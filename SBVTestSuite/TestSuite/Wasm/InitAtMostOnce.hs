-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.InitAtMostOnce
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path one-time initialization state machine that
-- backs 'Data.SBV.SMT.WasmBridge.acquireSolver' (Requirements 5.3, 5.4, 5.5,
-- design Property 7).
--
-- The real @acquireSolver@ drives the @NotLoaded -> Loading -> Ready\/Failed@
-- 'Data.SBV.SMT.WasmBridge.WasmSolverState' machine behind GHC's WebAssembly
-- JSFFI, which is uninhabited on a stock native GHC. As with the other
-- browser-path properties, the contract is therefore exercised through the
-- shared 'Utils.MockBridge' harness, whose @acquireSolver@ reproduces the same
-- state machine (initialize at most once; on success transition to
-- 'Utils.MockBridge.PhaseReady'; on failure transition to
-- 'Utils.MockBridge.PhaseFailed' and /fail fast/ rather than stranding callers).
--
-- The single property exercises both facets of Property 7 over a generated
-- scenario:
--
--   * /Initialization happens at most once/ (Requirement 5.3). Any number of
--     awaiters that call @acquireSolver@ trigger /exactly one/ initialization:
--     the recorded 'Utils.MockBridge.initCount' stays @1@, and once the solver
--     is 'Utils.MockBridge.PhaseReady' every later @acquireSolver@ returns the
--     same handle without re-initializing.
--
--   * /Queued operations proceed in submission order/ (Requirement 5.4). When
--     initialization succeeds, a batch of operations (each @acquireSolver@ then
--     @sendCommand@) is delivered to the solver in the exact order submitted:
--     the recorded transcript equals the submitted command list.
--
--   * /A failed initialization strands nothing/ (Requirement 5.5). When
--     initialization fails, /every/ awaiter fails fast with a descriptive
--     'Utils.MockBridge.MockInitFailure' (naming the initialization phase),
--     none returns a result, none forwards a command to the solver, and — proven
--     by wrapping the whole run in 'System.Timeout.timeout' with a generous
--     bound — no operation is left blocked indefinitely.
--
-- Honest modelling note: on a single-threaded synchronous native GHC there is no
-- real event loop, so "queue during loading, resume in submission order" is
-- modelled as a strictly sequential batch of awaiters/operations — exactly how
-- the single-threaded browser runtime resolves them (each waiter resumes from
-- its event-loop yield in the order the loop schedules the callbacks).
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.InitAtMostOnce (tests) where

import Control.Exception (try)
import Control.Monad     (forM, replicateM, replicateM_, void)
import Data.List         (isInfixOf)
import System.Timeout    (timeout)

import Data.Text (Text)
import qualified Data.Text as T

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.InitAtMostOnce" [ initAtMostOnceNeverStrands ]

-- | Whether the one initialization attempt of the scenario succeeds, or fails
-- with a particular 'MB.SolverFailure'.
data InitMode = InitSucceeds
              | InitFails MB.SolverFailure

-- | One generated scenario: how initialization resolves, the batch of queued
-- operations (each modelled as an @acquireSolver@ followed by a @sendCommand@),
-- and a count of additional bare awaiters that only @acquireSolver@ (so the
-- at-most-once invariant is stressed with more than one waiter).
data Scenario = Scenario InitMode [Text] Int

-- | 'Show' via the explicit renderer, since 'MB.SolverFailure' (carried inside
-- 'InitMode') has no 'Show' instance. 'QC.pick' requires it for counterexamples.
instance Show Scenario where
  show = renderScenario

-- | A generous synchronicity bound (microseconds): a fail-fast initialization
-- and a sequential batch of sends complete in microseconds; this 2-second bound
-- only trips if some awaiter is actually left stranded (blocked indefinitely).
syncBoundMicros :: Int
syncBoundMicros = 2 * 1000 * 1000

-- | A single random command payload (no embedded newline; that is the unit the
-- bridge transmits).
genPayload :: QC.Gen Text
genPayload = do n <- QC.choose (1, 10)
                T.pack <$> QC.vectorOf n (QC.elements payloadChars)
  where payloadChars = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "()-_ "

-- | A command tagged with its submission index, so the submission-order check
-- (transcript equals the submitted list) is observable in a counterexample even
-- when two payloads happen to coincide.
genCmd :: Int -> QC.Gen Text
genCmd i = (\p -> T.pack (show i ++ ":") <> p) <$> genPayload

-- | A scripted initialization failure: any of the four 'MB.SolverFailure'
-- shapes (biased toward the load\/init phases that an initialization realistically
-- hits) carrying an arbitrary, possibly empty, descriptive payload.
genFailure :: QC.Gen MB.SolverFailure
genFailure = do mk  <- QC.elements [MB.SolverLoadError, MB.SolverInitError, MB.SolverRejected, MB.SolverTimedOut]
                msg <- genFailMsg
                pure (mk msg)
  where genFailMsg = do n <- QC.choose (0, 20)
                        QC.vectorOf n (QC.elements (['a'..'z'] ++ " .:_"))

-- | Generate a scenario with at least one queued operation (hence at least one
-- awaiter), so initialization is always triggered.
genScenario :: QC.Gen Scenario
genScenario = do n     <- QC.choose (1, 12)
                 cmds  <- mapM genCmd [1 .. n]
                 extra <- QC.choose (0, 6)
                 mode  <- QC.frequency [ (1, pure InitSucceeds)
                                       , (1, InitFails <$> genFailure)
                                       ]
                 pure (Scenario mode cmds extra)

-- | Run a successful-initialization scenario: some bare awaiters, then each
-- queued operation (@acquireSolver@ + @sendCommand@), then more bare awaiters.
-- Returns the recorded init count, final phase, transcript, and the per-send
-- outcomes.
runSuccess :: [Text] -> Int -> IO (Int, MB.MockPhase, [Text], [Either MB.SolverFailure Text])
runSuccess cmds extra = do
        mb <- MB.newMockBridge (MB.emptyScript { MB.msResponses = replicate (length cmds) (MB.respondWith (T.pack "success")) })
        replicateM_ extra (void (MB.acquireSolver mb))
        outs <- forM cmds $ \c -> do _ <- MB.acquireSolver mb
                                     MB.sendCommand mb Nothing c
        replicateM_ extra (void (MB.acquireSolver mb))
        ic <- MB.initCount   mb
        ph <- MB.solverPhase mb
        tr <- MB.transcript  mb
        pure (ic, ph, tr, outs)

-- | Run a failing-initialization scenario: every awaiter calls @acquireSolver@,
-- which must fail fast. Returns the recorded init count, final phase, transcript
-- (which must stay empty: nothing is forwarded after a failed init), and the
-- per-awaiter outcomes.
runFailure :: MB.SolverFailure -> Int -> IO (Int, MB.MockPhase, [Text], [Either MB.MockBridgeException ()])
runFailure f nAwaiters = do
        mb <- MB.newMockBridge (MB.emptyScript { MB.msInitOutcome = Left f })
        results <- replicateM nAwaiters (try (void (MB.acquireSolver mb)) :: IO (Either MB.MockBridgeException ()))
        ic <- MB.initCount   mb
        ph <- MB.solverPhase mb
        tr <- MB.transcript  mb
        pure (ic, ph, tr, results)

-- Feature: sbv-browser-wasm-backend, Property 7: Initialization happens at most once and never strands queued operations
initAtMostOnceNeverStrands :: TestTree
initAtMostOnceNeverStrands =
    QC.testProperty "Property 7: Initialization happens at most once and never strands queued operations" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          scenario@(Scenario mode cmds extra) <- QC.pick genScenario
          QC.monitor (QC.counterexample (renderScenario scenario))

          case mode of
            InitSucceeds -> do
              mres <- QC.run $ timeout syncBoundMicros (runSuccess cmds extra)
              case mres of
                Nothing -> do QC.monitor (QC.counterexample "queued operations stranded: did not complete within the synchronicity bound")
                              QC.assert False
                Just (ic, ph, tr, outs) -> do
                  QC.monitor (QC.counterexample ("initCount/phase/transcript: " ++ show (ic, ph, tr)))
                  -- Initialization happened at most (here exactly) once across every awaiter (Requirement 5.3).
                  QC.assert (ic == 1)
                  QC.assert (ph == MB.PhaseReady)
                  -- Queued operations were delivered in submission order (Requirement 5.4).
                  QC.assert (tr == cmds)
                  -- Every queued operation completed with a response (none stranded).
                  QC.assert (all isRightE outs)

            InitFails _ -> do
              let nAwaiters = length cmds + extra
              mres <- QC.run $ timeout syncBoundMicros (runFailure (failureOf mode) nAwaiters)
              case mres of
                Nothing -> do QC.monitor (QC.counterexample "init-failure awaiters stranded: did not complete within the synchronicity bound")
                              QC.assert False
                Just (ic, ph, tr, results) -> do
                  QC.monitor (QC.counterexample ("initCount/phase/transcript: " ++ show (ic, ph, tr)))
                  -- Initialization was attempted at most (here exactly) once, even though it failed (Requirement 5.3).
                  QC.assert (ic == 1)
                  QC.assert (ph == MB.PhaseFailed)
                  -- No queued operation forwarded a command to the solver after a failed init.
                  QC.assert (null tr)
                  -- Every awaiter resolved (none was left blocked) ...
                  QC.assert (length results == nAwaiters)
                  -- ... and each failed with a descriptive, phase-naming error (Requirement 5.5).
                  QC.assert (all descriptiveInitFailure results)

-- | Extract the scripted failure from a failing-init scenario mode.
failureOf :: InitMode -> MB.SolverFailure
failureOf (InitFails f) = f
failureOf InitSucceeds  = error "TestSuite.Wasm.InitAtMostOnce.failureOf: called on a succeeding-init scenario"

-- | A failed awaiter is acceptable only if it threw a 'MB.MockInitFailure' whose
-- rendered message is non-empty and names the initialization phase, so the error
-- is genuinely descriptive (Requirement 5.5).
descriptiveInitFailure :: Either MB.MockBridgeException () -> Bool
descriptiveInitFailure (Left (MB.MockInitFailure msg)) = not (null msg) && "initialization" `isInfixOf` msg
descriptiveInitFailure _                               = False

-- | Local 'Data.Either.isRight' (avoids depending on its presence in scope).
isRightE :: Either a b -> Bool
isRightE Right{} = True
isRightE _       = False

-- | Render a scenario for counterexamples ('MB.SolverFailure' has no 'Show').
renderScenario :: Scenario -> String
renderScenario (Scenario mode cmds extra) =
        "mode=" ++ renderMode mode ++ ", #cmds=" ++ show (length cmds)
                ++ ", extraAcquires=" ++ show extra ++ ", cmds=" ++ show cmds

-- | Render the initialization mode for counterexamples.
renderMode :: InitMode -> String
renderMode InitSucceeds   = "InitSucceeds"
renderMode (InitFails f)  = "InitFails(" ++ renderFailure f ++ ")"

-- | Render a 'MB.SolverFailure' for counterexamples (the shared type has no
-- 'Show' instance).
renderFailure :: MB.SolverFailure -> String
renderFailure (MB.SolverRejected  s) = "SolverRejected "  ++ show s
renderFailure (MB.SolverTimedOut  s) = "SolverTimedOut "  ++ show s
renderFailure (MB.SolverLoadError s) = "SolverLoadError " ++ show s
renderFailure (MB.SolverInitError s) = "SolverInitError " ++ show s

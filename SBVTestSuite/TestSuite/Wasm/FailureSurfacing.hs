-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.FailureSurfacing
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path failure-surfacing contract (design
-- Property 5, Requirements 1.5, 2.6, 3.4, 13.3, 13.4).
--
-- When a Solver_Failure occurs before a complete, balanced s-expression is
-- received, the browser engine must abort the operation, surface an
-- 'SBVException' that
--
--   * carries the command in flight in 'sbvExceptionSent' (Reqs 2.6, 3.4,
--     13.3, 13.4),
--   * carries any partial response received in 'sbvExceptionReceived' (Reqs
--     2.6, 13.3, 13.4),
--   * identifies the failure cause in its description (Reqs 1.5, 3.4),
--
-- release the WASM_Solver resources associated with that request (Req 13.4),
-- and return /no/ result for the command (Reqs 1.5, 2.6, 3.4).
--
-- The real 'Data.SBV.SMT.BrowserEngine.browserEngine' lives behind
-- @#ifdef SBV_WASM@ and drives a JSFFI bridge that is uninhabited on a stock
-- native GHC. Exactly as the other @Wasm.*@ property tests do — and exactly as
-- Property 13 routes the concurrent-combinator rejection through the shared
-- pure helper 'Data.SBV.Internals.concurrentCombinatorRejection', and Property
-- 12 routes @safeWith@ path reporting through 'Data.SBV.Internals.mkRelativeFor'
-- — this module exercises the contract through:
--
--   * the shared 'Utils.MockBridge' harness, which scripts the very
--     'SolverFailure' values the engine consumes and records every released
--     session; and
--   * the shared /pure/ helpers 'Data.SBV.Internals.browserFailureException'
--     and 'Data.SBV.Internals.incompleteResponseFailure', which are the exact
--     functions 'browserEngine' uses to build the surfaced 'SBVException'.
--
-- The local 'engineReadStep' is a faithful transcription of the engine's
-- @getResponseFromSolver@ + @collectComplete@ read path over a bridge result:
-- on a scripted transport failure ('Left' 'SolverFailure') it releases the
-- session and throws @'browserFailureException' cfg fl (Just cmd) \"\"@; on a
-- delivered-but-unbalanced response ('Right' with a positive 'parenDeficit') it
-- releases the session and throws
-- @'browserFailureException' cfg ('incompleteResponseFailure' d) (Just cmd) r@;
-- and on a delivered, balanced response it returns the response with no
-- teardown. Driving generated scenarios through it on a native GHC therefore
-- checks the exact 'SBVException' the browser engine raises — with no
-- WebAssembly runtime and no real solver.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.FailureSurfacing (tests) where

import Control.Exception (try, throwIO)
import Data.List         (isInfixOf)

import Data.Text (Text)
import qualified Data.Text as T

import Data.SBV.Internals (browserFailureException, incompleteResponseFailure, parenDeficit)

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.FailureSurfacing" [ failuresSurfaceAsSBVException ]

-- | The browser configuration whose engine surfaces these exceptions. Its
-- solver name (@Z3@) is what the surfaced description must identify.
cfg :: SMTConfig
cfg = z3Wasm

-- | The three scenario kinds a generated interaction exercises.
data FailKind = -- | The bridge reports a transport 'SolverFailure' before any
            -- response arrives (Promise rejection / crash / load / init /
            -- timeout). The engine surfaces it with an /empty/ partial response.
            TransportFailure MB.SolverFailure
            -- | The bridge delivers a single message that is /not/ balanced (a
            -- positive paren deficit), i.e. a Solver_Failure occurred before a
            -- complete s-expression. The engine surfaces it with the received
            -- text as the partial response.
          | IncompleteResponse Text
            -- | The bridge delivers a complete, balanced response. No failure is
            -- surfaced; the response is returned and the session is not torn
            -- down. (Control case, to show failures — and only failures —
            -- surface.)
          | CompleteResponse Text

-- | A generated interaction: the command in flight and the scenario kind.
data Scenario = Scenario
        { sCommand :: Text
        , sKind    :: FailKind
        }

-- | 'Show' via the explicit renderer ('MB.SolverFailure' has no 'Show').
instance Show Scenario where
  show = renderScenario

-- | A distinctive, non-empty failure cause so its preservation in the surfaced
-- description is observable via 'isInfixOf'.
genCause :: QC.Gen String
genCause = do n <- QC.choose (1, 12)
              body <- QC.vectorOf n (QC.elements (['a'..'z'] ++ ['0'..'9']))
              pure ("cause-" ++ body)

-- | A scripted transport 'SolverFailure', drawn from all four shapes so the
-- phase wordings (which keep the kinds textually distinguishable) are all
-- exercised, each carrying a distinctive cause.
genFailure :: QC.Gen MB.SolverFailure
genFailure = do mk <- QC.elements [MB.SolverRejected, MB.SolverTimedOut, MB.SolverLoadError, MB.SolverInitError]
                mk <$> genCause

-- | A token built from a non-paren alphabet, so its 'parenDeficit' is @0@ and
-- it can be used to build responses with a precisely controlled deficit.
genNoParenToken :: QC.Gen String
genNoParenToken = do n <- QC.choose (0, 10)
                     QC.vectorOf n (QC.elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " :-_"))

-- | A response with a strictly positive paren deficit (more @(@ than @)@): an
-- incomplete s-expression. We prepend @k >= 1@ unmatched open parens to a
-- paren-free token, so the deficit is exactly @k@.
genIncomplete :: QC.Gen Text
genIncomplete = do k   <- QC.choose (1, 5)
                   tok <- genNoParenToken
                   pure (T.pack (replicate k '(' ++ tok))

-- | A complete, balanced response (paren deficit @0@): either a paren-free
-- token (e.g. @sat@\/@unsat@\/@unknown@\/@success@) or a balanced
-- @(...)@ wrapping a paren-free body.
genComplete :: QC.Gen Text
genComplete = QC.oneof
        [ QC.elements (map T.pack ["sat", "unsat", "unknown", "success"])
        , T.pack <$> genNoParenToken
        , do body <- genNoParenToken
             pure (T.pack ("(" ++ body ++ ")"))
        ]

-- | A non-empty command string, biased toward realistic SMT-Lib2 commands so
-- the "names the command" check is meaningful.
genCommand :: QC.Gen Text
genCommand = QC.oneof
        [ QC.elements (map T.pack [ "(check-sat)"
                                  , "(get-model)"
                                  , "(get-value (x))"
                                  , "(assert (> x 0))"
                                  , "(get-unsat-core)"
                                  ])
        , do n <- QC.choose (1, 10)
             T.pack <$> QC.vectorOf n (QC.elements (['a'..'z'] ++ ['0'..'9'] ++ "()-:_"))
        ]

-- | Generate a scenario across all three kinds.
genScenario :: QC.Gen Scenario
genScenario = do cmd  <- genCommand
                 kind <- QC.frequency [ (2, TransportFailure   <$> genFailure)
                                      , (2, IncompleteResponse <$> genIncomplete)
                                      , (1, CompleteResponse   <$> genComplete)
                                      ]
                 pure (Scenario cmd kind)

-- | A faithful transcription of the browser engine's read path over a single
-- bridge result (mirrors @getResponseFromSolver@ + @collectComplete@ in
-- "Data.SBV.SMT.BrowserEngine"). It sends the command through the mock bridge
-- and then:
--
--   * on a transport 'SolverFailure': releases the session ('MB.release', the
--     engine's @terminateSolver@) and throws the enriched 'SBVException' with an
--     empty partial response;
--   * on a delivered-but-unbalanced response: releases the session and throws
--     the enriched 'SBVException' carrying the received text as the partial; and
--   * on a delivered, balanced response: returns the response (no teardown).
--
-- It uses the same shared pure helpers ('browserFailureException',
-- 'incompleteResponseFailure', 'parenDeficit') the engine uses, so the
-- 'SBVException' it raises is byte-for-byte the one the engine raises.
engineReadStep :: MB.MockBridge -> Text -> IO String
engineReadStep mb command = do
        res <- MB.sendCommand mb Nothing command
        case res of
          Left fl  -> do MB.release mb
                         throwIO (browserFailureException cfg fl (Just (T.unpack command)) "")
          Right r  -> let s    = T.unpack r
                          need = parenDeficit s
                      in if need <= 0
                            then pure s
                            else do MB.release mb
                                    throwIO (browserFailureException cfg (incompleteResponseFailure need) (Just (T.unpack command)) s)

-- Feature: sbv-browser-wasm-backend, Property 5: Failures surface as an SBVException carrying the command and partial response
-- Validates: Requirements 1.5, 2.6, 3.4, 13.3, 13.4
failuresSurfaceAsSBVException :: TestTree
failuresSurfaceAsSBVException =
    QC.testProperty "Property 5: Failures surface as an SBVException carrying the command and partial response" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          scn <- QC.pick genScenario
          QC.monitor (QC.counterexample (renderScenario scn))

          let command = sCommand scn

          -- Script the mock bridge with the single scripted outcome for this
          -- interaction, init it cleanly, run the engine read step capturing any
          -- SBVException, then read back what the bridge recorded.
          (outcome, recorded, releases) <- QC.run $ do
                mb <- MB.newMockBridge (MB.emptyScript { MB.msResponses = [scriptedOutcome (sKind scn)] })
                _  <- MB.acquireSolver mb
                r  <- try (engineReadStep mb command) :: IO (Either SBVException String)
                tr <- MB.transcript   mb
                rc <- MB.releaseCount mb
                pure (r, tr, rc)

          -- The command in flight was forwarded to the solver exactly once (a
          -- real command, not the empty/comment short-circuit), so the failure
          -- bound applies to an actually-awaited command.
          QC.monitor (QC.counterexample ("transcript: " ++ show recorded))
          QC.assert (recorded == [command])

          case sKind scn of
            -- A transport Solver_Failure: the engine surfaces an SBVException
            -- carrying the command in flight and an EMPTY partial response (the
            -- response never arrived), identifies the failure cause, and returns
            -- no result; the request's resources are released.
            TransportFailure fl ->
                assertFailureSurfaced outcome releases command "" (failureCause fl)

            -- A delivered-but-unbalanced response: a Solver_Failure occurred
            -- before a complete s-expression. The engine surfaces an
            -- SBVException carrying the command and the RECEIVED text as the
            -- partial response, and returns no result; resources are released.
            IncompleteResponse r ->
                assertFailureSurfaced outcome releases command (T.unpack r) Nothing

            -- A complete, balanced response: NO failure surfaces. The response
            -- is returned verbatim and the session is not torn down.
            CompleteResponse r -> do
                QC.monitor (QC.counterexample ("expected a returned result, got: " ++ show (render outcome)))
                -- 'SBVException' has no 'Eq'; compare through the success arm of
                -- 'render' (which is the identity on a returned 'String').
                QC.assert (render outcome == Right (T.unpack r))
                -- No teardown happened on the success path.
                QC.monitor (QC.counterexample ("unexpected release on the success path; count=" ++ show releases))
                QC.assert (releases == 0)

-- | Assert that a failure scenario surfaced correctly: the read step threw an
-- 'SBVException' (so /no/ result was returned) whose 'sbvExceptionSent' is the
-- command in flight and whose 'sbvExceptionReceived' is the expected partial
-- response; the description names the solver and (when given) carries the
-- failure cause; and the request's resources were released exactly once.
assertFailureSurfaced :: Either SBVException String  -- ^ the read-step outcome
                      -> Int                         -- ^ recorded release count
                      -> Text                        -- ^ the command in flight
                      -> String                      -- ^ the expected partial response
                      -> Maybe String                -- ^ the expected failure cause (when distinctive)
                      -> QC.PropertyM IO ()
assertFailureSurfaced outcome releases command expectedPartial mbCause = case outcome of
        Right s -> do QC.monitor (QC.counterexample ("expected an SBVException, but a result was returned: " ++ show s))
                      QC.assert False
        Left e  -> do
            -- (no result) — we are in the Left/exception branch, so nothing was returned.

            -- The command in flight is carried in sbvExceptionSent (Reqs 2.6, 3.4, 13.3, 13.4).
            QC.monitor (QC.counterexample ("sbvExceptionSent: " ++ show (sbvExceptionSent e)))
            QC.assert (sbvExceptionSent e == Just (T.unpack command))

            -- The partial response is carried in sbvExceptionReceived (Reqs 2.6, 13.3, 13.4).
            QC.monitor (QC.counterexample ("sbvExceptionReceived: " ++ show (sbvExceptionReceived e)))
            QC.assert (sbvExceptionReceived e == Just expectedPartial)

            -- The description identifies the solver (Reqs 1.5, 3.4) ...
            let desc = sbvExceptionDescription e
            QC.monitor (QC.counterexample ("description did not name the solver: " ++ desc))
            QC.assert ("Z3" `isInfixOf` desc)

            -- ... and carries the failure cause when one was distinctly scripted (Reqs 1.5, 3.4).
            case mbCause of
              Just cause -> do QC.monitor (QC.counterexample ("description did not carry the cause " ++ show cause ++ ": " ++ desc))
                               QC.assert (cause `isInfixOf` desc)
              Nothing    -> pure ()

            -- The request's WASM resources were released exactly once (Req 13.4).
            QC.monitor (QC.counterexample ("expected exactly one release, count=" ++ show releases))
            QC.assert (releases == 1)

-- | The scripted bridge outcome for a scenario kind.
scriptedOutcome :: FailKind -> MB.ScriptedResponse
scriptedOutcome (TransportFailure fl)  = MB.failWith fl
scriptedOutcome (IncompleteResponse r) = MB.respondWith r
scriptedOutcome (CompleteResponse r)   = MB.respondWith r

-- | The distinctive cause string carried by a transport failure (so its
-- preservation in the surfaced description can be checked).
failureCause :: MB.SolverFailure -> Maybe String
failureCause (MB.SolverRejected  s) = Just s
failureCause (MB.SolverTimedOut  s) = Just s
failureCause (MB.SolverLoadError s) = Just s
failureCause (MB.SolverInitError s) = Just s

-- | A showable rendering of a read-step outcome for counterexamples
-- ('SBVException' has a 'Show', so we just reuse it for the 'Left' arm).
render :: Either SBVException String -> Either String String
render (Right s) = Right s
render (Left e)  = Left (sbvExceptionDescription e)

-- | Render a scenario for counterexamples ('MB.SolverFailure' has no 'Show').
renderScenario :: Scenario -> String
renderScenario (Scenario cmd kind) = "command=" ++ show cmd ++ ", kind=" ++ renderKind kind

-- | Render a scenario kind for counterexamples.
renderKind :: FailKind -> String
renderKind (TransportFailure fl)  = "TransportFailure(" ++ renderFailure fl ++ ")"
renderKind (IncompleteResponse r) = "IncompleteResponse " ++ show r
renderKind (CompleteResponse r)   = "CompleteResponse "   ++ show r

-- | Render a 'MB.SolverFailure' for counterexamples (the shared type has no
-- 'Show' instance).
renderFailure :: MB.SolverFailure -> String
renderFailure (MB.SolverRejected  s) = "SolverRejected "  ++ show s
renderFailure (MB.SolverTimedOut  s) = "SolverTimedOut "  ++ show s
renderFailure (MB.SolverLoadError s) = "SolverLoadError " ++ show s
renderFailure (MB.SolverInitError s) = "SolverInitError " ++ show s

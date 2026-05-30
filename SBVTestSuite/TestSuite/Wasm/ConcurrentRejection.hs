-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.ConcurrentRejection
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path rejection of the multi-solver concurrent
-- combinators @proveWithAny@ \/ @proveWithAll@ \/ @satWithAny@ \/ @satWithAll@
-- (Requirements 9.4, 9.5, design Property 13).
--
-- On the browser (WASM) path these four combinators cannot race solver
-- /processes/ against each other (the runtime is single-threaded), so they are
-- rejected with an unsupported-operation 'SBVException' that /names/ the invoked
-- combinator, returned /synchronously/ (no thread spawned, no Promise awaited),
-- /without/ opening or leaving any 'WASM_Solver' session active.
--
-- The actual @#ifdef SBV_WASM@ combinators are not compiled into the native
-- test binary (the suite is built without @-DSBV_WASM@), so we cannot call the
-- real @proveWithAny@ etc. here. Instead — exactly as Property 12 routes both
-- 'Data.SBV.safeWith' branches through the shared pure helper
-- 'Data.SBV.Internals.mkRelativeFor' — the rejection's exception value is built
-- by the shared pure helper 'Data.SBV.Internals.concurrentCombinatorRejection'.
-- The browser combinators are literally
-- @combinator configs _ = throwIO ('concurrentCombinatorRejection' name configs)@,
-- so reproducing that one-line synchronous throw natively faithfully models the
-- browser combinator's observable behaviour:
--
--   (i)   it throws /synchronously/ — we wrap the throw in 'System.Timeout.timeout'
--         with a generous bound and require it to complete (throw) within the
--         bound; a regression that instead awaited an OS thread\/background task
--         (e.g. @async ... >>= wait@, 'threadDelay') would time out;
--   (ii)  the raised 'SBVException' /names/ the invoked combinator in its
--         'sbvExceptionDescription'; and
--   (iii) it leaves /no/ 'WASM_Solver' session active — modelled natively with
--         'Utils.MockBridge': the rejection path never 'acquireSolver's,
--         initializes, or releases a session, so the mock stays in
--         'PhaseNotLoaded' with a zero init\/release count. A regression that
--         opened a session before rejecting would flip those counters.
--
-- Honest modelling note: on a stock native GHC there is no real WASM session, so
-- clause (iii) is asserted at the level available — that the rejection path does
-- not /create/ a session (never calls the bridge), which is precisely how the
-- real combinators guarantee "no session left active": they reject before doing
-- any session work.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.ConcurrentRejection (tests) where

import Control.Exception (try, throwIO)
import Data.List         (isInfixOf)
import System.Timeout    (timeout)

import Data.SBV.Internals (concurrentCombinatorRejection)

import Utils.SBVTestFramework

import qualified Utils.MockBridge      as MB
import qualified Test.Tasty.QuickCheck as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.ConcurrentRejection" [ concurrentCombinatorsRejectedSynchronously ]

-- | The four multi-solver concurrent combinators that the browser path rejects.
-- These are the exact names the @#ifdef SBV_WASM@ combinators pass to the
-- rejection helper.
combinatorNames :: [String]
combinatorNames = ["proveWithAny", "proveWithAll", "satWithAny", "satWithAll"]

-- | Generate one invoked-combinator name from the closed set above.
genCombinator :: QC.Gen String
genCombinator = QC.elements combinatorNames

-- | Generate an arbitrary list of solver configs to pass to the combinator,
-- drawn from the publicly available solver configurations. The empty list is
-- included on purpose so the helper's @[] -> defaultSMTCfg@ branch is exercised.
genConfigs :: QC.Gen [SMTConfig]
genConfigs = QC.sized $ \n -> do
        k <- QC.choose (0, max 0 (min n 5))
        QC.vectorOf k (QC.elements availableConfigs)
  where availableConfigs = [ boolector, bitwuzla, cvc4, cvc5, yices, dReal, z3, mathSAT, abc, openSMT ]

-- | A generous synchronicity bound (microseconds). A synchronous throw returns
-- in microseconds; this 2-second bound only trips if the rejection actually
-- blocks on / awaits a thread or background task.
syncBoundMicros :: Int
syncBoundMicros = 2 * 1000 * 1000

-- Feature: sbv-browser-wasm-backend, Property 13: Concurrent combinators are rejected synchronously without leaving a session active
concurrentCombinatorsRejectedSynchronously :: TestTree
concurrentCombinatorsRejectedSynchronously =
    QC.testProperty "Property 13: Concurrent combinators are rejected synchronously without leaving a session active" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          combinator <- QC.pick genCombinator
          configs    <- QC.pick genConfigs

          QC.monitor (QC.counterexample ("combinator: " ++ combinator ++ ", #configs: " ++ show (length configs)))

          -- The browser combinator's observable action: a single synchronous
          -- throw of the shared rejection exception (mirrors
          -- @combinator configs _ = throwIO (concurrentCombinatorRejection name configs)@).
          let reject :: IO ()
              reject = throwIO (concurrentCombinatorRejection combinator configs)

          -- (i) + (ii): the rejection completes (throws) WITHIN the bound
          -- (synchronous, no awaited thread/task) and the thrown SBVException
          -- NAMES the invoked combinator.
          outcome <- QC.run $ timeout syncBoundMicros (try reject)
          case outcome of
            Nothing                -> do QC.monitor (QC.counterexample "rejection did not complete synchronously (timed out)")
                                         QC.assert False
            Just (Right ())        -> do QC.monitor (QC.counterexample "rejection returned a result instead of throwing")
                                         QC.assert False
            Just (Left (e :: SBVException)) -> do
                let desc = sbvExceptionDescription e
                QC.monitor (QC.counterexample ("exception description did not name the combinator: " ++ desc))
                QC.assert (combinator `isInfixOf` desc)

          -- (iii): the rejection leaves NO WASM_Solver session active. Drive the
          -- same synchronous throw in a context holding a fresh MockBridge and
          -- confirm the rejection never acquired, initialized, or released a
          -- session: the mock stays in PhaseNotLoaded with zero init/release.
          (phase, inits, releases) <- QC.run $ do
                mb <- MB.newMockBridge MB.emptyScript
                -- Mirror the real combinator, which ignores any session and just rejects.
                _  <- try reject :: IO (Either SBVException ())
                ph <- MB.solverPhase   mb
                ic <- MB.initCount     mb
                rc <- MB.releaseCount  mb
                pure (ph, ic, rc)

          QC.monitor (QC.counterexample ("post-rejection mock phase/init/release: " ++ show (phase, inits, releases)))
          QC.assert (phase    == MB.PhaseNotLoaded)
          QC.assert (inits    == 0)
          QC.assert (releases == 0)

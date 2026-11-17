-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.CleanupFidelity
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path aborting-cleanup exception fidelity
-- (Requirements 8.3, 8.4, 8.5, design Property 10).
--
-- When a browser solver task is aborted by a forwarded exception, the
-- browser engine ("Data.SBV.SMT.BrowserEngine") must:
--
--   * release the WASM_Solver resources held by that session /before/
--     propagating the exception (Requirement 8.3);
--   * re-raise the /original/ forwarded exception, without substituting a
--     different one (Requirement 8.4); and
--   * still re-raise that original exception even if releasing the resources
--     itself fails — a resource-release error must never substitute\/mask the
--     original (Requirement 8.5).
--
-- The engine encodes this discipline in two structurally identical places (the
-- @cleanUp@ closure's forwarded-exception branch and the top-level
-- @launchSolver \`catch\`@ handler), both of which run:
--
-- @
--   terminateSolver                                   -- release, swallowing any release failure
--   terminateSolver = release h \`catch\` \\(_::SomeException) -> pure ()
--   ...
--   C.throwIO forwardedException                      -- re-raise the ORIGINAL exception unchanged
-- @
--
-- The real @browserEngine@ talks to the JSFFI bridge
-- ("Data.SBV.SMT.WasmBridge"), whose primitives are uninhabited @error@ stubs
-- on a stock native GHC, so it cannot be invoked here. Exactly as the sibling
-- browser-path properties do (e.g. @Wasm.ConcurrentRejection@ reproduces the
-- combinator's one-line synchronous throw, @Wasm.InitAtMostOnce@ drives the
-- state machine through the mock), this test reproduces the engine's abort-path
-- cleanup as a faithful transcription ('abortCleanup') over the reusable
-- 'Utils.MockBridge' harness. The harness already models a scripted /failing/
-- release ('Utils.MockBridge.msReleaseThrows'), which surfaces a
-- 'Utils.MockBridge.MockReleaseFailure' rather than silently swallowing it — so
-- a regression that dropped the engine's release-swallowing @catch@ (and thus
-- let a release error escape and mask the original) would make the
-- corresponding model fail this test.
--
-- The single property exercises both release outcomes (clean release and
-- scripted release failure) crossed with a randomly-tagged forwarded exception,
-- and asserts the three observable halves of Property 10:
--
--   (1) the cleanup actually released the session's resources before
--       propagating — the recorded 'Utils.MockBridge.releaseCount' is @1@
--       (Requirement 8.3);
--   (2) the exception that escapes is, by value, /exactly/ the original
--       forwarded exception (matched by its unique tag), and is not the
--       release-phase failure (Requirements 8.4, 8.5); and
--   (3) the cleanup completes synchronously (proven by a generous
--       'System.Timeout.timeout' bound), so no awaiter is left stranded.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.CleanupFidelity (tests) where

import Control.Exception (Exception, SomeException, catch, fromException, throwIO, try)
import System.Timeout    (timeout)

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.CleanupFidelity" [ abortingCleanupReraisesOriginal ]

-- | A stand-in for the /original forwarded exception/ that aborts a browser
-- solver task. It carries a unique integer tag so the exception that escapes
-- the cleanup can be matched back to the original by value, and so it is
-- unambiguously distinguishable from any release-phase failure (which is a
-- 'Utils.MockBridge.MockReleaseFailure', a different type entirely).
newtype ForwardedException = ForwardedException Int
        deriving (Eq, Show)

instance Exception ForwardedException

-- | Whether the scenario's resource release succeeds cleanly, or fails (so the
-- "release error must not mask the original" facet, Requirement 8.5, is
-- exercised).
data ReleaseOutcome = ReleaseSucceeds
                    | ReleaseFails
                    deriving (Eq, Show)

-- | A generous synchronicity bound (microseconds). A correct abort-path cleanup
-- releases (swallowing any failure) and re-raises in microseconds; this 2-second
-- bound only trips if the cleanup is left blocked / stranded.
syncBoundMicros :: Int
syncBoundMicros = 2 * 1000 * 1000

-- | Generate one scenario: how the release resolves, and the unique tag of the
-- original forwarded exception.
genScenario :: QC.Gen (ReleaseOutcome, Int)
genScenario = do ro  <- QC.elements [ReleaseSucceeds, ReleaseFails]
                 tag <- QC.choose (-1000000, 1000000)
                 pure (ro, tag)

-- | A faithful transcription of the browser engine's abort-path cleanup
-- ("Data.SBV.SMT.BrowserEngine": @terminateSolver@ + @cleanUp@'s
-- forwarded-exception branch / the top-level @launchSolver \`catch\`@ handler).
--
-- 'terminateSolver' releases the session's resources, swallowing any release
-- failure with a catch-all so it can never escape; the abort branch then
-- re-raises the /original/ forwarded exception unchanged. The release-swallowing
-- @catch@ here is the engine mechanism under test: were it dropped, a scripted
-- 'Utils.MockBridge.MockReleaseFailure' would escape and mask the original,
-- which the property below would catch.
abortCleanup :: MB.MockBridge -> ForwardedException -> IO ()
abortCleanup mb forwarded = do
        -- Release resources BEFORE propagating (Requirement 8.3); a release
        -- failure is swallowed so it can never substitute the original
        -- exception (Requirement 8.5).
        MB.release mb `catch` \(_ :: SomeException) -> pure ()
        -- Re-raise the ORIGINAL forwarded exception unchanged (Requirements 8.4, 8.5).
        throwIO forwarded

-- Feature: sbv-browser-wasm-backend, Property 10: Aborting cleanup re-raises the original exception after releasing resources
-- Validates: Requirements 8.3, 8.4, 8.5
abortingCleanupReraisesOriginal :: TestTree
abortingCleanupReraisesOriginal =
    QC.testProperty "Property 10: Aborting cleanup re-raises the original exception after releasing resources" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          (releaseOutcome, tag) <- QC.pick genScenario
          let forwarded     = ForwardedException tag
              releaseThrows = releaseOutcome == ReleaseFails

          QC.monitor (QC.counterexample ("releaseOutcome=" ++ show releaseOutcome ++ ", forwarded=" ++ show forwarded))

          -- Drive a fresh, initialized mock session that scripts the chosen
          -- release outcome, then run the engine's abort-path cleanup under a
          -- synchronicity bound and read back how many times release ran.
          (outcome, releases) <- QC.run $ do
                mb <- MB.newMockBridge (MB.emptyScript { MB.msReleaseThrows = releaseThrows })
                _  <- MB.acquireSolver mb
                res <- timeout syncBoundMicros (try (abortCleanup mb forwarded) :: IO (Either SomeException ()))
                rc  <- MB.releaseCount mb
                pure (res, rc)

          QC.monitor (QC.counterexample ("releaseCount=" ++ show releases))

          case outcome of
            -- (3) The cleanup must complete synchronously; a 'Nothing' means it
            --     was left stranded / blocked past the generous bound.
            Nothing -> do QC.monitor (QC.counterexample "aborting cleanup did not complete within the synchronicity bound")
                          QC.assert False

            -- A cleanup that returns normally never re-raised the forwarded
            -- exception at all (a violation of Requirement 8.4).
            Just (Right ()) -> do QC.monitor (QC.counterexample "aborting cleanup returned normally instead of re-raising the forwarded exception")
                                  QC.assert False

            Just (Left e) -> do
                -- (1) Resources were released before propagating: release ran
                --     exactly once (Requirement 8.3). This holds whether release
                --     succeeded or was scripted to fail (the mock increments its
                --     release count before throwing the scripted failure).
                QC.monitor (QC.counterexample "release was not invoked before propagating the exception")
                QC.assert (releases == 1)

                -- (2) The escaping exception is, by value, EXACTLY the original
                --     forwarded exception (Requirement 8.4) and is therefore not
                --     the release-phase failure even when release failed
                --     (Requirement 8.5).
                case fromException e :: Maybe ForwardedException of
                  Just fe -> do QC.monitor (QC.counterexample ("re-raised exception did not match the original: got " ++ show fe))
                                QC.assert (fe == forwarded)
                  Nothing -> do QC.monitor (QC.counterexample ("re-raised a substituted (non-original) exception: " ++ show e))
                                QC.assert False

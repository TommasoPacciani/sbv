-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.QueryTimeout
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path Query_Timeout semantics of the
-- async-to-sync bridge (Requirements 1.6, 3.5, 13.5, design Property 6).
--
-- On the browser (WASM) path a 'sendCommand' that is given a Query_Timeout
-- @'Just' µs@ races the solver's @send@ @Promise@ against a @setTimeout@-backed
-- timer @Promise@ (@Promise.race@): when the timer wins (the solver's response
-- does not arrive within the bound) the call yields @'Left'
-- ('SolverTimedOut' …)@ naming the command; when the solver wins (its response
-- arrives within the bound) the scripted outcome is returned verbatim. When the
-- Query_Timeout is @'Nothing'@ no timer is created at all and the await is
-- unbounded, exactly matching Native_SBV — so /no/ amount of simulated solver
-- delay can produce a timeout.
--
-- The real bridge enforces this on the JS side (it never uses 'System.Timeout'
-- preempting a blocked thread); the deterministic 'Utils.MockBridge' harness
-- models the very same @Promise.race@ decision by comparing each command's
-- scripted delay against the supplied timeout. Driving the mock with scripted
-- timing therefore exercises the browser-path contract on a stock native GHC,
-- with no WebAssembly runtime and no real solver.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.QueryTimeout (tests) where

import Data.List (isInfixOf)

import Data.Text (Text)
import qualified Data.Text as T

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.QueryTimeout" [ queryTimeoutBoundsTheWait ]

-- | Which of the three @Promise.race@ outcomes a generated scenario exercises.
data Outcome = TimerWins    -- ^ bounded wait, solver delay strictly exceeds the bound -> 'SolverTimedOut'.
             | SolverWins   -- ^ bounded wait, solver delay within the bound          -> scripted response.
             | Unbounded    -- ^ no Query_Timeout, any (even huge) delay              -> scripted response.
             deriving Show

-- | One generated interaction: the command sent, the response the solver would
-- (eventually) produce, the Query_Timeout in microseconds (@'Nothing'@ = wait
-- indefinitely), and the simulated solver delay for that command.
data TimeoutScenario = TimeoutScenario
        { tOutcome  :: Outcome
        , tCommand  :: Text
        , tResponse :: Text
        , tTimeout  :: Maybe Int
        , tDelay    :: Maybe Int
        } deriving Show

-- | A small token of solver-ish characters.
genToken :: QC.Gen Text
genToken = T.pack <$> QC.listOf1 (QC.elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "()-:_"))

-- | A non-empty command string, biased towards realistic SMT-Lib2 commands so
-- the "names the command" check is meaningful, with random tokens mixed in.
genCommand :: QC.Gen Text
genCommand = QC.oneof [ QC.elements (map T.pack [ "(check-sat)"
                                                , "(get-model)"
                                                , "(get-value (x))"
                                                , "(check-sat-assuming (p))"
                                                , "(get-unsat-core)"
                                                ])
                      , genToken
                      ]

-- | A non-empty response string.
genResponse :: QC.Gen Text
genResponse = QC.oneof [ QC.elements (map T.pack ["sat", "unsat", "unknown", "success", "(model)"])
                       , genToken
                       ]

-- | Generate a timing scenario. The bound and delay are chosen per outcome so
-- the @Promise.race@ decision is unambiguous:
--
--   * 'TimerWins'  - a positive bound @t@ and a delay strictly greater than @t@.
--   * 'SolverWins' - a positive bound @t@ and a delay within @t@ (or no delay,
--     i.e. instantaneous), including the boundary @delay == t@.
--   * 'Unbounded'  - no bound at all, paired with delays up to very large values
--     (and 'Nothing') to show that the absence of a Query_Timeout never produces
--     a timeout no matter how slow the solver is.
genTiming :: QC.Gen TimeoutScenario
genTiming = do
        cmd  <- genCommand
        resp <- genResponse
        oc   <- QC.elements [TimerWins, SolverWins, Unbounded]
        (to, d) <- case oc of
            TimerWins  -> do t     <- QC.choose (1, 1000000)
                             extra <- QC.choose (1, 1000000)
                             pure (Just t, Just (t + extra))
            SolverWins -> do t  <- QC.choose (1, 1000000)
                             md <- QC.oneof [ Just <$> QC.choose (0, t)   -- within the bound (<= t)
                                            , pure Nothing                -- instantaneous
                                            ]
                             pure (Just t, md)
            Unbounded  -> do md <- QC.oneof [ Just <$> QC.choose (0, 100000000)  -- even a very slow solver
                                            , pure Nothing
                                            ]
                             pure (Nothing, md)
        pure TimeoutScenario { tOutcome  = oc
                             , tCommand  = cmd
                             , tResponse = resp
                             , tTimeout  = to
                             , tDelay    = d
                             }

-- Feature: sbv-browser-wasm-backend, Property 6: Query_Timeout bounds the wait; absence waits indefinitely
-- Validates: Requirements 1.6, 3.5, 13.5
queryTimeoutBoundsTheWait :: TestTree
queryTimeoutBoundsTheWait =
    QC.testProperty "Property 6: Query_Timeout bounds the wait; absence waits indefinitely" $
      QC.withNumTests 200 $
        QC.forAll genTiming $ \tm -> QC.monadicIO $ do
          QC.monitor (QC.counterexample (show tm))

          -- Drive the scripted timing through the MockBridge: one command, whose
          -- single scripted response optionally carries the simulated solver
          -- delay. 'sendCommand' applies the same Promise.race decision the real
          -- bridge does, comparing the delay against the supplied Query_Timeout.
          (result, tr) <- QC.run $ do
                let scripted = maybe id MB.withDelay (tDelay tm) (MB.respondWith (tResponse tm))
                    script   = MB.emptyScript { MB.msResponses = [scripted] }
                mb <- MB.newMockBridge script
                _  <- MB.acquireSolver mb        -- clean init; the command below is the interaction under test
                r  <- MB.sendCommand mb (tTimeout tm) (tCommand tm)
                t  <- MB.transcript mb
                pure (r, t)

          -- The real command was forwarded (recorded as a single message), so
          -- the bound applies to an actually-awaited command.
          QC.monitor (QC.counterexample ("transcript: " ++ show tr))
          QC.assert (tr == [tCommand tm])

          case tOutcome tm of
            -- Bounded wait, solver too slow: the timer wins and the failure both
            -- is a 'SolverTimedOut' and names the command that timed out (3.5, 13.5).
            TimerWins  -> case result of
                            Left (MB.SolverTimedOut msg) -> do
                                QC.monitor (QC.counterexample ("timeout message did not name the command: " ++ msg))
                                QC.assert (T.unpack (tCommand tm) `isInfixOf` msg)
                            _ -> do QC.monitor (QC.counterexample "expected SolverTimedOut, got a non-timeout outcome")
                                    QC.assert False

            -- Bounded wait, solver fast enough: the bound does NOT fire; the
            -- scripted response is returned verbatim (1.6 - bounded but not exceeded).
            SolverWins -> assertScriptedResponse tm result

            -- No Query_Timeout: no timer exists, so however slow the solver is
            -- the await is unbounded and the scripted response is returned
            -- verbatim - never a timeout (1.6, 13.5 - absence waits indefinitely).
            Unbounded  -> assertScriptedResponse tm result

-- | Assert the call returned the scripted response verbatim (no timeout fired).
assertScriptedResponse :: TimeoutScenario -> Either MB.SolverFailure Text -> QC.PropertyM IO ()
assertScriptedResponse tm result = case result of
        Right txt -> do QC.monitor (QC.counterexample ("response mismatch: got " ++ show txt))
                        QC.assert (txt == tResponse tm)
        Left  _   -> do QC.monitor (QC.counterexample "expected the scripted response, but the wait was bounded/failed")
                        QC.assert False

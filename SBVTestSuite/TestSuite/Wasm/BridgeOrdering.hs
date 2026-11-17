-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.BridgeOrdering
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path async-to-sync bridge ordering /
-- single-in-flight guarantee (Requirement 3.3, design Property 4).
--
-- Requirement 3.3 states that the Async_Bridge delivers WASM_Solver responses
-- to SBV in the same order in which their commands were sent, clears its
-- awaiting state immediately upon delivering a response, and does NOT begin
-- awaiting a subsequent command's response until the response to the most
-- recently sent command has been delivered, so that each delivered response
-- corresponds to its originating command.
--
-- The real bridge keeps that ordering state in a module-level cell behind
-- JSFFI ("Data.SBV.SMT.WasmBridge.inFlightRef"), which is unavailable on a
-- native GHC. Exactly as the other @Wasm.*@ property tests do, this module
-- exercises the contract through the reusable 'Utils.MockBridge' harness, which
-- mirrors the real bridge's single-slot in-flight guard: 'MB.sendCommand'
-- records every message in an ordered transcript, claims a single in-flight
-- slot for the duration of each send (recording, via 'MB.sawConcurrentInFlight',
-- any send entered while another was still in flight), and replays scripted
-- responses front-to-back, one per send.
--
-- The driver here is strictly sequential (each 'MB.sendCommand' completes
-- before the next begins), exactly as SBV's @ask@ is on the single-threaded
-- browser runtime. The test then asserts the three observable halves of the
-- guarantee:
--
--   (1) the transcript of recorded commands is, in order, exactly the sequence
--       of commands sent (command order preserved);
--   (2) the delivered responses are, in order, exactly the scripted responses,
--       and because each command and its scripted response both embed the
--       interaction's position index, this confirms each delivered response
--       corresponds to its originating command (no off-by-one / swapped
--       delivery); and
--   (3) the harness never observed a send entered while another was still in
--       flight (at most one in flight at a time, the awaiting state cleared
--       between sends).
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.BridgeOrdering (tests) where

import Data.Text (Text)
import qualified Data.Text as T

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.BridgeOrdering" [ responsesDeliveredInOrderSingleInFlight ]

-- | A random command body, drawn from a small alphanumeric alphabet (possibly
-- empty). It only serves to vary the content of each command/response so the
-- test is not exercising a single fixed string.
genPayload :: QC.Gen String
genPayload = do n <- QC.choose (0, 8)
                QC.vectorOf n (QC.elements (['a'..'z'] ++ ['0'..'9']))

-- | One generated interaction: a random payload plus whether its scripted
-- outcome is a 'MB.SolverFailure' (rather than a success). The interaction's
-- position index is assigned later (by 'zip'), and is embedded into both the
-- command and its scripted response so a delivered response can be matched back
-- to its originating command.
genItem :: QC.Gen (String, Bool)
genItem = do p <- genPayload
             -- mostly successful responses, with the occasional scripted failure
             -- so ordering is checked across both response kinds.
             f <- QC.frequency [(4, pure False), (1, pure True)]
             pure (p, f)

-- | A non-empty batch of interactions to drive through the bridge in order.
genItems :: QC.Gen [(String, Bool)]
genItems = QC.sized $ \n -> do
        k <- QC.choose (1, max 1 (min n 12))
        QC.vectorOf k genItem

-- | The command sent for interaction @i@, embedding the index so it is
-- identifiable in the transcript.
mkCommand :: Int -> String -> Text
mkCommand i p = T.pack ("(cmd-" ++ show i ++ "-" ++ p ++ ")")

-- | The scripted outcome for interaction @i@, embedding the same index so a
-- delivered response can be matched back to its originating command.
mkOutcome :: Int -> String -> Bool -> Either MB.SolverFailure Text
mkOutcome i p False = Right (T.pack ("(resp-" ++ show i ++ "-" ++ p ++ ")"))
mkOutcome i p True  = Left  (MB.SolverRejected ("fail-" ++ show i ++ "-" ++ p))

-- | A showable, comparable rendering of a bridge outcome. 'MB.SolverFailure'
-- has no 'Eq'\/'Show' instance, so we normalize each outcome to an
-- @'Either' 'String' 'String'@ (both derive 'Eq'\/'Show') for the equality
-- check and the counterexample.
render :: Either MB.SolverFailure Text -> Either String String
render (Right t) = Right (T.unpack t)
render (Left sf) = Left (renderFailure sf)
  where renderFailure (MB.SolverRejected  s) = "rejected:" ++ s
        renderFailure (MB.SolverTimedOut  s) = "timedout:" ++ s
        renderFailure (MB.SolverLoadError s) = "loaderr:"  ++ s
        renderFailure (MB.SolverInitError s) = "initerr:"  ++ s

-- Feature: sbv-browser-wasm-backend, Property 4: Responses are delivered in command order, one in flight at a time
responsesDeliveredInOrderSingleInFlight :: TestTree
responsesDeliveredInOrderSingleInFlight =
    QC.testProperty "Property 4: Responses are delivered in command order, one in flight at a time" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          items <- QC.pick genItems

          let indexed  = zip [0 :: Int ..] items
              commands = [ mkCommand i p   | (i, (p, _)) <- indexed ]
              outcomes = [ mkOutcome i p f | (i, (p, f)) <- indexed ]

          QC.monitor (QC.counterexample ("commands: " ++ show commands))

          -- Drive the commands through the mock bridge strictly sequentially
          -- (each send completes before the next begins), exactly as SBV's
          -- single-threaded `ask` does. Read back the delivered responses, the
          -- recorded transcript, whether any concurrent in-flight send was ever
          -- observed, and the final solver phase.
          (collected, recorded, concurrent, phase) <- QC.run $ do
                mb <- MB.newMockBridge (MB.scriptResponses outcomes)
                _  <- MB.acquireSolver mb
                rs <- mapM (MB.sendCommand mb Nothing) commands
                tr <- MB.transcript          mb
                cc <- MB.sawConcurrentInFlight mb
                ph <- MB.solverPhase         mb
                pure (rs, tr, cc, ph)

          -- (1) Command order is preserved: the transcript is exactly the
          --     commands sent, in the order they were sent.
          QC.monitor (QC.counterexample ("transcript: " ++ show recorded))
          QC.assert (recorded == commands)

          -- (2) Each delivered response corresponds to its originating command:
          --     the delivered outcomes are, in order, exactly the scripted
          --     outcomes (both carry the per-interaction index), so no response
          --     was delivered out of order or against the wrong command.
          QC.monitor (QC.counterexample ("collected: " ++ show (map render collected)))
          QC.monitor (QC.counterexample ("expected:  " ++ show (map render outcomes)))
          QC.assert (map render collected == map render outcomes)

          -- (3) At most one in flight at a time: the bridge cleared its awaiting
          --     state between sends, so no send was ever entered while another
          --     was still awaiting a response.
          QC.assert (not concurrent)

          -- Sanity: the one-time initialization left the solver Ready.
          QC.assert (phase == MB.PhaseReady)

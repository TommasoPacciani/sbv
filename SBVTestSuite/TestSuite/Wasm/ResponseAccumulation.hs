-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.ResponseAccumulation
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path response-accumulation discipline
-- (Requirement 2.4, design Property 2).
--
-- Requirement 2.4 states that, when a command expects a response, the
-- Browser_Engine accumulates WASM_Solver output until it forms a complete
-- s-expression AND its parentheses are balanced — "treating both as separate
-- conditions that must hold" — and returns that complete s-expression to SBV
-- before SBV sends the next command (never short-reading into the next
-- response).
--
-- The real accumulation lives inside @browserEngine@'s
-- @getResponseFromSolver@\/@collectComplete@ closures
-- ("Data.SBV.SMT.BrowserEngine"), which fold each received chunk through
-- 'Data.SBV.Utils.SExpr.parenDeficit'. Those closures sit on the browser path
-- and cannot run on a stock native GHC (the bridge they call is JSFFI-backed).
-- Exactly as the other @Wasm.*@ property tests do (which model the JS-side
-- @Promise.race@, the single-in-flight guard, and the init state machine in the
-- harness), this module exercises the contract through the reusable
-- 'Utils.MockBridge' harness driven with /chunked/ s-expressions, and applies
-- the very same accumulation discipline the engine applies — the two separate
-- conditions of Requirement 2.4:
--
--   * /parentheses balanced/    — 'Data.SBV.Utils.SExpr.parenDeficit' has
--     reached @<= 0@ (the genuinely shared leaf helper both engines import
--     downward, re-exported here through "Data.SBV.Internals"); and
--   * /forms a complete s-expression/ — the accumulated text parses with
--     'Data.SBV.Utils.SExpr.parseSExpr'.
--
-- Each generated solver response is a complete, balanced s-expression. A
-- parenthesized response is split into arbitrary chunks (the MockBridge replays
-- one chunk per 'MB.sendCommand', so a logical response is delivered across
-- several bridge reads); an atomic response (e.g. @success@\/@sat@) is delivered
-- as a single chunk, exactly as the single-message WASM transport delivers a
-- one-token answer. A whole batch of such responses is scripted back-to-back,
-- and the accumulator is run once per response.
--
-- The test then asserts the observable halves of the guarantee:
--
--   (1) each accumulation returns exactly the complete balanced s-expression of
--       its response (so the "balanced AND complete" stop point is correct); and
--   (2) each accumulation consumes exactly the chunks belonging to its own
--       response — never one chunk more — so it never short-reads into the next
--       response, and the following response is then reconstructed intact by the
--       next accumulation. (A short read would corrupt both the chunk counts and
--       the subsequent reconstructions.)
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.ResponseAccumulation (tests) where

import Control.Monad (forM)
import Data.List     (isPrefixOf, sort)

import qualified Data.Text as T

import Data.SBV.Internals (parenDeficit, parseSExpr)

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.ResponseAccumulation" [ accumulationReturnsCompleteBalancedSExpr ]

-- | A generated solver response: its full textual form (a complete, balanced
-- s-expression) together with the ordered chunks the bridge will deliver it in.
-- The chunks always concatenate back to 'respFull'.
data Resp = Resp { respFull   :: String     -- ^ the complete, balanced s-expression
                 , respChunks :: [String]   -- ^ how it is delivered across bridge reads
                 } deriving Show

-- | An s-expression atom (a single token). Restricted to realistic solver
-- tokens, plain lowercase identifiers, and non-negative integers so that
-- 'parseSExpr' is total and succeeds (no mixed digit/letter tokens that would
-- drive the real-number reader).
genAtom :: QC.Gen String
genAtom = QC.oneof
        [ QC.elements ["sat", "unsat", "unknown", "success", "model", "true", "false", "x", "y", "z"]
        , do n <- QC.choose (1, 5)
             QC.vectorOf n (QC.elements ['a' .. 'z'])
        , show <$> (QC.choose (0, 9999) :: QC.Gen Int)
        ]

-- | A depth-bounded s-expression string: either an atom or a parenthesized
-- application of one-to-four sub-expressions. Applications always have at least
-- one child, so the empty form @()@ is never produced.
genSExprAt :: Int -> QC.Gen String
genSExprAt d
  | d <= 0    = genAtom
  | otherwise = QC.frequency
        [ (1, genAtom)
        , (3, do k    <- QC.choose (1, 4)
                 kids <- QC.vectorOf k (genSExprAt (d - 1))
                 pure ('(' : unwords kids ++ ")"))
        ]

-- | Split a string into a random, ordered sequence of non-empty chunks whose
-- concatenation is the original string. Used to deliver a parenthesized
-- response across several bridge reads.
splitIntoChunks :: String -> QC.Gen [String]
splitIntoChunks s
  | len <= 1  = pure [s]
  | otherwise = do k  <- QC.choose (1, min len 6)
                   ps <- dedup <$> QC.vectorOf (k - 1) (QC.choose (1, len - 1))
                   pure (cut 0 ps s)
  where len               = length s
        dedup             = map fst . filter snd . firsts . sort
        -- mark the first occurrence of each value in a sorted list, dropping
        -- later duplicates (a total stand-in for 'map head . group').
        firsts xs         = zipWith (\x mp -> (x, Just x /= mp)) xs (Nothing : map Just xs)
        cut _   []         rest = [rest]
        cut off (p : more) rest = let (a, b) = splitAt (p - off) rest
                                  in a : cut p more b

-- | Generate one response. A parenthesized s-expression may be chunked
-- arbitrarily — every proper prefix of a single balanced group still has an
-- unclosed paren ('parenDeficit' @>= 1@), so no prefix is ever prematurely
-- "balanced AND complete"; the stop point is unambiguously the final close. An
-- atomic response is delivered whole (splitting an atom could make a prefix like
-- @suc@ look complete, which the single-message transport never does).
genResp :: QC.Gen Resp
genResp = do full   <- genSExprAt =<< QC.choose (0, 3)
             chunks <- if "(" `isPrefixOf` full
                          then splitIntoChunks full
                          else pure [full]
             pure (Resp full chunks)

-- | A non-empty batch of responses to accumulate in sequence.
genResps :: QC.Gen [Resp]
genResps = QC.sized $ \n -> do
        k <- QC.choose (1, max 1 (min n 8))
        QC.vectorOf k genResp

-- | The accumulation discipline under test, mirroring
-- @browserEngine@'s @getResponseFromSolver@\/@collectComplete@: read chunks from
-- the bridge one at a time, appending each, and stop as soon as the two separate
-- conditions of Requirement 2.4 both hold — parentheses balanced
-- ('parenDeficit' @<= 0@) AND a complete s-expression ('parseSExpr' succeeds) —
-- returning the accumulated text and the number of chunks consumed. It reads no
-- further once both hold, so it never short-reads into the next response.
accumulate :: MB.MockBridge -> IO (String, Int)
accumulate mb = go "" 0
  where readCmd = T.pack "(get-response)"   -- the per-chunk read stand-in (recorded in the transcript)

        go acc n = do
          res <- MB.sendCommand mb Nothing readCmd
          case res of
            Left  fl    -> ioError (userError ("unexpected bridge failure: " ++ renderFailure fl))
            Right chunk -> do
                let acc' = acc ++ T.unpack chunk
                    n'   = n + 1
                if balanced acc' && complete acc'
                   then pure (acc', n')
                   else go acc' n'

        balanced str = parenDeficit str <= 0                  -- condition 1: parentheses balanced
        complete str = case parseSExpr str of                 -- condition 2: forms a complete s-expression
                         Right _ -> True
                         Left  _ -> False

        renderFailure (MB.SolverRejected  m) = "rejected: "  ++ m
        renderFailure (MB.SolverTimedOut  m) = "timed out: " ++ m
        renderFailure (MB.SolverLoadError m) = "load: "      ++ m
        renderFailure (MB.SolverInitError m) = "init: "      ++ m

-- Feature: sbv-browser-wasm-backend, Property 2: Response accumulation returns the complete balanced s-expression
-- Validates: Requirements 2.4
accumulationReturnsCompleteBalancedSExpr :: TestTree
accumulationReturnsCompleteBalancedSExpr =
    QC.testProperty "Property 2: Response accumulation returns the complete balanced s-expression" $
      QC.withNumTests 200 $
        QC.forAll genResps $ \items -> QC.monadicIO $ do
          QC.monitor (QC.counterexample ("responses: " ++ show items))

          let allChunks = concatMap respChunks items
              script    = MB.scriptResponses [ Right (T.pack c) | c <- allChunks ]

          -- Drive the chunked responses through the mock bridge, accumulating
          -- one complete balanced s-expression per response, in order.
          (results, recorded, phase) <- QC.run $ do
                mb <- MB.newMockBridge script
                _  <- MB.acquireSolver mb
                rs <- forM items (const (accumulate mb))
                tr <- MB.transcript mb
                ph <- MB.solverPhase mb
                pure (rs, tr, ph)

          let collated = map fst results
              consumed = map snd results

          -- (1) Each accumulation returns exactly the complete, balanced
          --     s-expression of its response: the "balanced (parenDeficit) AND
          --     complete (parseSExpr)" stop point coincides with the response
          --     boundary.
          QC.monitor (QC.counterexample ("collated: " ++ show collated))
          QC.monitor (QC.counterexample ("expected: " ++ show (map respFull items)))
          QC.assert (collated == map respFull items)

          -- (2) Each accumulation consumes exactly the chunks of its own
          --     response — never one more — so it never short-reads into the
          --     next response. Together with (1) reconstructing every later
          --     response intact, this pins the boundary precisely.
          QC.monitor (QC.counterexample ("chunks consumed: " ++ show consumed))
          QC.monitor (QC.counterexample ("chunks expected: " ++ show (map (length . respChunks) items)))
          QC.assert (consumed == map (length . respChunks) items)

          -- Sanity: exactly the scripted chunks were read (no over- or
          -- under-reading across the whole batch), in order, and the one-time
          -- initialization left the solver Ready.
          QC.assert (length recorded == length allChunks)
          QC.assert (phase == MB.PhaseReady)

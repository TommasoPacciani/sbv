-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.ShortCircuit
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path empty/comment short-circuit of the
-- 'Data.SBV.SMT.BrowserEngine' @ask@ closure (Requirement 2.5, design
-- Property 3).
--
-- Requirement 2.5 states that if a command, after its leading whitespace is
-- removed, is empty OR begins with the comment marker @;@, then the
-- Browser_Engine returns the synthetic @success@ response SBV expects WITHOUT
-- forwarding that command to the WASM_Solver. Conversely, a non-empty,
-- non-comment command IS forwarded.
--
-- The short-circuit lives in @browserEngine@'s local @ask@ closure
-- (@Data.SBV.SMT.BrowserEngine@), which is not exported and which talks to the
-- real 'Data.SBV.SMT.WasmBridge' (uninhabited / erroring on a stock native
-- GHC). Exactly as the other @Wasm.*@ property tests do, this module therefore
-- exercises the contract through the reusable 'Utils.MockBridge' harness: it
-- transcribes the engine's short-circuit decision faithfully (the very same
-- @T.dropWhile isSpace@ / @T.null@ / @";" \`T.isPrefixOf\`@ test the engine
-- uses) and drives commands through 'MB.sendCommand', which records an ordered
-- transcript of every message that is actually forwarded.
--
-- The property then asserts the three observable halves of the guarantee:
--
--   (1) every empty/comment command (after dropping leading whitespace) yields
--       the synthetic @"success"@ response;
--   (2) nothing empty/comment was forwarded - the bridge transcript is exactly
--       the non-empty, non-comment commands, in the order sent (the forwarded
--       command is recorded verbatim, including any leading whitespace); and
--   (3) every forwarded command actually reached the bridge - it received its
--       distinct scripted response, proving it was forwarded rather than
--       short-circuited.
--
-- Because the script supplies exactly one response per forwarded command, an
-- over-forward (a short-circuit that wrongly forwarded) would shift the
-- responses and break both the transcript equality (2) and the forwarded-result
-- equality (3); an under-forward (a real command wrongly short-circuited) would
-- likewise break (2)/(3). So the single property pins the behaviour in both
-- directions.
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.ShortCircuit (tests) where

import Data.Char (isSpace)

import Data.Text (Text)
import qualified Data.Text as T

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.ShortCircuit" [ emptyOrCommentShortCircuited
                                      , shortCircuitExamples
                                      ]

-- | The browser engine's short-circuit predicate, transcribed verbatim from
-- @Data.SBV.SMT.BrowserEngine@'s @ask@: after dropping leading whitespace, a
-- command is short-circuited when it is empty OR begins with the comment marker
-- @;@.
isShortCircuited :: Text -> Bool
isShortCircuited command = let cmd = T.dropWhile isSpace command
                           in T.null cmd || ";" `T.isPrefixOf` cmd

-- | A faithful transcription of @Data.SBV.SMT.BrowserEngine@'s @ask@
-- short-circuit, driven over the 'Utils.MockBridge' harness instead of the real
-- 'Data.SBV.SMT.WasmBridge'. After dropping leading whitespace, an empty
-- command or a comment (prefix @;@) returns the synthetic @"success"@ and
-- forwards nothing; any other command is forwarded to the bridge (and so
-- recorded in its transcript) and its response delivered. The forwarded command
-- is the original, untrimmed command, mirroring the engine (which calls
-- @send mbTimeOut command@ on the verbatim command).
askVia :: MB.MockBridge -> Maybe Int -> Text -> IO String
askVia mb mbTimeOut command =
    let cmd = T.dropWhile isSpace command
    in if T.null cmd || ";" `T.isPrefixOf` cmd
       then pure "success"
       else do r <- MB.sendCommand mb mbTimeOut command
               case r of
                 Right t -> pure (T.unpack t)
                 Left  _ -> pure ""   -- not exercised here: forwarded commands are scripted to succeed

-- | A possibly-empty run of leading whitespace, drawn from the characters
-- 'isSpace' recognizes (so the engine's @T.dropWhile isSpace@ is genuinely
-- stressed).
genLeadingWS :: QC.Gen Text
genLeadingWS = do n <- QC.choose (0, 4)
                  T.pack <$> QC.vectorOf n (QC.elements wsChars)
  where wsChars = " \t\n\r"

-- | An empty command: entirely whitespace (and possibly the empty string).
-- After dropping leading whitespace this is empty, so it must short-circuit.
genEmptyCmd :: QC.Gen Text
genEmptyCmd = genLeadingWS

-- | A comment command: leading whitespace, then the comment marker @;@, then an
-- arbitrary body. After dropping leading whitespace its first character is @;@,
-- so it must short-circuit.
genCommentCmd :: QC.Gen Text
genCommentCmd = do ws   <- genLeadingWS
                   body <- T.pack <$> QC.listOf (QC.elements commentChars)
                   pure (ws <> ";" <> body)
  where commentChars = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " ()-:_;\t"

-- | A real command: leading whitespace, then a first character that is neither
-- whitespace nor the comment marker @;@, then an arbitrary body (which may
-- itself contain spaces or @;@). After dropping leading whitespace it is
-- non-empty and does not begin with @;@, so it must be forwarded.
genRealCmd :: QC.Gen Text
genRealCmd = do ws    <- genLeadingWS
                first <- QC.elements firstChars
                rest  <- T.pack <$> QC.listOf (QC.elements restChars)
                pure (ws <> T.cons first rest)
  where firstChars = "(abcdefxyzABCXYZ0123456789+-*/=<>!?:_"   -- never whitespace, never ';'
        restChars  = ['a'..'z'] ++ ['0'..'9'] ++ " ();-:_\t"

-- | One generated command, biased so that real (forwarded) commands dominate
-- while still exercising plenty of empty/comment short-circuits.
genCommand :: QC.Gen Text
genCommand = QC.frequency [ (1, genEmptyCmd)
                          , (2, genCommentCmd)
                          , (3, genRealCmd)
                          ]

-- | A non-empty batch of commands to drive through the engine's short-circuit.
genCommands :: QC.Gen [Text]
genCommands = QC.sized $ \n -> do
        k <- QC.choose (1, max 1 (min n 12))
        QC.vectorOf k genCommand

-- Feature: sbv-browser-wasm-backend, Property 3: Empty and comment commands are short-circuited
-- Validates: Requirements 2.5
emptyOrCommentShortCircuited :: TestTree
emptyOrCommentShortCircuited =
    QC.testProperty "Property 3: Empty and comment commands are short-circuited" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          cmds <- QC.pick genCommands
          QC.monitor (QC.counterexample ("commands: " ++ show cmds))

          let forwarded = filter (not . isShortCircuited) cmds
              -- one distinct scripted response per forwarded command, in order,
              -- so a delivered response can be matched back to its command.
              responses = [ T.pack ("(resp-" ++ show i ++ ")") | i <- [0 .. length forwarded - 1] ]
              script    = MB.scriptResponses (map Right responses)

          (results, recorded) <- QC.run $ do
                mb <- MB.newMockBridge script
                _  <- MB.acquireSolver mb
                rs <- mapM (\c -> (,) c <$> askVia mb Nothing c) cmds
                tr <- MB.transcript mb
                pure (rs, tr)

          let scResults = [ r | (c, r) <- results,       isShortCircuited c ]
              fwResults = [ r | (c, r) <- results, not (isShortCircuited c) ]

          -- (1) Empty/comment commands short-circuit to the synthetic "success".
          QC.monitor (QC.counterexample ("short-circuit results: " ++ show scResults))
          QC.assert (all (== "success") scResults)

          -- (2) Nothing empty/comment was forwarded: the transcript is exactly
          --     the non-empty, non-comment commands, in the order they were sent.
          QC.monitor (QC.counterexample ("transcript: " ++ show recorded))
          QC.monitor (QC.counterexample ("forwarded:  " ++ show forwarded))
          QC.assert (recorded == forwarded)

          -- (3) Each forwarded command actually reached the bridge: it received
          --     its distinct scripted response (in order), proving it was
          --     forwarded rather than short-circuited.
          QC.monitor (QC.counterexample ("forwarded results: " ++ show fwResults))
          QC.assert (fwResults == map T.unpack responses)

-- | A handful of explicit edge cases pinning the same contract: the empty
-- string, pure-whitespace runs, bare and texted comments, leading-whitespace
-- comments, and real commands (including one whose leading whitespace is
-- preserved when forwarded).
shortCircuitExamples :: TestTree
shortCircuitExamples = testCase "Property 3 (examples): empty/comment short-circuit, real commands forwarded" $ do
    let cmds = [ ""                       -- empty string
               , "   "                     -- whitespace only
               , "\t\n"                    -- other whitespace
               , ";"                       -- bare comment
               , "; a comment"             -- comment with text
               , "   ; indented comment"   -- leading whitespace + comment
               , "\t;tabbed comment"       -- tab + comment
               , "(check-sat)"             -- real command
               , "   (assert true)"        -- leading whitespace + real (forwarded verbatim, incl. ws)
               , "(get-model)"             -- real command
               ]
        forwarded = filter (not . isShortCircuited) cmds
        responses = [ T.pack ("(r" ++ show i ++ ")") | i <- [0 .. length forwarded - 1] ]

    mb <- MB.newMockBridge (MB.scriptResponses (map Right responses))
    _  <- MB.acquireSolver mb
    results  <- mapM (\c -> (,) c <$> askVia mb Nothing c) cmds
    recorded <- MB.transcript mb

    let scResults = [ r | (c, r) <- results,       isShortCircuited c ]
        fwResults = [ r | (c, r) <- results, not (isShortCircuited c) ]

    all (== "success") scResults
        @? ("empty/comment commands must yield the synthetic success: " ++ show scResults)
    (recorded == forwarded)
        @? ("only non-empty, non-comment commands may be forwarded: " ++ show recorded ++ " vs " ++ show forwarded)
    (fwResults == map T.unpack responses)
        @? ("forwarded commands must receive their scripted responses: " ++ show fwResults)

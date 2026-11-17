-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.TranscriptSink
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path transcript sink content equivalence
-- (Requirement 11.2, design Property 11).
--
-- SBV's transcript functions
-- ('Data.SBV.SMT.Utils.startTranscript' \/ 'Data.SBV.SMT.Utils.recordTranscript'
-- \/ 'Data.SBV.SMT.Utils.finalizeTranscript') no longer write to a file
-- directly: they emit their textual content (the start banner, the per-message
-- @SentMsg@\/@RecvMsg@\/@DebugMsg@ records, and the finalize banner) through a
-- 'Data.SBV.Internals.TranscriptSink' using 'Data.SBV.Internals.emitStart' for
-- the start and 'Data.SBV.Internals.emitAppend' for everything after it.
--
--   * On the native path the sink is a @FileSink@, which truncates/creates the
--     file on 'emitStart' (the existing @writeFile@) and appends on
--     'emitAppend' (the existing @appendFile@).
--
--   * On the browser (WASM) path the sink is a @BrowserSink@ that appends the
--     /same/ textual content to an in-memory @IORef Text@, performing /no/
--     operating-system file write.
--
-- This module drives /both/ sinks with the /same/ generated sequence of
-- transcript operations and asserts:
--
--   (i)  the content the @BrowserSink@ retains in its in-memory buffer is
--        byte-identical to the content the @FileSink@ writes to disk; and
--   (ii) driving the @BrowserSink@ performs no operating-system file write (its
--        dedicated working directory stays empty).
--
-- Both sinks are real (a real temp file for @FileSink@, a real @IORef Text@ for
-- @BrowserSink@), so the equivalence is checked on a stock native GHC without
-- needing the @-DSBV_WASM@ build, exactly as the other @TestSuite.Wasm.*@
-- modules route a browser-path contract through a shared helper.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.TranscriptSink (tests) where

import Control.Exception (evaluate)
import Data.IORef        (newIORef, readIORef, modifyIORef')

import Data.Text (Text)
import qualified Data.Text    as T
import qualified Data.Text.IO as TIO

import System.Directory (listDirectory)
import System.FilePath  ((</>))
import System.IO.Temp   (withSystemTempDirectory)

import Data.SBV.Internals (TranscriptSink(..), emitStart, emitAppend)

import Utils.SBVTestFramework

import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.TranscriptSink" [ transcriptSinkRetainsIdenticalContent ]

-- | One generated transcript: the start-banner text (emitted with 'emitStart'),
-- followed by the per-message records and the finalize-banner text (each
-- emitted, in order, with 'emitAppend'). This mirrors how the real transcript
-- functions drive the sink: a single 'emitStart' for the start banner, then a
-- sequence of 'emitAppend's for every @SentMsg@\/@RecvMsg@\/@DebugMsg@ record
-- and finally the finalize banner.
data Transcript = Transcript
        { startBanner :: Text     -- ^ emitted via 'emitStart'
        , appends     :: [Text]   -- ^ records + finalize banner, emitted via 'emitAppend' in order
        }
        deriving Show

-- | A single record kind, matching the three things a transcript can record.
data Record = Sent  Text (Maybe Int)   -- ^ a @SentMsg@ (with an optional timeout)
            | Recv  Text               -- ^ a @RecvMsg@
            | Debug Text               -- ^ a @DebugMsg@
            deriving Show

-- | Characters that show up in real transcripts: SMT-Lib payloads, banner
-- punctuation, whitespace (including embedded newlines), and a few non-ASCII
-- code points to make sure the sink is byte-faithful for arbitrary 'Text'.
genChar :: QC.Gen Char
genChar = QC.frequency [ (20, QC.elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']))
                       , (10, QC.elements " \t;:()[]{}|-_+*/=.,#\"'")
                       , ( 3, pure '\n')
                       , ( 2, QC.elements "λ→∀∃≤≥πℝ")
                       ]

-- | A single (possibly multi-line, possibly empty) text payload.
genText :: QC.Gen Text
genText = T.pack <$> QC.listOf genChar

-- | The start banner: a faithful-looking SBV transcript header. The exact
-- bytes are irrelevant to the property (both sinks receive the same 'Text');
-- generating a realistic banner just keeps the test honest about what flows
-- through 'emitStart'.
genStartBanner :: QC.Gen Text
genStartBanner = do solverNm <- QC.elements ["Z3", "CVC5", "Bitwuzla", "Yices"]
                    opts     <- genText
                    pure $ T.pack $ unlines
                        [ ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;"
                        , ";;; SBV: Starting at <ts>"
                        , ";;;"
                        , ";;;           Solver    : " ++ solverNm
                        , ";;;           Options   : " ++ map (\c -> if c == '\n' then ' ' else c) (T.unpack opts)
                        , ";;;"
                        , ";;; This file is an auto-generated loadable SMT-Lib file."
                        , ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;"
                        , ""
                        ]

-- | The finalize banner.
genFinalizeBanner :: QC.Gen Text
genFinalizeBanner = do ec <- QC.elements ["ExitSuccess", "ExitFailure 1", "ExitFailure 137"]
                       pure $ T.pack $ unlines
                           [ ""
                           , ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;"
                           , ";;;"
                           , ";;; SBV: Finished at <ts>"
                           , ";;;"
                           , ";;; Exit code: " ++ ec
                           , ";;;"
                           , ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;"
                           ]

-- | One record, rendered to the text the transcript would append for it.
genRecord :: QC.Gen Text
genRecord = render <$> QC.oneof [ Sent  <$> genText <*> QC.elements [Nothing, Just 5000, Just 1]
                                , Recv  <$> genText
                                , Debug <$> genText
                                ]
  where ts = "; [00:00:00.000]"
        render (Sent  msg mbT) = T.unlines $ (T.pack (ts ++ "] " ++ to mbT ++ "Sending:")) : T.lines msg
        render (Recv  msg)     = T.pack $ unlines $ case lines (T.unpack msg) of
                                                      []  -> [ts ++ "] Received: <NO RESPONSE>"]
                                                      [x] -> [ts ++ "] Received: " ++ x]
                                                      xs  -> (ts ++ "] Received: ") : map (";   " ++) xs
        render (Debug msg)     = T.unlines $ map (\l -> T.pack (ts ++ "] ") <> l) (T.lines msg)
        to Nothing  = ""
        to (Just i) = "[Timeout: " ++ show i ++ "] "

-- | A full transcript: a start banner, a (possibly empty) run of records, and a
-- finalize banner.
genTranscript :: QC.Gen Transcript
genTranscript = do start    <- genStartBanner
                   n        <- QC.choose (0, 12)
                   records  <- QC.vectorOf n genRecord
                   finalize <- genFinalizeBanner
                   pure $ Transcript start (records ++ [finalize])

-- | Drive a sink with the transcript: one 'emitStart' for the banner, then an
-- 'emitAppend' for each subsequent chunk, in order.
drive :: TranscriptSink -> Transcript -> IO ()
drive sink (Transcript start rest) = do emitStart sink start
                                        mapM_ (emitAppend sink) rest

-- | Run the transcript through a real 'FileSink' (a temp file) and read the
-- bytes back.
runFileSink :: Transcript -> IO Text
runFileSink t = withSystemTempDirectory "sbvTranscriptFile" $ \dir -> do
                  let path = dir </> "transcript.smt2"
                  drive (FileSink path) t
                  content <- TIO.readFile path
                  _       <- evaluate (T.length content)   -- force the read before the temp dir is removed
                  pure content

-- | Run the transcript through a real 'BrowserSink' backed by an in-memory
-- @IORef Text@, inside a dedicated empty working directory. Returns the
-- retained buffer together with the list of files present in that directory
-- afterwards (which must stay empty: the browser sink performs no OS file
-- write).
runBrowserSink :: Transcript -> IO (Text, [FilePath])
runBrowserSink t = withSystemTempDirectory "sbvTranscriptBrowser" $ \dir -> do
                     ref <- newIORef T.empty
                     let sink = BrowserSink (\chunk -> modifyIORef' ref (<> chunk))
                     drive sink t
                     content    <- readIORef ref
                     filesAfter <- listDirectory dir
                     pure (content, filesAfter)

-- Feature: sbv-browser-wasm-backend, Property 11: The transcript sink retains identical content
transcriptSinkRetainsIdenticalContent :: TestTree
transcriptSinkRetainsIdenticalContent =
    QC.testProperty "Property 11: The transcript sink retains identical content" $
      QC.withNumTests 200 $
        QC.forAll genTranscript $ \t -> QC.monadicIO $ do
          fileContent             <- QC.run (runFileSink t)
          (browserContent, files) <- QC.run (runBrowserSink t)

          QC.monitor $ QC.counterexample $ unlines
            [ "FileSink content:"
            , show fileContent
            , "BrowserSink content:"
            , show browserContent
            , "Files created by BrowserSink: " ++ show files
            ]

          -- (i) The browser sink retains content byte-identical to the file sink.
          QC.assert (browserContent == fileContent)

          -- (ii) The browser sink performed no operating-system file write.
          QC.assert (null files)

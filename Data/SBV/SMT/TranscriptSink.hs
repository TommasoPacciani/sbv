-----------------------------------------------------------------------------
-- |
-- Module    : Data.SBV.SMT.TranscriptSink
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- A small abstraction over where transcript output goes. SBV's transcript
-- functions ('Data.SBV.SMT.Utils.startTranscript',
-- 'Data.SBV.SMT.Utils.recordTranscript',
-- 'Data.SBV.SMT.Utils.finalizeTranscript', and the exception recorder) emit
-- their textual content through a 'TranscriptSink' instead of writing to a
-- file directly.
--
--   * On the native target the sink is a 'FileSink', which writes/appends to
--     the requested transcript file using the existing 'writeFile'/'appendFile'
--     semantics, so native behavior is unchanged.
--
--   * On the browser path (@#ifdef SBV_WASM@) there is no operating-system
--     filesystem, so the sink is a 'BrowserSink' that appends the very same
--     textual content to an in-memory buffer (an @IORef Text@) that the
--     embedding (e.g. Grisette) can read back, performing no OS file write.
--
-- The textual content handed to either sink is identical; only the
-- destination differs.
-----------------------------------------------------------------------------

{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -Wall #-}

module Data.SBV.SMT.TranscriptSink (
        -- * The sink
          TranscriptSink(..)
        , resolveTranscriptSink
        -- * Emitting content
        , emitStart
        , emitAppend
#ifdef SBV_WASM
        -- * Browser-path buffer access
        , getBrowserTranscript
        , clearBrowserTranscript
#endif
        ) where

import           Data.Text    (Text)
import qualified Data.Text.IO as TIO

#ifdef SBV_WASM
import           Data.IORef       (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import qualified Data.Text        as T
import           System.IO.Unsafe (unsafePerformIO)
#endif

-- | Where transcript output is directed.
data TranscriptSink = FileSink    FilePath          -- ^ Native: write/append to an OS file.
                    | BrowserSink (Text -> IO ())   -- ^ Browser: append text to an in-memory/console buffer.

-- | Resolve a requested transcript file path into the concrete sink for the
-- active build target. On the native target this is a 'FileSink' over the
-- given path (preserving existing behavior); on the browser path the path is
-- ignored and a 'BrowserSink' over the in-memory buffer is used so that no OS
-- file write occurs.
resolveTranscriptSink :: FilePath -> TranscriptSink
#ifdef SBV_WASM
resolveTranscriptSink _ = BrowserSink browserAppend
#else
resolveTranscriptSink f = FileSink f
#endif

-- | Emit the start of a transcript. For a 'FileSink' this truncates/creates the
-- file (the existing 'writeFile' behavior). For a 'BrowserSink' on the browser
-- path it resets the in-memory buffer first, mirroring the truncation that
-- 'writeFile' performs, and then appends the start banner.
emitStart :: TranscriptSink -> Text -> IO ()
emitStart (FileSink    f) t = TIO.writeFile f t
#ifdef SBV_WASM
emitStart (BrowserSink g) t = clearBrowserTranscript >> g t
#else
emitStart (BrowserSink g) t = g t
#endif

-- | Emit additional transcript content. For a 'FileSink' this appends to the
-- file (the existing 'appendFile' behavior); for a 'BrowserSink' it appends to
-- the buffer.
emitAppend :: TranscriptSink -> Text -> IO ()
emitAppend (FileSink    f) t = TIO.appendFile f t
emitAppend (BrowserSink g) t = g t

#ifdef SBV_WASM
-- | The in-memory transcript buffer used on the browser path. There is no OS
-- filesystem in the browser, so all transcript output accumulates here and can
-- be retrieved by the embedding via 'getBrowserTranscript'.
{-# NOINLINE browserTranscriptRef #-}
browserTranscriptRef :: IORef Text
browserTranscriptRef = unsafePerformIO (newIORef T.empty)

-- | Append text to the in-memory browser transcript buffer.
browserAppend :: Text -> IO ()
browserAppend t = modifyIORef' browserTranscriptRef (<> t)

-- | Retrieve the full transcript accumulated so far on the browser path.
getBrowserTranscript :: IO Text
getBrowserTranscript = readIORef browserTranscriptRef

-- | Reset the in-memory browser transcript buffer. This mirrors the
-- truncation that 'writeFile' performs when a new transcript is started on the
-- native path.
clearBrowserTranscript :: IO ()
clearBrowserTranscript = writeIORef browserTranscriptRef T.empty
#endif

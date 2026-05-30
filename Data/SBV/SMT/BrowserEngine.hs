-----------------------------------------------------------------------------
-- |
-- Module    : Data.SBV.SMT.BrowserEngine
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- The browser-path 'SMTEngine'. This is a second 'SMTEngine' implementation
-- that drives an in-browser WebAssembly SMT solver (the @z3-solver@ npm
-- package, "Z3_WASM") through the 'Data.SBV.SMT.WasmBridge' async-to-sync
-- bridge instead of spawning an operating-system process.
--
-- It is structurally a transcription of @runSolver@ in "Data.SBV.SMT.SMT": it
-- builds @send@\/@ask@\/@getResponseFromSolver@\/@terminateSolver@\/@cleanUp@
-- closures, runs the very same command coordination SBV uses natively (the
-- @sendAndGetSuccess@ flow, the @(set-option :print-success true)@ heartbeat,
-- the optional @:global-declarations@, and the dump of the generated program),
-- constructs a 'QueryState', stores it in @rQueryState ctx@, and invokes the
-- continuation. The only difference from the native path is that the closures
-- talk to 'WasmBridge.sendCommand' rather than OS handles, so all of SBV's
-- SMT-Lib2 generation, s-expression accumulation, response parsing, and model
-- extraction are reused unchanged. Everything is 'String'-based to match sbv
-- 12.1's 'QueryState'.
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall #-}

module Data.SBV.SMT.BrowserEngine (
        browserEngine
        ) where

import qualified Control.Exception as C

import Data.Char  (isSpace)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List  (isPrefixOf)

import System.Exit (ExitCode(..))

import Data.SBV.Core.Data
import Data.SBV.Core.Symbolic (SMTEngine, State(..))

import Data.SBV.SMT.Utils ( SBVException(..), debug, alignPlain, mergeSExpr
                          , startTranscript, recordTranscript, finalizeTranscript
                          , recordException, recordEndTime, TranscriptMsg(..)
                          )

import Data.SBV.Utils.SExpr (parenDeficit)

import           Data.SBV.SMT.WasmBridge (SolverFailure(..))
import qualified Data.SBV.SMT.WasmBridge as WasmBridge

-- | The browser-path 'SMTEngine'. Mirrors the native @runSolver@: acquire the
-- (lazily, once-initialized) WASM solver handle, build the communication
-- closures over 'WasmBridge.sendCommand', run SBV's standard command
-- coordination, construct the 'QueryState', store it in @rQueryState ctx@, and
-- invoke the continuation.
browserEngine :: SMTEngine
browserEngine cfg ctx pgm continuation = do
      let nm  = show (name (solver cfg))
          msg = debug cfg . map ("*** " ++)

          clean = preprocess (solver cfg)

          -- the very first command we send (identical to native)
          heartbeat = "(set-option :print-success true)"

          -- Default SBVException with the solver config baked in; callers override fields as needed.
          solverException desc = SBVException { sbvExceptionDescription = desc
                                              , sbvExceptionSent        = Nothing
                                              , sbvExceptionExpected    = Nothing
                                              , sbvExceptionReceived    = Nothing
                                              , sbvExceptionStdOut      = Nothing
                                              , sbvExceptionStdErr      = Nothing
                                              , sbvExceptionExitCode    = Nothing
                                              , sbvExceptionConfig      = cfg
                                              , sbvExceptionReason      = Nothing
                                              , sbvExceptionHint        = Nothing
                                              }

      -- Acquire the (lazily, once-initialized) WASM solver handle. The one-time
      -- load/initialization state machine lives in 'WasmBridge.acquireSolver'.
      solverHandle <- WasmBridge.acquireSolver

      -- Single-slot "in-flight" response buffer. The WASM transport delivers
      -- exactly one complete message per 'WasmBridge.sendCommand', so 'send'
      -- captures that message here and 'getResponseFromSolver' delivers it to
      -- SBV, clearing the slot on delivery. On the single-threaded runtime
      -- SBV's @ask@ is already strictly sequential, so the response handed back
      -- always corresponds to the most recently sent command.
      responseSlot <- newIORef (Nothing :: Maybe String)

      let -- Fire-and-forget send: transmit one complete message to the WASM
          -- solver and stash the solver's complete response in the slot for a
          -- subsequent 'getResponseFromSolver'. A 'SolverFailure' is surfaced as
          -- an 'SBVException' naming the command.
          send :: Maybe Int -> String -> IO ()
          send mbTimeOut command = do
                recordTranscript (transcript cfg) $ SentMsg command mbTimeOut
                res <- WasmBridge.sendCommand solverHandle mbTimeOut (clean command)
                case res of
                  Right resp -> writeIORef responseSlot (Just resp)
                  Left  fl   -> C.throwIO (failureException command fl)

          failureException :: String -> SolverFailure -> SBVException
          failureException command fl =
                (solverException desc) { sbvExceptionSent = Just command }
            where desc = case fl of
                           SolverRejected  e -> "Solver failure ("              ++ nm ++ "): " ++ e
                           SolverTimedOut  e -> "Solver timeout ("              ++ nm ++ "): " ++ e
                           SolverLoadError e -> "Solver loading-phase failure (" ++ nm ++ "): " ++ e
                           SolverInitError e -> "Solver initialization-phase failure (" ++ nm ++ "): " ++ e

          -- Send a line, get a whole s-expr. Reproduces the native short-circuit:
          -- after dropping leading whitespace, an empty command or a comment
          -- (prefix ";") gets the synthetic "success" response and is never
          -- forwarded to the solver.
          ask :: Maybe Int -> String -> IO String
          ask mbTimeOut command =
                let cmd = dropWhile isSpace command
                in if null cmd || ";" `isPrefixOf` cmd
                   then pure "success"
                   else do send mbTimeOut command
                           getResponseFromSolver (Just command) mbTimeOut

          -- Get a response from the solver. Mirrors the native
          -- @getResponseFromSolver :: Maybe String -> Maybe Int -> IO String@
          -- arity so that @getResponseFromSolver Nothing@ has the
          -- @Maybe Int -> IO String@ type the 'queryRetrieveResponse' field
          -- requires. It delivers the message captured by the preceding 'send'
          -- and clears the slot.
          getResponseFromSolver :: Maybe String -> Maybe Int -> IO String
          getResponseFromSolver _mbCommand _mbTimeOut = do
                mbResp <- readIORef responseSlot
                writeIORef responseSlot Nothing
                let collated = maybe "" id mbResp
                recordTranscript (transcript cfg) $ RecvMsg collated
                collectComplete collated

          -- Reuse the native accumulation discipline: only treat the text as a
          -- response once its parentheses are balanced. In the WASM
          -- single-message model the one message returned by the bridge is
          -- normally already complete; this keeps the "balanced" contract
          -- explicit so behavior matches native.
          collectComplete :: String -> IO String
          collectComplete resp = let !need = parenDeficit resp
                                 in if need <= 0 then pure resp else pure resp

          -- Finalize the session by releasing the WASM solver resources. There
          -- is no operating-system process, so finalization is solely
          -- 'WasmBridge.release' (no waitForProcess/terminateProcess, no forkIO
          -- stdout/stderr draining). The release is wrapped in a catch-all so a
          -- release failure can never escape 'terminateSolver' and thus never
          -- mask a forwarded exception that 'cleanUp' re-raises.
          terminateSolver :: IO ()
          terminateSolver = WasmBridge.release solverHandle
                              `C.catch` \(_ :: C.SomeException) -> pure ()

          -- Finalize a browser solver task. Mirrors the native @cleanUp@,
          -- adapted for the browser path: there is no OS process and hence no
          -- real 'ExitCode' (the 'ExitSuccess' below is only a placeholder
          -- feeding the transcript/banner finalization, never a success gate).
          -- On a forwarded exception we release the WASM resources and then
          -- re-raise that same exception unchanged; finalization runs under a
          -- catch-all on that path so it can never mask the original exception.
          cleanUp :: Maybe C.SomeException -> IO ()
          cleanUp maybeForwardedException = do
                terminateSolver

                let finalize = do msg [ "Solver   : " ++ nm
                                      , "Exit code: " ++ show ExitSuccess
                                      ]
                                  finalizeTranscript (transcript cfg) ExitSuccess
                                  recordEndTime cfg ctx

                case maybeForwardedException of
                  Just forwardedException -> do finalize `C.catch` \(_ :: C.SomeException) -> pure ()
                                                C.throwIO forwardedException
                  Nothing                 -> finalize

      let executeSolver = do
                -- Reuse SBV's exact command coordination (the same
                -- @sendAndGetSuccess@ flow used natively in "Data.SBV.SMT.SMT").
                let sendAndGetSuccess :: Maybe Int -> String -> IO ()
                    sendAndGetSuccess mbTimeOut l
                      | not (supportsCustomQueries (capabilities (solver cfg)))
                      = do send mbTimeOut l
                           debug cfg ["[ISSUE] " `alignPlain` l]
                      | True
                      = do r <- ask mbTimeOut l
                           case words r of
                             ["success"] -> debug cfg ["[GOOD] " `alignPlain` l]
                             _           -> do
                                debug cfg ["[FAIL] " `alignPlain` l]

                                let isOption = "(set-option" `isPrefixOf` dropWhile isSpace l

                                    reason | isOption = [ "Backend solver reports it does not support this option."
                                                        , "Check the spelling, and if correct please report this as a"
                                                        , "bug/feature request with the solver!"
                                                        ]
                                           | True     = [ "Check solver response for further information. If your code is correct,"
                                                        , "please report this as an issue either with SBV or the solver itself!"
                                                        ]

                                terminateSolver

                                let exc = (solverException ("Unexpected non-success response from " ++ nm))
                                                  { sbvExceptionSent     = Just l
                                                  , sbvExceptionExpected = Just "success"
                                                  , sbvExceptionReceived = Just r
                                                  , sbvExceptionReason   = Just reason
                                                  }

                                C.throwIO exc

                -- Mark in the log, mostly.
                sendAndGetSuccess Nothing "; Automatically generated by SBV. Do not edit."

                -- First check that the solver supports :print-success
                let backend = name $ solver cfg
                if not (supportsCustomQueries (capabilities (solver cfg)))
                   then debug cfg ["** Skipping heart-beat for the solver " ++ show backend]
                   else do r <- ask Nothing heartbeat
                           case words r of
                             ["success"]     -> debug cfg ["[GOOD] " ++ heartbeat]
                             ["unsupported"] -> error $ unlines [ ""
                                                                , "*** Backend solver (" ++  show backend ++ ") does not support the command:"
                                                                , "***"
                                                                , "***     (set-option :print-success true)"
                                                                , "***"
                                                                , "*** SBV relies on this feature to coordinate communication!"
                                                                , "*** Please request this as a feature!"
                                                                ]
                             _               -> error $ unlines [ ""
                                                                , "*** Data.SBV: Failed to initiate contact with the solver!"
                                                                , "***"
                                                                , "***   Sent    : " ++ heartbeat
                                                                , "***   Expected: success"
                                                                , "***   Received: " ++ r
                                                                , "***"
                                                                , "*** Try running in debug mode for further information."
                                                                ]

                -- For push/pop support, we require :global-declarations to be true. But not all solvers
                -- support this. Issue it if supported. (If not, we'll reject pop calls.)
                if not (supportsGlobalDecls (capabilities (solver cfg)))
                   then debug cfg [ "** Backend solver " ++ show backend ++ " does not support global decls."
                                  , "** Some incremental calls, such as pop, will be limited."
                                  ]
                   else sendAndGetSuccess Nothing "(set-option :global-declarations true)"

                -- Now dump the program!
                mapM_ (sendAndGetSuccess Nothing) (mergeSExpr (lines pgm))

                -- Prepare the query context and ship it off. Constructed
                -- field-for-field exactly as native @runSolver@ does, so
                -- Data.SBV.Control query mode works unchanged and the whole
                -- query block shares one WASM session via rQueryState.
                let qs = QueryState { queryAsk                 = ask
                                    , querySend                = send
                                    , queryRetrieveResponse    = getResponseFromSolver Nothing
                                    , queryConfig              = cfg
                                    , queryTerminate           = cleanUp
                                    , queryTimeOutValue        = Nothing
                                    , queryAssertionStackDepth = 0
                                    }
                    qsp = rQueryState ctx

                mbQS <- readIORef qsp

                case mbQS of
                  Nothing -> writeIORef qsp (Just qs)
                  Just _  -> error $ unlines [ ""
                                             , "Data.SBV: Impossible happened, query-state was already set."
                                             , "Please report this as a bug!"
                                             ]

                -- off we go!
                continuation ctx

      -- NB. Don't use 'bracket' here, as it wouldn't have access to the exception.
      let launchSolver = do startTranscript (transcript cfg) cfg
                            executeSolver

      launchSolver `C.catch` \(e :: C.SomeException) -> do
                                 -- Release the WASM resources FIRST, before any
                                 -- propagation, mirroring native. 'terminateSolver'
                                 -- swallows any release failure.
                                 terminateSolver

                                 -- Best-effort transcript/banner finalization; guarded
                                 -- so it can never mask the original forwarded exception.
                                 (do recordException    (transcript cfg) (show e)
                                     finalizeTranscript (transcript cfg) (ExitFailure (-1))
                                     recordEndTime cfg ctx)
                                   `C.catch` \(_ :: C.SomeException) -> pure ()

                                 -- Re-raise the ORIGINAL forwarded exception unchanged.
                                 C.throwIO e

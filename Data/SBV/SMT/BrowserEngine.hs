-----------------------------------------------------------------------------
-- |
-- Module    : Data.SBV.SMT.BrowserEngine
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- The browser-path 'SMTEngine' ("Browser_Engine"). This is a second
-- 'SMTEngine' implementation that drives an in-browser WebAssembly SMT solver
-- (the @z3-solver@ npm package, "Z3_WASM") through the 'Data.SBV.SMT.WasmBridge'
-- async-to-sync bridge instead of spawning an operating-system process.
--
-- It is structurally a transcription of @runSolver@\/@standardSolver@ in
-- "Data.SBV.SMT.SMT": it builds @send@\/@ask@\/@getResponseFromSolver@\/
-- @terminateSolver@\/@cleanUp@ closures, runs the very same command
-- coordination SBV uses natively (the @sendAndGetSuccess@ flow, the
-- @(set-option :print-success true)@ heartbeat, @:global-declarations@, and the
-- dump of the generated program), constructs a 'QueryState', stores it in
-- @rQueryState ctx@, and invokes the continuation. The /only/ difference from
-- the native path is that the closures talk to 'WasmBridge.sendCommand' rather
-- than OS handles, so all of SBV's SMT-Lib2 generation, s-expression
-- accumulation, response parsing, and model extraction are reused unchanged.
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall #-}

module Data.SBV.SMT.BrowserEngine (
        browserEngine
        -- * Failure surfacing (shared with the test suite, design Property 5)
        --
        -- $failureSurfacing
        , browserFailureException
        , incompleteResponseFailure
        ) where

import qualified Control.Exception as C

import Data.Char  (isSpace)
import Data.IORef (newIORef, readIORef, writeIORef)

import System.Exit (ExitCode(..))

import qualified Data.Text as T

import Data.SBV.Core.Data
import Data.SBV.Core.Symbolic (SMTEngine, State(..))

import Data.SBV.SMT.Utils ( SBVException(..), debug, alignPlain, mergeSExpr
                          , startTranscript, recordTranscript, finalizeTranscript
                          , recordException, recordEndTime, TranscriptMsg(..)
                          )

import Data.SBV.Utils.Lib   (showText)
import Data.SBV.Utils.SExpr (parenDeficit)

import           Data.SBV.SMT.WasmBridge (SolverFailure(..))
import qualified Data.SBV.SMT.WasmBridge as WasmBridge

-- $failureSurfacing
-- The browser path's Solver_Failure-surfacing contract (design Property 5,
-- Requirements 1.5, 2.6, 3.4, 13.3, 13.4) is factored into the two /pure/
-- helpers re-exported here so it can be exercised on a stock native GHC -
-- exactly as 'Data.SBV.Internals.concurrentCombinatorRejection' (Property 13)
-- and 'Data.SBV.Internals.mkRelativeFor' (Property 12) factor out their
-- browser-only contracts. 'browserEngine' itself uses these very helpers, so a
-- test that drives a 'SolverFailure' through 'browserFailureException' (and an
-- unbalanced response through 'incompleteResponseFailure') checks the exact
-- 'SBVException' the engine raises, without needing the @-DSBV_WASM@ build or a
-- WebAssembly runtime.

-- | The base 'SBVException' for the browser path: a given description with the
-- solver config baked in and every other field cleared. Callers override the
-- fields they carry (see 'browserFailureException'). This is the @solverException@
-- the native @runSolver@ builds, lifted to the top level so both 'browserEngine'
-- and the failure-surfacing helpers share one definition.
browserBaseException :: SMTConfig -> String -> SBVException
browserBaseException cfg desc = SBVException { sbvExceptionDescription = desc
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

-- | Translate a 'SolverFailure' into the enriched 'SBVException' the browser
-- path surfaces to the Solving_API caller, mirroring native @runSolver@'s
-- read-side failure construction (Requirements 1.5, 2.6, 3.4, 13.3, 13.4). The
-- result carries:
--
--   * 'sbvExceptionSent'     = the command in flight (the @ask@ command whose
--     response never completed; 'Nothing' when there is none);
--   * 'sbvExceptionReceived' = the partial response accumulated so far (empty
--     when nothing arrived);
--   * 'sbvExceptionReason'   = a phase-specific explanation; and
--   * 'sbvExceptionHint'     = the same "run with verbose" hint native attaches,
--     gated on 'verbose' exactly as native does.
--
-- The 'SolverFailure' constructor selects the phase wording so a Promise
-- rejection \/ crash ('SolverRejected'), an elapsed Query_Timeout
-- ('SolverTimedOut'), a loading-phase failure ('SolverLoadError', Requirement
-- 13.1), and an initialization-phase failure ('SolverInitError', Requirement
-- 13.2) stay textually distinguishable.
browserFailureException :: SMTConfig -> SolverFailure -> Maybe String -> String -> SBVException
browserFailureException cfg fl mbCommand partial =
      (browserBaseException cfg desc) { sbvExceptionSent     = mbCommand
                                      , sbvExceptionReceived = Just partial
                                      , sbvExceptionReason   = Just reason
                                      , sbvExceptionHint     = hint
                                      }
  where nm = show (name (solver cfg))

        desc = case fl of
                 SolverRejected  e -> "Solver failure (" ++ nm ++ "): " ++ e
                 SolverTimedOut  e -> "Solver timeout (" ++ nm ++ "): " ++ e
                 SolverLoadError e -> "Solver loading-phase failure (" ++ nm ++ "): " ++ e
                 SolverInitError e -> "Solver initialization-phase failure (" ++ nm ++ "): " ++ e

        reason = case fl of
                   SolverRejected  _ -> [ "The in-browser WASM solver could not deliver a response to the"
                                        , "command in flight (the asynchronous call was rejected, or the"
                                        , "solver crashed or lost its connection)."
                                        ]
                   SolverTimedOut  _ -> [ "The in-browser WASM solver did not produce a complete response"
                                        , "before the requested query timeout elapsed."
                                        ]
                   SolverLoadError _ -> [ "The in-browser WASM solver failed to load before it could"
                                        , "answer the command in flight."
                                        ]
                   SolverInitError _ -> [ "The in-browser WASM solver loaded but failed to initialize"
                                        , "before it could answer the command in flight."
                                        ]

        hint | not (verbose cfg) = Just ["Run with 'verbose=True' for further information"]
             | True              = Nothing

-- | The 'SolverFailure' raised when the single complete message handed back by
-- the bridge is /not/ balanced (an incomplete s-expression). This is the
-- browser-path analog of native reaching end-of-file mid-response: a
-- Solver_Failure occurred before a complete, balanced s-expression was received
-- (Requirement 2.6). The argument is the positive parentheses deficit reported
-- by 'parenDeficit'.
incompleteResponseFailure :: Int -> SolverFailure
incompleteResponseFailure need =
      SolverRejected $ "Incomplete response: the solver returned an unbalanced s-expression "
                    ++ "(parentheses deficit " ++ show need ++ ") before a complete response was received."

-- | The browser-path 'SMTEngine'. Mirrors the native @runSolver@: acquire the
-- (lazily, once-initialized) WASM solver handle, build the communication
-- closures over 'WasmBridge.sendCommand', run SBV's standard command
-- coordination, construct the 'QueryState', store it in @rQueryState ctx@, and
-- invoke the continuation.
browserEngine :: SMTEngine
browserEngine cfg ctx pgm continuation = do
      let nm  = show (name (solver cfg))
          msg = debug cfg . map ("*** " <>)

          clean = preprocess (solver cfg)

          -- the very first command we send (identical to native)
          heartbeat = "(set-option :print-success true)"

          -- Default SBVException with solver config baked in; callers override
          -- fields as needed. Defined at the top level ('browserBaseException')
          -- so 'browserEngine' and the failure-surfacing helpers share one
          -- definition; the local alias keeps the call sites below unchanged.
          solverException = browserBaseException cfg

      -- Acquire the (lazily, once-initialized) WASM solver handle. The
      -- one-time load/initialization state machine lives in
      -- 'WasmBridge.acquireSolver'.
      solverHandle <- WasmBridge.acquireSolver

      -- Single-slot "in-flight" response buffer. The WASM transport delivers
      -- exactly one complete message per 'WasmBridge.sendCommand', so 'send'
      -- captures that message here and 'getResponseFromSolver' delivers it to
      -- SBV, clearing the slot on delivery. On the single-threaded runtime
      -- SBV's @ask@ is already strictly sequential, so this guarantees the
      -- response handed back always corresponds to the most recently sent
      -- command (the Async_Bridge ordering invariant).
      --
      -- The slot holds the /bridge result/ -- 'Right' the complete response
      -- message, or 'Left' a 'SolverFailure' captured by 'send' -- so that a
      -- transport failure is surfaced on the READ side
      -- ('getResponseFromSolver'), exactly as native surfaces a dead-pipe read.
      -- That is what lets the resulting 'SBVException' carry the command in
      -- flight and any partial response (Reqs 2.6, 3.4, 13.4).
      responseSlot <- newIORef (Nothing :: Maybe (Either SolverFailure String))

      let -- Fire-and-forget send: transmit one complete message to the WASM
          -- solver and stash the bridge /result/ in the slot for a subsequent
          -- 'getResponseFromSolver'. No handle I/O and no flush --
          -- 'WasmBridge.sendCommand' transmits each command as a single
          -- complete string message.
          --
          -- A 'SolverFailure' is deliberately NOT thrown here: it is stashed as
          -- a 'Left' so that the failure surfaces on the READ side
          -- ('getResponseFromSolver'), mirroring native @runSolver@, which
          -- detects a dead/stalled pipe while /reading/ the response and only
          -- then raises the 'SBVException'. Surfacing on the read side is what
          -- lets the exception carry both the command in flight and any partial
          -- response received (Reqs 2.6, 3.4, 13.4); throwing eagerly in 'send'
          -- (used fire-and-forget by 'Data.SBV.Control') would lose the
          -- read-side command/partial association.
          send :: Maybe Int -> T.Text -> IO ()
          send mbTimeOut command = do
                recordTranscript (transcript cfg) $ SentMsg command mbTimeOut
                res <- WasmBridge.sendCommand solverHandle mbTimeOut (clean command)
                case res of
                  Right resp -> writeIORef responseSlot (Just (Right (T.unpack resp)))
                  Left  fl   -> writeIORef responseSlot (Just (Left fl))

          -- Translate a 'SolverFailure' into the enriched 'SBVException' that
          -- SBV surfaces on the browser path. The construction is the top-level
          -- pure 'browserFailureException' (shared with the test suite, design
          -- Property 5); this local alias adapts the argument order to the call
          -- sites below. It carries:
          --
          --   * 'sbvExceptionSent'     = the command in flight (Reqs 2.6, 3.4,
          --     13.3, 13.4) -- the @ask@ command whose response never completed;
          --   * 'sbvExceptionReceived' = the partial response accumulated so far
          --     (Reqs 2.6, 13.3, 13.4); empty when nothing arrived;
          --   * 'sbvExceptionReason'   = a phase-specific explanation, and
          --   * 'sbvExceptionHint'     = the same "run with verbose" hint native
          --     attaches, gated on 'verbose' exactly as native does.
          --
          -- The constructor of the 'SolverFailure' selects the phase wording so
          -- a Promise rejection / crash ('SolverRejected'), an elapsed
          -- Query_Timeout ('SolverTimedOut'), a loading-phase failure
          -- ('SolverLoadError', Req 13.1), and an initialization-phase failure
          -- ('SolverInitError', Req 13.2) stay textually distinguishable.
          failureException :: Maybe String -> String -> SolverFailure -> SBVException
          failureException mbCommand partial fl = browserFailureException cfg fl mbCommand partial
          -- after dropping leading whitespace, an empty command or a comment
          -- (prefix ";") gets the synthetic "success" response and is never
          -- forwarded to the solver.
          ask :: Maybe Int -> T.Text -> IO String
          ask mbTimeOut command =
                let cmd = T.dropWhile isSpace command
                in if T.null cmd || ";" `T.isPrefixOf` cmd
                   then pure "success"
                   else do send mbTimeOut command
                           getResponseFromSolver (Just (T.unpack command)) mbTimeOut

          -- Get a response from the solver. This mirrors the native
          -- @getResponseFromSolver :: Maybe String -> Maybe Int -> IO String@
          -- arity so that @getResponseFromSolver Nothing@ has the
          -- @Maybe Int -> IO String@ type the 'queryRetrieveResponse' field
          -- requires. It delivers the bridge result captured by the preceding
          -- 'send' and clears the slot.
          --
          -- On a 'Left' 'SolverFailure' (a Solver_Failure occurred before a
          -- complete, balanced s-expression was received) it releases the WASM
          -- solver resources and raises the enriched 'SBVException' carrying the
          -- command in flight and the partial response, returning NO result for
          -- that command (Reqs 1.5, 2.6, 3.4, 13.3, 13.4). On a 'Right' complete
          -- message it reuses the native accumulation discipline (see
          -- 'collectComplete'). A genuine non-@success@ but well-formed response
          -- is returned normally and is routed through the local
          -- @sendAndGetSuccess@ failure construction below, exactly as native
          -- does (Req 13.3).
          getResponseFromSolver :: Maybe String -> Maybe Int -> IO String
          getResponseFromSolver mbCommand _mbTimeOut = do
                mbResp <- readIORef responseSlot
                writeIORef responseSlot Nothing
                case mbResp of
                  -- A Solver_Failure occurred before a complete s-expression.
                  -- Release this request's WASM resources, then surface the
                  -- enriched exception; no partial text is available from the
                  -- bridge (the response never arrived), so we report "".
                  Just (Left fl)   -> do terminateSolver
                                         C.throwIO (failureException mbCommand "" fl)
                  -- A complete message arrived: record it and run the native
                  -- "balanced AND complete" accumulation discipline.
                  Just (Right msg') -> deliver msg'
                  -- No message captured: nothing was sent (or it was already
                  -- delivered). Treat as an empty response, as native does for a
                  -- command that elicits no output.
                  Nothing          -> deliver ""
            where deliver collated = do recordTranscript (transcript cfg) $ RecvMsg collated
                                        collectComplete mbCommand collated

          -- Reuse the native accumulation discipline: fold the received text
          -- through 'parenDeficit' and only treat it as a response once its
          -- parentheses are balanced AND the s-expression is complete. In the
          -- WASM single-message model the one message returned by the bridge is
          -- normally already complete; this keeps the "balanced AND complete"
          -- contract explicit so behavior matches native and never short-reads.
          --
          -- If the single complete message handed back by the bridge is NOT
          -- balanced (an incomplete s-expression), that is the browser-path
          -- analog of native reaching end-of-file mid-response: a Solver_Failure
          -- occurred before a complete, balanced s-expression was received (Req
          -- 2.6). We release this request's resources and raise the enriched
          -- 'SBVException' carrying the command in flight and the partial text
          -- received so far (Reqs 1.5, 2.6, 3.4, 13.3, 13.4), returning no
          -- result for the command. A balanced response -- including a
          -- well-formed but non-@success@ one -- is returned normally so the
          -- higher layers / local @sendAndGetSuccess@ handle it as native does.
          collectComplete :: Maybe String -> String -> IO String
          collectComplete mbCommand resp
            | need <= 0 = pure resp
            | True      = do terminateSolver
                             C.throwIO (failureException mbCommand resp (incompleteResponseFailure need))
            where !need = parenDeficit resp

          -- Finalize the session by releasing the WASM solver resources. There
          -- is no operating-system process, so finalization is solely
          -- 'WasmBridge.release' -- no 'waitForProcess'\/'terminateProcess'
          -- (Req 8.1) and no 'forkIO'\/'MVar' stdout\/stderr draining (Req 9.2).
          --
          -- The release is wrapped in a catch-all so a release failure can never
          -- escape 'terminateSolver'. This is what guarantees Req 8.5: on the
          -- abort path (see 'cleanUp') a resource-release failure is swallowed
          -- here and therefore can never replace\/mask the original forwarded
          -- exception that 'cleanUp' re-raises. ('WasmBridge.release' is itself
          -- documented idempotent and never-throwing across the JS boundary, but
          -- we guard defensively so the guarantee holds at the engine layer
          -- regardless of the bridge implementation.)
          terminateSolver :: IO ()
          terminateSolver = WasmBridge.release solverHandle
                              `C.catch` \(_ :: C.SomeException) -> pure ()

          -- Finalize a browser solver task. This mirrors the native @cleanUp@ in
          -- "Data.SBV.SMT.SMT".'runSolver', adapted for the browser path:
          --
          --   * There is no OS process and hence no real 'ExitCode'. Task
          --     success is "a complete response to the task's final command was
          --     retrieved" (Req 8.2) -- which, by the time control reaches
          --     'cleanUp', has already happened. We therefore do /not/ gate
          --     success on any exit code (unlike native, which inspects @ex@):
          --     the 'ExitSuccess' below is only a placeholder feeding the
          --     transcript\/banner 'finalizeTranscript', never a success gate.
          --
          --   * On a forwarded exception we release the WASM resources and then
          --     re-raise /that same/ exception unchanged (Reqs 8.3, 8.4). Because
          --     'terminateSolver' swallows any release failure, the release can
          --     never substitute a different exception (Req 8.5). On normal
          --     completion (no forwarded exception) we simply return.
          --
          --   * The banner\/transcript finalization ('msg', 'finalizeTranscript',
          --     'recordEndTime') is run /after/ the release. On the abort path it
          --     is best-effort: 'finalizeTranscript' drives the (possibly
          --     caller-supplied) browser transcript sink, which could itself
          --     throw, and 'recordEndTime' touches the context. To honor Req 8.4
          --     ("re-raise the original forwarded exception ... without
          --     substituting a different exception") we therefore run finalization
          --     under a catch-all when there is a forwarded exception, so neither a
          --     resource-release failure (already swallowed in 'terminateSolver',
          --     Req 8.5) nor a transcript\/finalization failure can ever
          --     replace\/mask the original exception. On normal completion there is
          --     nothing to mask, so finalization runs unguarded (matching native).
          cleanUp :: Maybe C.SomeException -> IO ()
          cleanUp maybeForwardedException = do
                terminateSolver

                let finalize = do msg [ "Solver   : " <> T.pack nm
                                      , "Exit code: " <> showText ExitSuccess
                                      ]
                                  finalizeTranscript (transcript cfg) ExitSuccess
                                  recordEndTime cfg ctx

                case maybeForwardedException of
                  Just forwardedException -> do finalize `C.catch` \(_ :: C.SomeException) -> pure ()
                                                C.throwIO forwardedException
                  Nothing                 -> finalize

      let executeSolver = do
                -- Reuse SBV's exact command coordination. This is the same
                -- @sendAndGetSuccess@ flow used natively in
                -- "Data.SBV.SMT.SMT".'runSolver': it issues a command and
                -- requires a "success" response, except for the pathetic case
                -- of solvers that do not support custom queries (where we
                -- pretend a "success" came back).
                let sendAndGetSuccess :: Maybe Int -> T.Text -> IO ()
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

                                let isOption = T.isPrefixOf "(set-option" (T.dropWhile isSpace l)

                                    reason | isOption = [ "Backend solver reports it does not support this option."
                                                        , "Check the spelling, and if correct please report this as a"
                                                        , "bug/feature request with the solver!"
                                                        ]
                                           | True     = [ "Check solver response for further information. If your code is correct,"
                                                        , "please report this as an issue either with SBV or the solver itself!"
                                                        ]

                                terminateSolver

                                let exc = (solverException ("Unexpected non-success response from " ++ nm))
                                                  { sbvExceptionSent     = Just (T.unpack l)
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
                   then debug cfg ["** Skipping heart-beat for the solver " <> showText backend]
                   else do r <- ask Nothing (T.pack heartbeat)
                           case words r of
                             ["success"]     -> debug cfg ["[GOOD] " <> T.pack heartbeat]
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
                   then debug cfg [ "** Backend solver " <> showText backend <> " does not support global decls."
                                  , "** Some incremental calls, such as pop, will be limited."
                                  ]
                   else sendAndGetSuccess Nothing "(set-option :global-declarations true)"

                -- Now dump the program!
                mapM_ (sendAndGetSuccess Nothing) (mergeSExpr (T.lines pgm))

                -- Prepare the query context and ship it off. Constructed
                -- field-for-field exactly as native @runSolver@ does, so
                -- Data.SBV.Control query mode works unchanged (Req 6.1) and the
                -- whole query block shares one WasmSolver session via
                -- rQueryState (declarations/assertions persist across
                -- push/pop/check-sat/get-model -- Req 6.3).
                --
                -- Unconfigured communication fields (Req 1.4, first clause). The
                -- "fields not configured" guard is /not/ a local check in this
                -- engine: SBV detects it ABOVE the engine seam, in the
                -- solver-agnostic callers. Every command path that reads the
                -- communication fields goes through
                -- 'Data.SBV.Control.Utils.getQueryState' (and 'modifyQueryState'),
                -- which read @rQueryState ctx@ and, when it is 'Nothing' (i.e. no
                -- 'QueryState' was installed, so 'queryAsk'\/'querySend'\/
                -- 'queryRetrieveResponse' are unconfigured), abort by raising an
                -- error to the caller WITHOUT forwarding any command to the
                -- solver -- exactly the "send nothing, report a configuration
                -- error" behavior Req 1.4 requires. The browser engine inherits
                -- that guard for free because it installs the very same complete
                -- 'QueryState' the native engine installs; it does not bypass it
                -- (no direct command transmission happens outside these fields
                -- after the continuation runs). Per Rule R1 we deliberately do
                -- NOT add an upward import of 'Data.SBV.Control.*' to re-check
                -- this here: doing so would create an import cycle, and no local
                -- check is warranted since the higher layer already enforces it
                -- uniformly for both engines.
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
                                 -- propagation (Req 8.3), mirroring native which
                                 -- runs terminateProcess/waitForProcess ahead of
                                 -- the transcript recording. 'terminateSolver'
                                 -- swallows any release failure, so the release can
                                 -- never substitute a different exception (Req 8.5).
                                 terminateSolver

                                 -- Best-effort transcript/banner finalization. On
                                 -- the browser path 'finalizeTranscript' drives a
                                 -- (possibly caller-supplied) sink that could throw;
                                 -- we guard it so neither it nor 'recordException'/
                                 -- 'recordEndTime' can mask the original forwarded
                                 -- exception we are about to re-raise (Req 8.4).
                                 (do recordException    (transcript cfg) (show e)
                                     finalizeTranscript (transcript cfg) (ExitFailure (-1))
                                     recordEndTime cfg ctx)
                                   `C.catch` \(_ :: C.SomeException) -> pure ()

                                 -- Re-raise the ORIGINAL forwarded exception
                                 -- unchanged (Reqs 8.4, 8.5).
                                 C.throwIO e

-----------------------------------------------------------------------------
-- |
-- Module    : Data.SBV.SMT.WasmBridge
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- The async-to-sync bridge to an in-browser WebAssembly SMT solver (the
-- @z3-solver@ npm package, "Z3_WASM"). This module is the only place that
-- touches JavaScript: on the browser path it encapsulates one-time
-- load/initialization, the asynchronous command primitive, and resource
-- release through GHC's WebAssembly JSFFI.
--
-- On the browser path (@#ifdef SBV_WASM@) the @foreign import javascript@
-- declarations and the async-to-sync 'sendCommand'/'release' primitives are
-- defined here; on a native GHC the same signatures are kept as stubs (and
-- 'JSVal' as an opaque stand-in) so the shared types still compile. The
-- one-time initialization state machine driving 'acquireSolver' (the
-- 'WasmSolverState' transitions) is implemented here on the browser path.
--
-- Strings (not 'Data.Text.Text') are used throughout to match sbv 12.1's
-- 'QueryState' interface; @GHC.Wasm.Prim@ marshals @JSString \<-\> String@
-- directly, so no extra conversion layer is needed.
-----------------------------------------------------------------------------

{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

#ifdef SBV_WASM
-- The JavaScript FFI is only available under the GHC WebAssembly backend; a
-- stock native GHC rejects this extension, so it must stay behind the guard.
{-# LANGUAGE JavaScriptFFI #-}
#endif

{-# OPTIONS_GHC -Wall #-}

module Data.SBV.SMT.WasmBridge (
        -- * The opaque solver handle and its lifecycle state
          WasmSolver(..)
        , WasmSolverState(..)
        , SolverFailure(..)
        -- * Initialization failure
        , WasmInitException(..)
        -- * The abstract bridge interface
        , sendCommand
        , acquireSolver
        , release
        ) where

-- 'Control.Exception' is needed on both targets: the browser path uses it to
-- translate JS 'Promise' rejections into structured failures, and the shared
-- 'WasmInitException' below has an 'C.Exception' instance that must compile on
-- a native GHC too.
import qualified Control.Exception as C

#ifdef SBV_WASM
-- Under the GHC WebAssembly backend, 'JSVal' is the opaque handle type for an
-- arbitrary JavaScript value, provided by "GHC.Wasm.Prim", along with the
-- 'JSString' conversion helpers and the 'JSException' that wraps a rejected
-- 'Promise'. These are only available under the wasm backend.
import GHC.Wasm.Prim (JSVal, JSString(..), fromJSString, toJSString, freeJSVal, JSException)

import Data.IORef       (IORef, newIORef, readIORef, writeIORef)
import Data.List        (isInfixOf)
import System.IO.Unsafe (unsafePerformIO)
#else
-- | On a native (non-wasm) GHC there is no @GHC.Wasm.Prim@, but the types in
-- this module must still compile. We therefore provide a portable, opaque
-- stand-in for 'JSVal'. It is an empty (uninhabited) type carrying no real
-- JavaScript value; the JSFFI-backed implementations live behind
-- @#ifdef SBV_WASM@ and are unavailable here.
data JSVal
#endif

-- | Opaque handle to an initialized WASM solver instance. On the browser path
-- the wrapped 'JSVal' is the @z3-solver@ JavaScript object.
newtype WasmSolver = WasmSolver JSVal

-- | The one-time load/initialization state machine for the WASM solver.
--
--   * 'NotLoaded' - nothing has been attempted yet.
--   * 'Loading'   - an initialization is in flight; further operations await it
--                   rather than starting a second initialization.
--   * 'Ready'     - the solver loaded and initialized successfully.
--   * 'Failed'    - loading or initialization failed; queued operations are
--                   failed with a descriptive error rather than left blocked.
data WasmSolverState = NotLoaded
                     | Loading
                     | Ready  WasmSolver
                     | Failed SolverFailure

-- | A structured description of a browser-path solver failure.
data SolverFailure = SolverRejected  String   -- ^ Promise rejected / solver crashed.
                   | SolverTimedOut  String   -- ^ The query timeout elapsed before a complete response.
                   | SolverLoadError String   -- ^ Failed to load the WASM module (loading phase).
                   | SolverInitError String   -- ^ Loaded but failed to create an instance (initialization phase).

-- | The exception 'acquireSolver' raises when one-time load/initialization of
-- the WASM solver fails. It is thrown to every operation that tries to acquire
-- the solver after a failure, so a failed initialization fails fast rather than
-- leaving any operation blocked indefinitely. The rendered message names the
-- WASM solver (@Z3_WASM@) and the phase, so a loading-phase failure is
-- textually distinguishable from an initialization-phase failure.
newtype WasmInitException = WasmInitException SolverFailure

instance C.Exception WasmInitException

instance Show WasmInitException where
  show (WasmInitException fl) = case fl of
        SolverLoadError e -> phaseMsg "loading"        e
        SolverInitError e -> phaseMsg "initialization" e
        SolverRejected  e -> phaseMsg "initialization" e
        SolverTimedOut  e -> phaseMsg "initialization" e
    where phaseMsg phase e = "Data.SBV: Z3_WASM solver failed during the " ++ phase
                          ++ " phase" ++ if null e then "." else ": " ++ e

#ifdef SBV_WASM
-- The JSFFI imports. These are the only place SBV touches JavaScript. Each is
-- an asynchronous (@safe@) import: calling it returns immediately with a thunk,
-- and forcing that thunk suspends only the calling Haskell thread, yielding to
-- the browser event loop until the underlying @Promise@ settles. A rejected
-- @Promise@ surfaces as a 'JSException' when the thunk is forced.

-- | Load the @z3-solver@ module and create a solver instance.
foreign import javascript safe "sbvZ3Wasm.init()"
  js_initZ3Wasm :: IO JSVal

-- | Submit one complete SMT-Lib2 command string and obtain a @Promise@ of the
-- single complete response string.
foreign import javascript safe "$1.send($2)"
  js_send :: JSVal -> JSString -> IO JSString

-- | Submit one command string raced against a @setTimeout@-backed timer
-- ($3, in MILLISECONDS) that rejects with the @SBV_WASM_TIMEOUT@ marker.
foreign import javascript safe "Promise.race([$1.send($2), new Promise((resolve, reject) => setTimeout(() => reject(new Error('SBV_WASM_TIMEOUT')), $3))])"
  js_sendWithTimeout :: JSVal -> JSString -> Double -> IO JSString

-- | Release the underlying solver instance. The JS side tolerates being called
-- more than once; any rejection is swallowed by 'release'.
foreign import javascript safe "$1.release()"
  js_release :: JSVal -> IO ()

-- | Yield one turn to the browser event loop so an in-flight initialization can
-- make progress without ever starting a second one.
foreign import javascript safe "new Promise(function (resolve) { setTimeout(resolve, 0); })"
  js_yieldToEventLoop :: IO ()

-- | Submit one complete SMT-Lib2 command string and await the single complete
-- response string. The 'Maybe' 'Int' is the query timeout in MICROSECONDS;
-- 'Nothing' means wait indefinitely. A failure is reported as a 'SolverFailure'
-- rather than thrown across the boundary. The timeout is enforced on the JS
-- side (microseconds converted to milliseconds for @setTimeout@). A
-- module-level single-slot guard refuses to begin a new await while one is
-- already in flight, guaranteeing the delivered response corresponds to the
-- most recently sent command.
sendCommand :: WasmSolver -> Maybe Int -> String -> IO (Either SolverFailure String)
sendCommand (WasmSolver h) mbTimeOut command = guarded `C.finally` freeJSVal jsCmdVal
  where jsCmd@(JSString jsCmdVal) = toJSString command

        guarded :: IO (Either SolverFailure String)
        guarded = do held <- readIORef inFlightRef
                     if held
                        then pure (Left (SolverRejected singleInFlightViolation))
                        else do writeIORef inFlightRef True
                                doSend `C.finally` writeIORef inFlightRef False

        singleInFlightViolation :: String
        singleInFlightViolation =
              "Data.SBV: Z3_WASM single-in-flight violation: a new command await began "
           ++ "before the previous command's response was delivered."

        timeoutMarker :: String
        timeoutMarker = "SBV_WASM_TIMEOUT"

        doSend :: IO (Either SolverFailure String)
        doSend = ( do jsResp <- case mbTimeOut of
                                   Nothing -> js_send h jsCmd
                                   Just us -> js_sendWithTimeout h jsCmd (fromIntegral us / 1000)
                      _      <- C.evaluate jsResp                          -- await: resolves or throws here
                      fmap Right (C.evaluate (fromJSString jsResp))        -- fully realize the response
                 ) `C.catch` \(e :: JSException) ->
                       let msg = show e
                       in if timeoutMarker `isInfixOf` msg
                             then pure (Left (SolverTimedOut command))
                             else pure (Left (SolverRejected msg))

-- | The module-level cell holding the one-time load/initialization state of the
-- WASM solver. The GHC wasm runtime is single-threaded, so an ordinary 'IORef'
-- is a sufficient mutex: there is no preemption, and the only points at which
-- another operation can observe the cell are the explicit event-loop yields
-- inside the @safe@ JSFFI awaits.
{-# NOINLINE stateRef #-}
stateRef :: IORef WasmSolverState
stateRef = unsafePerformIO (newIORef NotLoaded)

-- | The module-level single-slot "in-flight" guard. 'False' when no command
-- await is in flight, 'True' while 'sendCommand' is awaiting a response.
{-# NOINLINE inFlightRef #-}
inFlightRef :: IORef Bool
inFlightRef = unsafePerformIO (newIORef False)

-- | Classify a rejected initialization 'Promise' into a 'SolverFailure' that
-- distinguishes a module-load failure ('SolverLoadError') from an
-- instance-creation failure ('SolverInitError'). The embedding's @init()@ is
-- expected to reject with an @Error@ whose text carries @SBV_WASM_LOAD_ERROR@
-- or @SBV_WASM_INIT_ERROR@; an unmarked rejection is classified defensively as
-- a load error (the full text is preserved either way).
classifyInitFailure :: String -> SolverFailure
classifyInitFailure msg
  | loadMarker `isInfixOf` msg = SolverLoadError msg
  | initMarker `isInfixOf` msg = SolverInitError msg
  | otherwise                  = SolverLoadError msg
  where loadMarker = "SBV_WASM_LOAD_ERROR"
        initMarker = "SBV_WASM_INIT_ERROR"

-- | Acquire the (lazily, once-initialized) WASM solver handle, driving the
-- 'WasmSolverState' machine and queueing concurrent callers on the in-flight
-- initialization.
acquireSolver :: IO WasmSolver
acquireSolver = do
        st <- readIORef stateRef
        case st of
          Ready h    -> pure h
          Failed fl  -> C.throwIO (WasmInitException fl)
          Loading    -> do js_yieldToEventLoop
                           acquireSolver
          NotLoaded  -> do
                writeIORef stateRef Loading
                outcome <- ( do h <- js_initZ3Wasm        -- await: resolves to the handle or rejects here
                                _ <- C.evaluate h
                                pure (Right (WasmSolver h))
                           ) `C.catch` \(e :: JSException) ->
                                 pure (Left (classifyInitFailure (show e)))
                case outcome of
                  Right solver -> do writeIORef stateRef (Ready solver)
                                     pure solver
                  Left  fl     -> do writeIORef stateRef (Failed fl)
                                     C.throwIO (WasmInitException fl)

-- | Release the solver instance. Idempotent and never throws across the
-- boundary: any JS-side rejection (including releasing an already-released
-- instance) is swallowed. We deliberately do not 'freeJSVal' the handle here,
-- so a subsequent 'release' stays safe.
release :: WasmSolver -> IO ()
release (WasmSolver h) = (js_release h >>= C.evaluate) `C.catch` \(_ :: C.SomeException) -> pure ()

#else
-- | Submit one complete SMT-Lib2 command string and await the single complete
-- response string. (Native stub.)
sendCommand :: WasmSolver -> Maybe Int -> String -> IO (Either SolverFailure String)
sendCommand = error "Data.SBV.SMT.WasmBridge.sendCommand: not available on the native target"

-- | Acquire the (lazily, once-initialized) WASM solver handle. (Native stub.)
acquireSolver :: IO WasmSolver
acquireSolver = error "Data.SBV.SMT.WasmBridge.acquireSolver: not available on the native target"

-- | Release the solver instance. (Native stub.)
release :: WasmSolver -> IO ()
release = error "Data.SBV.SMT.WasmBridge.release: not available on the native target"
#endif

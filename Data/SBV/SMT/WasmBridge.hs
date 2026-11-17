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
-- This file defines the shared bridge data types and the abstract interface
-- (@sendCommand@/@acquireSolver@/@release@) that both the real JSFFI bridge
-- and the test @MockBridge@ harness satisfy. On the browser path
-- (@#ifdef SBV_WASM@) the @foreign import javascript@ declarations and the
-- async-to-sync 'sendCommand'/'release' primitives are defined here; on a
-- native GHC the same signatures are kept as stubs (and 'JSVal' as an opaque
-- stand-in) so the shared types still compile for the test harness. The
-- one-time initialization state machine driving 'acquireSolver' (the
-- 'WasmSolverState' transitions) is implemented here on the browser path.
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
        --
        -- $interface
        , sendCommand
        , acquireSolver
        , release
        ) where

import Data.Text (Text)

-- 'Control.Exception' is needed on both targets: the browser path uses it to
-- translate JS 'Promise' rejections into structured failures, and the shared
-- 'WasmInitException' below has an 'C.Exception' instance that must compile on
-- a native GHC too (so the type can be re-exported for the test harness).
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

import qualified Data.Text         as T
#else
-- | On a native (non-wasm) GHC there is no @GHC.Wasm.Prim@, but the types in
-- this module must still compile so the native test harness ('MockBridge') can
-- share them. We therefore provide a portable, opaque stand-in for 'JSVal'. It
-- is an empty (uninhabited) type carrying no real JavaScript value: on the
-- native target there is no solver instance to point at, and the
-- JSFFI-backed implementations that would produce one live behind
-- @#ifdef SBV_WASM@ (added in later tasks) and are unavailable here.
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
--   * 'Ready'     - the solver loaded and initialized successfully; the handle
--                   is available for use.
--   * 'Failed'    - loading or initialization failed; queued operations are
--                   failed with a descriptive error rather than left blocked.
data WasmSolverState = NotLoaded
                     | Loading
                     | Ready  WasmSolver
                     | Failed SolverFailure

-- | A structured description of a browser-path solver failure. Each
-- constructor maps onto the @SBVException@ surfaced to the caller and keeps the
-- distinct failure phases textually distinguishable.
data SolverFailure = SolverRejected  String   -- ^ Promise rejected / solver crashed (a Solver_Failure).
                   | SolverTimedOut  String   -- ^ The Query_Timeout elapsed before a complete response.
                   | SolverLoadError String   -- ^ Failed to load the WASM module (loading phase).
                   | SolverInitError String   -- ^ Loaded but failed to create an instance (initialization phase).

-- | The exception 'acquireSolver' raises when one-time load/initialization of
-- the WASM solver fails. It is thrown to every operation that tries to acquire
-- the solver after a failure, so a failed initialization fails fast rather than
-- leaving any operation blocked indefinitely (Requirement 5.5).
--
-- The rendered message always names the WASM solver (@Z3_WASM@) and the phase
-- in which the failure occurred, so a loading-phase failure (Requirement 13.1)
-- is textually distinguishable from an initialization-phase failure
-- (Requirement 13.2):
--
--   * a 'SolverLoadError' renders as a @\"loading\"@-phase failure;
--   * a 'SolverInitError' renders as an @\"initialization\"@-phase failure.
--
-- This is a dedicated exception type (rather than the richer
-- 'Data.SBV.SMT.Utils.SBVException') because 'acquireSolver' runs at the bridge
-- layer, which sits /below/ the 'SMTConfig'-bearing layers in the module graph;
-- constructing an 'SBVException' requires an 'SMTConfig' that is not — and, to
-- keep the import graph acyclic, must not be — available here. The
-- 'Data.SBV.SMT.BrowserEngine' layer, which does have the 'SMTConfig', catches
-- a 'SolverFailure'/'WasmInitException' from the bridge and re-presents it as an
-- 'SBVException' to the Solving_API caller.
newtype WasmInitException = WasmInitException SolverFailure

-- | 'WasmInitException' is throwable; its 'Show' instance names @Z3_WASM@ and
-- the failing phase so loading- and initialization-phase failures are
-- distinguishable in the rendered text (Requirements 13.1, 13.2).
instance C.Exception WasmInitException

instance Show WasmInitException where
  show (WasmInitException fl) = case fl of
        SolverLoadError e -> phaseMsg "loading"        e
        SolverInitError e -> phaseMsg "initialization" e
        -- 'acquireSolver' only ever stores load/init failures, but render any
        -- other 'SolverFailure' defensively so the message stays descriptive.
        SolverRejected  e -> phaseMsg "initialization" e
        SolverTimedOut  e -> phaseMsg "initialization" e
    where phaseMsg phase e = "Data.SBV: Z3_WASM solver failed during the " ++ phase
                          ++ " phase" ++ if null e then "." else ": " ++ e

-- $interface
-- The interface that both the real JSFFI bridge and the test 'MockBridge'
-- satisfy. On the browser path ('SBV_WASM') the bodies are backed by the
-- @foreign import javascript@ declarations below; on a native GHC the same
-- signatures are kept as stubs so the shared types still compile for the test
-- harness.

#ifdef SBV_WASM
-- The JSFFI imports. These are the only place SBV touches JavaScript. Each is
-- an asynchronous (@safe@) import: calling it returns immediately with a thunk,
-- and forcing that thunk suspends only the calling Haskell thread, yielding to
-- the browser event loop until the underlying @Promise@ settles. A rejected
-- @Promise@ surfaces as a 'JSException' when the thunk is forced.

-- | Load the @z3-solver@ module and create a solver instance. Resolves to the
-- solver handle; rejects on a load/initialization failure. Consumed by
-- 'acquireSolver', which drives it through the 'WasmSolverState' machine.
foreign import javascript safe "sbvZ3Wasm.init()"
  js_initZ3Wasm :: IO JSVal

-- | Submit one complete SMT-Lib2 command string and obtain a @Promise@ of the
-- single complete response string. A rejection denotes a Solver_Failure.
foreign import javascript safe "$1.send($2)"
  js_send :: JSVal -> JSString -> IO JSString

-- | Submit one complete SMT-Lib2 command string with a Query_Timeout bound (in
-- MILLISECONDS, @$3@) enforced entirely on the JS side. The solver's @send@
-- @Promise@ is raced (@Promise.race@) against a @setTimeout@-backed timer
-- @Promise@ that rejects with an @Error@ carrying the @SBV_WASM_TIMEOUT@ marker
-- once the bound elapses. Therefore a resolved value is the solver response, a
-- marker-bearing rejection is the elapsed Query_Timeout, and any other
-- rejection is a genuine Solver_Failure. The timer is created by this snippet
-- only, so it exists solely when a Query_Timeout is set (the unbounded case
-- uses 'js_send' and creates no timer); the bound is enforced by the browser
-- event loop, never by 'System.Timeout' preempting a blocked Haskell thread
-- (Requirement 13.6).
foreign import javascript safe "Promise.race([$1.send($2), new Promise((resolve, reject) => setTimeout(() => reject(new Error('SBV_WASM_TIMEOUT')), $3))])"
  js_sendWithTimeout :: JSVal -> JSString -> Double -> IO JSString

-- | Release the underlying solver instance. The JS side is expected to tolerate
-- being called more than once; any rejection is swallowed by 'release'.
foreign import javascript safe "$1.release()"
  js_release :: JSVal -> IO ()

-- | Yield one turn to the browser event loop. Forcing this @safe@ import
-- suspends only the calling Haskell thread and hands control to the event loop
-- (the @setTimeout(…, 0)@ macrotask resolves after the current turn drains its
-- microtasks), then resumes this thread. 'acquireSolver' uses it in the
-- 'Loading' branch to let an /in-flight/ initialization make progress without
-- ever starting a second one (Requirement 5.3): a pure-Haskell spin would never
-- return control to the event loop, so the in-flight init Promise could never
-- settle.
foreign import javascript safe "new Promise(function (resolve) { setTimeout(resolve, 0); })"
  js_yieldToEventLoop :: IO ()

-- | Submit one complete SMT-Lib2 command string and await the single complete
-- response string. The 'Maybe' 'Int' is the Query_Timeout in MICROSECONDS;
-- 'Nothing' means wait indefinitely (matching Native_SBV). A failure is
-- reported as a 'SolverFailure' rather than thrown across the boundary.
--
-- The Query_Timeout is enforced on the JS side rather than with
-- 'System.Timeout' (Requirement 13.6):
--
--   * @'Just' µs@: race the solver's @send@ @Promise@ against a
--     @setTimeout@-backed timer @Promise@ via 'js_sendWithTimeout'. When the
--     timer wins the race the import rejects with the @SBV_WASM_TIMEOUT@ marker,
--     which we map to @'SolverTimedOut' command@ (naming the command, per
--     Requirement 13.5); a real solver rejection has no marker and maps to
--     'SolverRejected'.
--   * @'Nothing'@: create no timer and await 'js_send' unbounded (matching
--     Native_SBV), so there is no internal default timeout.
--
-- Units: the Query_Timeout 'Int' is in MICROSECONDS, but JavaScript's
-- @setTimeout@ takes MILLISECONDS, so we convert by dividing by 1000 (µs → ms).
--
-- Single-slot in-flight ordering guard (Requirement 3.3). Before awaiting,
-- 'sendCommand' claims the module-level 'inFlightRef' slot, and it releases the
-- slot IMMEDIATELY after the response is delivered (via 'C.finally', so the slot
-- is cleared on both the success and the exception paths). It refuses to begin a
-- new await while the slot is already held — that would mean a second await began
-- before the previous command's response was delivered — by returning a
-- @'Left' ('SolverRejected' …)@ that names the single-in-flight violation. On the
-- single-threaded runtime SBV's @ask@ is already strictly sequential, so this
-- guard is defensive; it guarantees the delivered response always corresponds to
-- the most recently sent command. The guard is purely a sentinel: it does NOT
-- drain threads/stdout and uses no @forkIO@/@MVar@.
sendCommand :: WasmSolver -> Maybe Int -> Text -> IO (Either SolverFailure Text)
sendCommand (WasmSolver h) mbTimeOut command = guarded `C.finally` freeJSVal jsCmdVal
  where jsCmd@(JSString jsCmdVal) = toJSString (T.unpack command)

        -- The single-slot in-flight guard (Requirement 3.3). The slot check and
        -- claim are not interrupted by an event-loop yield (no @safe@ JSFFI await
        -- occurs between them), so on the single-threaded runtime this read-then-set
        -- is effectively atomic. We compose the slot release as an INNER 'finally'
        -- around 'doSend' so it fires exactly once, immediately after the response
        -- is delivered (success or exception); the OUTER 'finally' that frees the
        -- command 'JSVal' still runs exactly once on every path. On the refusal
        -- path the slot is left untouched (we never claimed it, so we must not
        -- clear another await's claim).
        guarded :: IO (Either SolverFailure Text)
        guarded = do held <- readIORef inFlightRef
                     if held
                        then pure (Left (SolverRejected singleInFlightViolation))
                        else do writeIORef inFlightRef True
                                doSend `C.finally` writeIORef inFlightRef False

        -- Message surfaced when a new await is attempted while the slot is held:
        -- the previous command's response was not delivered before this one began.
        singleInFlightViolation :: String
        singleInFlightViolation =
              "Data.SBV: Z3_WASM single-in-flight violation: a new command await began "
           ++ "before the previous command's response was delivered."

        -- Sentinel embedded in the timer @Promise@'s rejection reason so a
        -- timeout is distinguishable from a genuine solver rejection.
        timeoutMarker :: String
        timeoutMarker = "SBV_WASM_TIMEOUT"

        -- Force the async-import result thunk so the 'Promise' actually settles
        -- before we return; translate a rejection ('JSException') into a
        -- structured 'SolverFailure' instead of letting it cross the boundary. A
        -- rejection whose text carries 'timeoutMarker' is the elapsed
        -- Query_Timeout ('SolverTimedOut', naming the command); anything else is
        -- a genuine Solver_Failure ('SolverRejected').
        doSend :: IO (Either SolverFailure Text)
        doSend = ( do jsResp <- case mbTimeOut of
                                   -- Unbounded: no timer is created; await is open-ended (matches Native_SBV).
                                   Nothing -> js_send h jsCmd
                                   -- Bounded: race against a JS timer. µs → ms (divide by 1000) for setTimeout.
                                   Just us -> js_sendWithTimeout h jsCmd (fromIntegral us / 1000)
                      _      <- C.evaluate jsResp                              -- await: resolves or throws here
                      fmap Right (C.evaluate (T.pack (fromJSString jsResp)))   -- fully realize the response
                 ) `C.catch` \(e :: JSException) ->
                       let msg = show e
                       in if timeoutMarker `isInfixOf` msg
                             then pure (Left (SolverTimedOut (T.unpack command)))
                             else pure (Left (SolverRejected msg))

-- | The module-level cell holding the one-time load/initialization state of the
-- WASM solver. It starts 'NotLoaded' and is driven by 'acquireSolver' through
-- 'Loading' to either 'Ready' or 'Failed'. Because the GHC wasm runtime is
-- single-threaded, an ordinary 'IORef' is a sufficient mutex here: there is no
-- preemption, and the only points at which another operation can observe the
-- cell are the explicit event-loop yields inside the @safe@ JSFFI awaits. We
-- follow the same @NOINLINE@\/'unsafePerformIO' top-level-'IORef' pattern used
-- by 'Data.SBV.SMT.TranscriptSink.browserTranscriptRef'.
{-# NOINLINE stateRef #-}
stateRef :: IORef WasmSolverState
stateRef = unsafePerformIO (newIORef NotLoaded)

-- | The module-level single-slot \"in-flight\" guard backing the ordering
-- invariant (Requirement 3.3). It is 'False' when no command await is in flight
-- and 'True' while 'sendCommand' is awaiting a response. 'sendCommand' claims it
-- (sets 'True') before awaiting and clears it (sets 'False') immediately after
-- delivering the response, refusing to begin a new await while it is held. It is
-- used purely as a sentinel/mutex — NOT a thread- or stdout-draining mechanism
-- (no @forkIO@, no @MVar@-for-draining). An ordinary 'IORef' suffices because the
-- GHC wasm runtime is single-threaded: there is no preemption, and the only
-- points another operation can observe the cell are the explicit event-loop
-- yields inside the @safe@ JSFFI awaits. We follow the same
-- @NOINLINE@\/'unsafePerformIO' top-level-'IORef' pattern used by 'stateRef' and
-- 'Data.SBV.SMT.TranscriptSink.browserTranscriptRef'.
{-# NOINLINE inFlightRef #-}
inFlightRef :: IORef Bool
inFlightRef = unsafePerformIO (newIORef False)

-- | Classify a rejected initialization 'Promise' into a 'SolverFailure' that
-- distinguishes a module-load failure ('SolverLoadError', Requirement 13.1)
-- from an instance-creation failure ('SolverInitError', Requirement 13.2).
--
-- Marker contract with the JS embedding. The single @sbvZ3Wasm.init()@ entry
-- point ('js_initZ3Wasm') covers both phases, so the Haskell side cannot by
-- itself tell which phase failed. We therefore adopt a marker convention,
-- mirroring the @SBV_WASM_TIMEOUT@ marker used for the Query_Timeout in
-- 'sendCommand': the embedding's @init()@ is expected to reject with an @Error@
-- whose text carries
--
--   * @SBV_WASM_LOAD_ERROR@  - the @z3-solver@ module failed to load, or
--   * @SBV_WASM_INIT_ERROR@  - the module loaded but creating the solver
--                              instance failed.
--
-- An unmarked rejection (e.g. a stock @Error@ from an embedding that does not
-- yet follow the contract) is classified defensively as a 'SolverLoadError',
-- since a failure with no instance ever created is most often a load failure;
-- the full rejection text is preserved either way so the cause is never lost.
classifyInitFailure :: String -> SolverFailure
classifyInitFailure msg
  | loadMarker `isInfixOf` msg = SolverLoadError msg
  | initMarker `isInfixOf` msg = SolverInitError msg
  | otherwise                  = SolverLoadError msg
  where loadMarker = "SBV_WASM_LOAD_ERROR"
        initMarker = "SBV_WASM_INIT_ERROR"

-- | Acquire the (lazily, once-initialized) WASM solver handle, driving the
-- 'WasmSolverState' machine and queueing concurrent callers on the in-flight
-- initialization (Requirements 5.3, 5.4, 5.5):
--
--   * 'NotLoaded' - claim the slot by setting 'Loading', run 'js_initZ3Wasm'
--     exactly once, then store 'Ready' on success or 'Failed' on rejection.
--     There is no second @init@ on this path (Requirement 5.3).
--   * 'Loading' - an initialization started by an earlier caller is in flight.
--     We do /not/ start a second one (Requirement 5.3); we yield to the event
--     loop ('js_yieldToEventLoop') so that in-flight init can make progress,
--     then re-read the cell and dispatch on the resulting 'Ready'\/'Failed'.
--     On the single-threaded runtime this realizes "queue and proceed in
--     submission order when the init Promise settles" (Requirement 5.4): each
--     waiter resumes from its yield in the order the event loop schedules the
--     callbacks.
--   * 'Ready' - return the cached handle; no re-initialization.
--   * 'Failed' - throw a descriptive 'WasmInitException' naming @Z3_WASM@ and
--     the failing phase, so no queued operation is ever left blocked
--     (Requirement 5.5) and the loading vs initialization phase is textually
--     distinguishable (Requirements 13.1, 13.2).
acquireSolver :: IO WasmSolver
acquireSolver = do
        st <- readIORef stateRef
        case st of
          Ready h    -> pure h
          Failed fl  -> C.throwIO (WasmInitException fl)
          Loading    -> do
                -- An init started elsewhere is in flight. Do NOT re-init; yield
                -- to the event loop so it can settle, then retry the dispatch.
                js_yieldToEventLoop
                acquireSolver
          NotLoaded  -> do
                -- Claim the one-time init slot before awaiting, so any operation
                -- that calls 'acquireSolver' while we are awaiting observes
                -- 'Loading' and queues rather than starting a second init.
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
-- instance) is swallowed. The async import returns a thunk even for a @()@
-- result, so we force it to make sure the release @Promise@ has settled.
--
-- We deliberately do not 'freeJSVal' the handle here: doing so would make a
-- subsequent 'release' pass a freed 'JSVal' to JavaScript, which is an
-- uncatchable runtime panic rather than a catchable error. Leaving the handle
-- to the garbage collector keeps 'release' safely idempotent.
release :: WasmSolver -> IO ()
release (WasmSolver h) = (js_release h >>= C.evaluate) `C.catch` \(_ :: C.SomeException) -> pure ()

#else
-- | Submit one complete SMT-Lib2 command string and await the single complete
-- response string. The 'Maybe' 'Int' is the Query_Timeout in microseconds;
-- 'Nothing' means wait indefinitely (matching Native_SBV). A failure is
-- reported as a 'SolverFailure' rather than thrown across the boundary.
sendCommand :: WasmSolver -> Maybe Int -> Text -> IO (Either SolverFailure Text)
sendCommand = error "Data.SBV.SMT.WasmBridge.sendCommand: not available on the native target"

-- | Acquire the (lazily, once-initialized) WASM solver handle, driving the
-- 'WasmSolverState' machine and queueing concurrent callers on the in-flight
-- initialization.
acquireSolver :: IO WasmSolver
acquireSolver = error "Data.SBV.SMT.WasmBridge.acquireSolver: not available on the native target"

-- | Release the solver instance. Implementations are idempotent and never
-- throw across the boundary.
release :: WasmSolver -> IO ()
release = error "Data.SBV.SMT.WasmBridge.release: not available on the native target"
#endif

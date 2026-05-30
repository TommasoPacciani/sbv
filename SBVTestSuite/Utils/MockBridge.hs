-----------------------------------------------------------------------------
-- |
-- Module    : Utils.MockBridge
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- A reusable, deterministic test harness that mimics the browser-path
-- async-to-sync bridge ("Data.SBV.SMT.WasmBridge") on a stock native GHC, so
-- the engine/bridge property tests (P1-P13) can run with no WebAssembly
-- runtime and no real solver.
--
-- The harness offers the same shape of interface as the real bridge -
-- @acquireSolver@ \/ @sendCommand@ \/ @release@ - but threads its configuration
-- and recording state through an explicit 'MockBridge' handle (the real bridge
-- keeps that state in a module-level cell behind JSFFI, which is unavailable
-- and uninhabited on a native GHC). It:
--
--   * records an ordered transcript of every message handed to 'sendCommand'
--     (see 'transcript');
--   * replays a /script/ of responses, scripted 'SolverFailure's, and
--     scripted per-command timing\/delay so the @Promise.race@ 'Maybe' 'Int'
--     timeout behaviour can be simulated deterministically;
--   * models the one-time initialization state machine ('acquireSolver'
--     initializes at most once and fails fast rather than stranding callers);
--   * can script a failing 'release' so the aborting-cleanup fidelity property
--     (re-raise the original exception even if release fails) is exercisable; and
--   * provides a separate /capturing native transport/ mock
--     ('CapturingTransport') that records the exact 'Text' byte sequence handed
--     to a solver, so Property 1 can compare browser vs native transmission.
--
-- The shared failure vocabulary ('SolverFailure') is imported from the real
-- bridge so that scripted failures are the very same values the browser engine
-- consumes - the harness does not introduce a parallel failure type.
-----------------------------------------------------------------------------

{-# OPTIONS_GHC -Wall #-}

module Utils.MockBridge (
        -- * Scripting the mock
          MockScript(..)
        , ScriptedResponse(..)
        , emptyScript
        , scriptResponses
        , respondWith
        , failWith
        , withDelay
        -- * The browser-side mock bridge
        , MockBridge
        , newMockBridge
        , acquireSolver
        , sendCommand
        , release
        -- * Reading back recorded state
        , transcript
        , initCount
        , releaseCount
        , solverPhase
        , MockPhase(..)
        , sawConcurrentInFlight
        -- * Capturing native transport mock (for Property 1)
        , CapturingTransport
        , newCapturingTransport
        , captureSend
        , capturedBytes
        -- * Harness exceptions
        , MockBridgeException(..)
        -- * Re-export of the shared failure vocabulary
        , SolverFailure(..)
        ) where

import Control.Exception (Exception, throwIO, finally)
import Data.IORef        (IORef, newIORef, readIORef, writeIORef, modifyIORef')

import Data.Text (Text)
import qualified Data.Text as T

import Data.SBV.SMT.WasmBridge (SolverFailure(..))

-- | A single scripted outcome for one bridge read (one 'sendCommand' call).
-- A response may carry a simulated solver delay so that, when a caller supplies
-- a @Just micros@ timeout, the harness can deterministically decide whether the
-- timer would win the @Promise.race@ (delay strictly greater than the timeout)
-- or the solver would win (delay within the timeout, or no timeout supplied).
data ScriptedResponse = ScriptedResponse
        { srDelayMicros :: Maybe Int                  -- ^ simulated solver time for this command; 'Nothing' means instantaneous.
        , srOutcome     :: Either SolverFailure Text  -- ^ the scripted response chunk, or a scripted 'SolverFailure'.
        }

-- | The full deterministic script driving a 'MockBridge'.
data MockScript = MockScript
        { msResponses     :: [ScriptedResponse]      -- ^ consumed in order, one per 'sendCommand' call.
        , msInitOutcome   :: Either SolverFailure ()  -- ^ whether 'acquireSolver' initializes successfully or fails.
        , msReleaseThrows :: Bool                     -- ^ when 'True', 'release' throws a 'MockReleaseFailure' (for the aborting-cleanup property).
        }

-- | A script that initializes cleanly, releases cleanly, and has no responses
-- queued. Build on top of this with the helpers below.
emptyScript :: MockScript
emptyScript = MockScript { msResponses     = []
                         , msInitOutcome   = Right ()
                         , msReleaseThrows = False
                         }

-- | Convenience: a script whose responses are the given outcomes, each with no
-- simulated delay, that initializes and releases cleanly.
scriptResponses :: [Either SolverFailure Text] -> MockScript
scriptResponses outs = emptyScript { msResponses = map (ScriptedResponse Nothing) outs }

-- | A scripted successful response chunk with no simulated delay.
respondWith :: Text -> ScriptedResponse
respondWith = ScriptedResponse Nothing . Right

-- | A scripted 'SolverFailure' with no simulated delay.
failWith :: SolverFailure -> ScriptedResponse
failWith = ScriptedResponse Nothing . Left

-- | Attach a simulated solver delay (in microseconds) to a scripted response,
-- so the @Promise.race@ timeout behaviour can be exercised.
withDelay :: Int -> ScriptedResponse -> ScriptedResponse
withDelay micros r = r { srDelayMicros = Just micros }

-- | The lifecycle phase of a mock solver, mirroring the real
-- 'Data.SBV.SMT.WasmBridge.WasmSolverState' machine (minus its handle payload,
-- which on a native GHC is uninhabited).
data MockPhase = PhaseNotLoaded   -- ^ nothing attempted yet.
               | PhaseLoading     -- ^ initialization in progress.
               | PhaseReady       -- ^ initialized; ready for commands.
               | PhaseFailed      -- ^ initialization failed; further operations fail fast.
               deriving (Show, Eq)

-- | An opaque handle to a mock browser-path solver. Construct one with
-- 'newMockBridge'; drive it with 'acquireSolver' \/ 'sendCommand' \/ 'release';
-- read back what happened with 'transcript', 'initCount', 'releaseCount',
-- 'solverPhase', and 'sawConcurrentInFlight'.
data MockBridge = MockBridge
        { mbResponses    :: IORef [ScriptedResponse]  -- remaining scripted responses (consumed front-to-back).
        , mbTranscript   :: IORef [Text]              -- messages sent, stored reversed for O(1) append.
        , mbPhase        :: IORef MockPhase
        , mbInitCount    :: IORef Int                 -- number of times initialization actually ran (must stay <= 1).
        , mbReleaseCount :: IORef Int
        , mbInFlight     :: IORef Bool                -- True while a send is awaiting; for the single-in-flight guard.
        , mbConcurrent   :: IORef Bool                -- set True if a send is entered while another is in flight.
        , mbInitOutcome  :: Either SolverFailure ()
        , mbReleaseThrows :: Bool
        }

-- | Build a fresh mock bridge from a script. The bridge starts in
-- 'PhaseNotLoaded'; nothing is initialized until 'acquireSolver' is called.
newMockBridge :: MockScript -> IO MockBridge
newMockBridge script = do
        rResponses    <- newIORef (msResponses script)
        rTranscript   <- newIORef []
        rPhase        <- newIORef PhaseNotLoaded
        rInitCount    <- newIORef 0
        rReleaseCount <- newIORef 0
        rInFlight     <- newIORef False
        rConcurrent   <- newIORef False
        pure MockBridge { mbResponses     = rResponses
                        , mbTranscript    = rTranscript
                        , mbPhase         = rPhase
                        , mbInitCount     = rInitCount
                        , mbReleaseCount  = rReleaseCount
                        , mbInFlight      = rInFlight
                        , mbConcurrent    = rConcurrent
                        , mbInitOutcome   = msInitOutcome script
                        , mbReleaseThrows = msReleaseThrows script
                        }

-- | Drive the one-time initialization state machine, mirroring the real
-- 'Data.SBV.SMT.WasmBridge.acquireSolver':
--
--   * 'PhaseNotLoaded' \/ 'PhaseLoading' - run initialization exactly once,
--     incrementing 'initCount'; on success transition to 'PhaseReady', on
--     failure transition to 'PhaseFailed' and throw a descriptive
--     'MockInitFailure'.
--   * 'PhaseReady' - return the same handle without re-initializing
--     (initialization happens at most once).
--   * 'PhaseFailed' - throw rather than leaving the caller blocked, so a failed
--     initialization never strands queued operations.
--
-- Returns the same 'MockBridge' handle, so callers can keep using it (the real
-- bridge returns a @WasmSolver@ handle here).
acquireSolver :: MockBridge -> IO MockBridge
acquireSolver mb = do
        phase <- readIORef (mbPhase mb)
        case phase of
          PhaseReady  -> pure mb
          PhaseFailed -> throwIO (MockInitFailure (initFailureMessage mb))
          _           -> do
                writeIORef (mbPhase mb) PhaseLoading
                modifyIORef' (mbInitCount mb) (+ 1)
                case mbInitOutcome mb of
                  Right () -> writeIORef (mbPhase mb) PhaseReady >> pure mb
                  Left  _  -> do writeIORef (mbPhase mb) PhaseFailed
                                 throwIO (MockInitFailure (initFailureMessage mb))

-- | Submit one complete command, recording it in the transcript and returning
-- the next scripted outcome. The 'Maybe' 'Int' is the Query_Timeout in
-- microseconds (as in the real bridge):
--
--   * @Just micros@ with a scripted delay strictly greater than @micros@ - the
--     timer wins the simulated @Promise.race@, yielding @Left ('SolverTimedOut'
--     ...)@ naming the command.
--   * otherwise (delay within the bound, or @Nothing@ = wait indefinitely) - the
--     scripted outcome is returned verbatim.
--
-- The send claims a single in-flight slot for its duration; entering a send
-- while another is already in flight is recorded (see 'sawConcurrentInFlight').
-- Throws 'MockScriptExhausted' if the script has no response left for the
-- command.
sendCommand :: MockBridge -> Maybe Int -> Text -> IO (Either SolverFailure Text)
sendCommand mb mbTimeout command = do
        modifyIORef' (mbTranscript mb) (command :)
        enterInFlight mb
        nextResponse mb mbTimeout command `finally` leaveInFlight mb

-- | Release the mock solver, incrementing 'releaseCount'. When the script set
-- 'msReleaseThrows', this throws a 'MockReleaseFailure' so the aborting-cleanup
-- fidelity property (original exception re-raised even when release fails) can
-- be tested. Unlike the real bridge it is /not/ silently swallowed here - the
-- harness deliberately surfaces the scripted failure.
release :: MockBridge -> IO ()
release mb = do
        modifyIORef' (mbReleaseCount mb) (+ 1)
        if mbReleaseThrows mb
           then throwIO (MockReleaseFailure "Utils.MockBridge.release: scripted release failure")
           else pure ()

-- | The ordered transcript of every message handed to 'sendCommand', oldest first.
transcript :: MockBridge -> IO [Text]
transcript mb = reverse <$> readIORef (mbTranscript mb)

-- | How many times initialization actually ran. Stays @<= 1@ for any number of
-- 'acquireSolver' calls (initialization happens at most once).
initCount :: MockBridge -> IO Int
initCount = readIORef . mbInitCount

-- | How many times 'release' has been invoked on this bridge.
releaseCount :: MockBridge -> IO Int
releaseCount = readIORef . mbReleaseCount

-- | The current lifecycle phase of the mock solver.
solverPhase :: MockBridge -> IO MockPhase
solverPhase = readIORef . mbPhase

-- | Whether a 'sendCommand' was ever entered while another send was still in
-- flight. On a correctly sequential (single-in-flight) driver this stays
-- 'False'.
sawConcurrentInFlight :: MockBridge -> IO Bool
sawConcurrentInFlight = readIORef . mbConcurrent

-- Internal: pop the next scripted response, applying the simulated Promise.race
-- timeout decision.
nextResponse :: MockBridge -> Maybe Int -> Text -> IO (Either SolverFailure Text)
nextResponse mb mbTimeout command = do
        rs <- readIORef (mbResponses mb)
        case rs of
          []       -> throwIO (MockScriptExhausted command)
          (r : rs') -> do
                writeIORef (mbResponses mb) rs'
                pure $ case (mbTimeout, srDelayMicros r) of
                         (Just t, Just d) | d > t -> Left (SolverTimedOut (timeoutMessage t command))
                         _                        -> srOutcome r

-- Internal: claim the in-flight slot, recording a concurrency violation if it
-- was already held.
enterInFlight :: MockBridge -> IO ()
enterInFlight mb = do
        busy <- readIORef (mbInFlight mb)
        if busy then writeIORef (mbConcurrent mb) True
                else writeIORef (mbInFlight mb) True

-- Internal: release the in-flight slot.
leaveInFlight :: MockBridge -> IO ()
leaveInFlight mb = writeIORef (mbInFlight mb) False

-- Internal: render the scripted init failure for the thrown exception.
initFailureMessage :: MockBridge -> String
initFailureMessage mb = case mbInitOutcome mb of
                          Right () -> "Utils.MockBridge: initialization unexpectedly succeeded"
                          Left sf  -> "Utils.MockBridge: initialization failed: " ++ failureMessage sf

-- Internal: a stable textual rendering of a 'SolverFailure' (the shared type
-- does not derive 'Show', so the harness renders it explicitly).
failureMessage :: SolverFailure -> String
failureMessage (SolverRejected  s) = "solver rejected: "       ++ s
failureMessage (SolverTimedOut  s) = "query timed out: "       ++ s
failureMessage (SolverLoadError s) = "load error: "            ++ s
failureMessage (SolverInitError s) = "initialization error: "  ++ s

-- Internal: the message carried by a simulated timeout.
timeoutMessage :: Int -> Text -> String
timeoutMessage t command = "Utils.MockBridge: command timed out after " ++ show t ++ "us: " ++ T.unpack command

-- | A capturing native-transport mock. It records, in order, the exact 'Text'
-- byte sequence that would be handed to a solver, so Property 1 can compare the
-- native transmission against the browser ('MockBridge') transmission for the
-- same generated problem.
newtype CapturingTransport = CapturingTransport (IORef [Text])

-- | Create a fresh capturing transport that has recorded nothing yet.
newCapturingTransport :: IO CapturingTransport
newCapturingTransport = CapturingTransport <$> newIORef []

-- | Record one message handed to the (mock) native solver.
captureSend :: CapturingTransport -> Text -> IO ()
captureSend (CapturingTransport r) t = modifyIORef' r (t :)

-- | The ordered sequence of messages captured by the transport, oldest first.
capturedBytes :: CapturingTransport -> IO [Text]
capturedBytes (CapturingTransport r) = reverse <$> readIORef r

-- | Failures surfaced by the harness itself (distinct from the scripted
-- 'SolverFailure's, which model the /solver's/ behaviour).
data MockBridgeException
        = MockScriptExhausted Text   -- ^ no scripted response remained for the given command.
        | MockInitFailure     String -- ^ 'acquireSolver' was driven into a failed initialization.
        | MockReleaseFailure  String -- ^ a scripted 'release' failure (for the aborting-cleanup property).
        deriving Show

instance Exception MockBridgeException

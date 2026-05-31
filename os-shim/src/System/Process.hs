{-# LANGUAGE JavaScriptFFI #-}
-- | Out-of-tree replacement for the slice of "System.Process" that SBV's native
-- engine uses, backed by an in-browser WASI solver process over SharedArrayBuffer
-- pipes. SBV source is unchanged; this module is selected via cabal on wasm only.
--
-- @runInteractiveProcess@ asks the JS host (sbv-worker) to spawn the solver
-- worker and inject three pipe fds into this instance's WASI fd table, then wraps
-- them as ordinary GHC Handles with the recipe validated by the standalone probe
-- (fdToHandle' + Stream + explicit WriteMode/ReadMode).
module System.Process
  ( runInteractiveProcess
  , waitForProcess
  , terminateProcess
  , ProcessHandle
  ) where

import Data.List         (intercalate)
import System.Exit       (ExitCode(..))
import System.IO         (Handle, IOMode(..), BufferMode(..), hSetBuffering)
import GHC.IO.Handle.FD  (fdToHandle')
import GHC.IO.Device     (IODeviceType(Stream))
import GHC.Wasm.Prim     (JSVal, JSString(..), toJSString)

-- | Opaque handle: the base fd index of the spawned solver's pipe triple.
newtype ProcessHandle = ProcessHandle Int

-- | Host: allocate cmd/resp/err SAB pipes, start the solver worker for @exe@ with
-- @args@ (newline-joined), push 3 PipeFds onto this worker's WASI fds, return the
-- base index. inh = base (write), outh = base+1 (read), errh = base+2 (read).
-- Args are passed as JSVal (a JS string); unsafe imports don't marshal JSString
-- arguments directly.
foreign import javascript unsafe "spawnSolver($1,$2)"
  js_spawnSolver :: JSVal -> JSVal -> IO Int

foreign import javascript unsafe "terminateSolver($1)"
  js_terminateSolver :: Int -> IO ()

runInteractiveProcess :: FilePath -> [String] -> Maybe FilePath -> Maybe [(String, String)]
                      -> IO (Handle, Handle, Handle, ProcessHandle)
runInteractiveProcess exe args _ _ = do
  let JSString jExe  = toJSString exe
      JSString jArgs = toJSString (intercalate "\n" args)
  base <- js_spawnSolver jExe jArgs
  inh  <- fdToHandle' (fromIntegral base)       (Just Stream) False exe WriteMode False
  outh <- fdToHandle' (fromIntegral (base + 1)) (Just Stream) False exe ReadMode  False
  errh <- fdToHandle' (fromIntegral (base + 2)) (Just Stream) False exe ReadMode  False
  hSetBuffering inh  LineBuffering
  hSetBuffering outh LineBuffering
  hSetBuffering errh LineBuffering
  pure (inh, outh, errh, ProcessHandle base)

waitForProcess :: ProcessHandle -> IO ExitCode
waitForProcess _ = pure ExitSuccess

terminateProcess :: ProcessHandle -> IO ()
terminateProcess (ProcessHandle base) = js_terminateSolver base

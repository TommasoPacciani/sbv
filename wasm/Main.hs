-----------------------------------------------------------------------------
-- |
-- Module    : Main
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Browser (WebAssembly) entry point for SBV. This is a tiny GHC-wasm
-- /reactor/ module: it does no work in @main@, and instead exposes a JSFFI
-- export, @sbvRunDemos@, that the browser harness calls. The export runs a few
-- representative SBV solving calls through the in-browser Z3 (the @z3Wasm@
-- configuration becomes @defaultSMTCfg@ on the @SBV_WASM@ target, so plain
-- 'sat'/'prove' drive the browser engine) and returns a human-readable report.
--
-- Because the solver bridge awaits JavaScript @Promise@s (z3-solver is
-- asynchronous), the entry point MUST be a JSFFI export returning a @Promise@
-- to JS rather than a WASI @_start@ command: a @foreign export javascript@
-- function returns a JS @Promise@ that settles only after every awaited
-- sub-Promise (Z3 load/init and each @send@) has resolved, which is exactly
-- how the GHC wasm RTS yields to the browser event loop while a Haskell green
-- thread is suspended.
-----------------------------------------------------------------------------

{-# LANGUAGE JavaScriptFFI       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall #-}

module Main (main) where

import qualified Control.Exception as C

import Data.SBV
import GHC.Wasm.Prim (JSString(..), toJSString)

-- | Reactor entry point: nothing to do here. The RTS is initialized by the
-- loader (via @hs_init@) and the real work happens in 'sbvRunDemos'.
main :: IO ()
main = pure ()

-- | The JSFFI export the browser harness invokes. Calling
-- @instance.exports.sbvRunDemos()@ from JS returns a @Promise<string>@ that
-- resolves with the report once the in-browser Z3 has answered every query.
foreign export javascript "sbvRunDemos" sbvRunDemos :: IO JSString

-- | Run a handful of representative solves that exercise the retained theories
-- on the browser path: bit-vectors, unbounded integers, and IEEE floating
-- point (the last goes through the @libBF@ C sources compiled for wasm). Each
-- call uses the default configuration, which is 'z3Wasm' on the @SBV_WASM@
-- target, so all communication is routed through the browser engine.
sbvRunDemos :: IO JSString
sbvRunDemos = do
   report <- (runAll `C.catch` \(e :: C.SomeException) ->
                 pure ("SBV browser demo failed with an exception:\n" ++ show e))
   -- Also echo to stdout (captured by the WASI shim) so the result is visible
   -- even if the JS side ignores the returned string.
   putStr report
   pure (toJSString report)
  where
   runAll :: IO String
   runAll = do
      r1 <- sat   $ \x -> x * 3 .== (1 :: SWord8)
      r2 <- prove $ \x -> x + 1 .> (x :: SInteger)
      r3 <- prove $ \x -> (x :: SFloat) .== x
      pure $ unlines
         [ "SBV running in the browser via z3-solver (WebAssembly)."
         , ""
         , "sat   (x * 3 == 1 :: SWord8):"
         , "  " ++ show r1
         , ""
         , "prove (x + 1 > x :: SInteger):"
         , "  " ++ show r2
         , ""
         , "prove (x == x :: SFloat)   [exercises libBF floating point]:"
         , "  " ++ show r3
         ]

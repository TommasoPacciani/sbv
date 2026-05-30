-----------------------------------------------------------------------------
-- |
-- Module    : Data.SBV.Provers.Z3Wasm
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- The connection to the Z3 SMT solver running in-browser as a WebAssembly
-- module (the @z3-solver@ npm package, "Z3_WASM").
--
-- This mirrors "Data.SBV.Provers.Z3" but, instead of spawning an
-- operating-system process, it drives Z3_WASM through the browser engine
-- ('browserEngine' from "Data.SBV.SMT.BrowserEngine"). Accordingly it carries
-- no executable name (it is never looked up on a PATH) and passes no
-- command-line options (no @-nw@\/@-in@\/@-smt2@, no process arguments).
--
-- The capabilities are taken from native 'Data.SBV.Provers.Z3.z3' unchanged
-- /except/ that @supportsGlobalDecls@ is set to 'False': z3-solver drives a
-- single persistent context via @Z3_eval_smtlib2_string@, which rejects
-- @(set-option :global-declarations true)@ "after initialization". With the
-- capability off, SBV never sends that option (scoped declarations still work;
-- push/pop semantics then match a non-global-decls solver). Deriving the rest
-- from @Z3.z3@ keeps every other capability identical to native Z3 and avoids
-- duplicating the capabilities record.
-----------------------------------------------------------------------------

{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -Wall #-}

module Data.SBV.Provers.Z3Wasm(z3Wasm, z3WasmCapabilities) where

import Data.SBV.Core.Data

import qualified Data.SBV.Provers.Z3 as Z3

#ifdef SBV_WASM
-- The browser engine is only available on the WebAssembly target; on a native
-- GHC the module that defines it is not built, so the import stays guarded.
import Data.SBV.SMT.BrowserEngine (browserEngine)
#endif

-- | The description of the Z3 SMT solver running in the browser as a
-- WebAssembly module. Unlike the native 'Data.SBV.Provers.Z3.z3' solver, this
-- one has no executable to discover and passes no operating-system command-line
-- options to the solver; all communication is routed through 'browserEngine'.
z3Wasm :: SMTSolver
z3Wasm = Z3.z3 {
           executable   = ""           -- no executable; never looked up on a PATH
         , options      = const []     -- no -nw/-in/-smt2, no CLI args
#ifdef SBV_WASM
         , engine       = browserEngine
#else
         , engine       = error "Data.SBV.Provers.Z3Wasm.z3Wasm: the browser engine is only available on the WebAssembly (SBV_WASM) target"
#endif
         , capabilities = z3WasmCapabilities
         }

-- | The capabilities of Z3_WASM: native Z3's 'SolverCapabilities' with
-- @supportsGlobalDecls = False@ (see the module header for why).
z3WasmCapabilities :: SolverCapabilities
z3WasmCapabilities = (capabilities Z3.z3) { supportsGlobalDecls = False }

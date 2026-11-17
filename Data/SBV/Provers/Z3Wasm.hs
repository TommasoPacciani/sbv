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
-- It advertises exactly the same solver capabilities as native Z3 — including
-- @supportsIEEE754 = True@ — because the arbitrary-precision\/IEEE
-- floating-point paths are retained on the browser path: @libBF@ is compiled
-- for the WebAssembly target from its bundled portable C sources, so SBV's
-- @FloatingPoint@\/@FP@ type and the floating-point theories remain present in
-- the browser build.
-----------------------------------------------------------------------------

{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Data.SBV.Provers.Z3Wasm(z3Wasm, z3WasmCapabilities) where

import Data.SBV.Core.Data

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
z3Wasm = SMTSolver {
           name         = Z3
         , executable   = ""           -- no executable; never looked up on a PATH (Requirement 7.1)
         , preprocess   = id
         , options      = const []     -- no -nw/-in/-smt2, no CLI args         (Requirement 5.2)
#ifdef SBV_WASM
         , engine       = browserEngine
#else
         , engine       = error "Data.SBV.Provers.Z3Wasm.z3Wasm: the browser engine is only available on the WebAssembly (SBV_WASM) target"
#endif
         , capabilities = z3WasmCapabilities
         }

-- | The capabilities of Z3_WASM. These are identical to the native
-- 'Data.SBV.Provers.Z3.z3' 'SolverCapabilities', copied unchanged. In
-- particular @supportsIEEE754@ stays 'True': arbitrary-precision\/IEEE
-- floating-point support is retained on the browser path because @libBF@ is
-- compiled for the WebAssembly target (Requirements 5.6, 10).
z3WasmCapabilities :: SolverCapabilities
z3WasmCapabilities = SolverCapabilities {
                                supportsQuantifiers     = True
                              , supportsDefineFun       = True
                              , supportsDistinct        = True
                              , supportsBitVectors      = True
                              , supportsADTs            = True
                              , supportsUnboundedInts   = True
                              , supportsReals           = True
                              , supportsApproxReals     = True
                              , supportsDeltaSat        = Nothing
                              , supportsIEEE754         = True
                              , supportsSets            = True
                              , supportsOptimization    = True
                              , supportsPseudoBooleans  = True
                              , supportsCustomQueries   = True
                              , supportsGlobalDecls     = True
                              , supportsDataTypes       = True
                              , supportsLambdas         = True
                              , supportsSpecialRels     = True
                              , supportsDirectTesters   = False -- Needs ascriptions. (See the CVC4 version of this)
                              , supportsFlattenedModels = Just [ "(set-option :pp.max_depth      4294967295)"
                                                               , "(set-option :pp.min_alias_size 4294967295)"
                                                               , "(set-option :model.inline_def  true      )"
                                                               ]
                              }

-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.Z3WasmConfig
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Unit tests for the Z3_WASM solver-value and configuration wiring
-- (Requirements 1.2, 5.2, 5.6, 7.5; design components 3 and the @z3Wasm@
-- 'Data.SBV.SMTConfig' wrapper).
--
-- These tests assert the four pieces of wiring the spec pins down for the
-- browser-path Z3 solver value 'Data.SBV.Provers.Z3Wasm.z3Wasm' and its
-- user-facing 'Data.SBV.z3Wasm' configuration:
--
--   (1) @'options' ('solver' 'z3Wasm') cfg == []@ — the Z3_WASM value passes
--       /no/ operating-system command-line arguments (no @-nw@\/@-in@\/@-smt2@),
--       and it carries no executable to look up (Requirement 5.2).
--
--   (2) @'z3WasmCapabilities'@ equals native Z3's 'SolverCapabilities'
--       /unchanged/, in particular @'supportsIEEE754' = 'True'@, because the
--       arbitrary-precision\/IEEE floating-point paths are retained on the
--       browser path (Requirements 5.6, 10). 'SolverCapabilities' has no 'Eq'
--       instance, so the comparison is a field-by-field conjunction
--       ('sameCapabilities').
--
--   (3) @'engine' ('solver' 'z3Wasm')@ is 'browserEngine' (Requirement 1.2).
--
--   (4) Under @SBV_WASM@, @'defaultSMTCfg' == 'z3Wasm'@ (Requirement 7.5).
--
-- CPP-guarding (mirroring 'TestSuite.Wasm.SafeWithPaths' and
-- 'TestSuite.Wasm.ConcurrentRejection', which model the browser path on a stock
-- native GHC). The real 'browserEngine' lives behind @#ifdef SBV_WASM@ /and/
-- @if arch(wasm32)@: it is simply not compiled into the native test binary
-- (which is built without @-DSBV_WASM@), so the @engine@ field of the Z3_WASM
-- solver value is the documented @#else@ stub there, and 'defaultSMTCfg' is
-- 'z3' rather than 'z3Wasm'. The tests therefore split on @SBV_WASM@:
--
--   * @engine@ wiring (3): an 'SMTEngine' is a rank-2 @forall@ function and
--     cannot be compared with @(==)@. We instead force the @engine@ field to
--     weak-head normal form (WHNF). On the native build the field is literally
--     @'error' \"... only available on the WebAssembly (SBV_WASM) target\"@, so
--     forcing it /throws/ an 'ErrorCall' that names the WebAssembly-only engine
--     — which proves the native build correctly does /not/ wire 'browserEngine'
--     and that the choice is CPP-selected. Under @SBV_WASM@ the field is
--     'browserEngine', a genuine function whose WHNF is an ordinary closure, so
--     forcing it succeeds without executing anything (it never runs
--     @acquireSolver@).
--
--   * @defaultSMTCfg@ wiring (4): under @SBV_WASM@ we assert it matches 'z3Wasm';
--     natively we assert it matches 'z3' (the @#else@ branch) and that the two
--     configs are distinguishable, which together confirm the selection is
--     CPP-driven. 'SMTConfig' has no 'Eq' instance, so configs are compared
--     through a distinguishing signature ('cfgSig').
-----------------------------------------------------------------------------

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.Z3WasmConfig (tests) where

import Control.Exception (SomeException, try, evaluate)

import Data.Text (Text)

import Data.SBV.Internals (SolverCapabilities(..), State)

import Utils.SBVTestFramework

#ifndef SBV_WASM
import Data.List (isInfixOf)
#endif

-- | The Z3_WASM 'SolverCapabilities'. The defining
-- 'Data.SBV.Provers.Z3Wasm.z3Wasm' solver value wires
-- @capabilities = z3WasmCapabilities@, and that module is hidden
-- (@other-modules@) exactly like 'Data.SBV.Provers.Z3', so — following the
-- project convention of reaching a solver value through its public 'SMTConfig'
-- wrapper — we read 'z3WasmCapabilities' off the exported 'z3Wasm' config's
-- solver value rather than importing the hidden module.
z3WasmCapabilities :: SolverCapabilities
z3WasmCapabilities = capabilities (solver z3Wasm)

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.Z3WasmConfig"
   [ testCase "Z3WasmConfig.optionsAreEmpty"      optionsAreEmpty
   , testCase "Z3WasmConfig.noExecutable"         noExecutable
   , testCase "Z3WasmConfig.nameIsZ3"             nameIsZ3
   , testCase "Z3WasmConfig.capabilitiesMatchZ3"  capabilitiesMatchZ3
   , testCase "Z3WasmConfig.supportsIEEE754"      supportsIEEE754Retained
   , testCase "Z3WasmConfig.engineWiring"         engineWiring
   , testCase "Z3WasmConfig.defaultSMTCfgWiring"  defaultSMTCfgWiring
   ]

-- | (1) The Z3_WASM value passes no operating-system command-line arguments
-- (no @-nw@\/@-in@\/@-smt2@). Its @options@ field is @const []@, so applying it
-- to any configuration (here the 'z3Wasm' config itself) yields @[]@
-- (Requirement 5.2).
optionsAreEmpty :: Assertion
optionsAreEmpty = (options (solver z3Wasm) z3Wasm == ([] :: [String]))
                    @? "options (solver z3Wasm) cfg must be []"

-- | (1, cont.) The Z3_WASM value carries no executable: there is nothing to
-- look up on a PATH (Requirements 5.2, 7.1).
noExecutable :: Assertion
noExecutable = (executable (solver z3Wasm) == "")
                 @? "executable (solver z3Wasm) must be the empty string"

-- | The Z3_WASM value reports the same solver name as native Z3. 'Solver' has
-- no 'Eq' instance, so we compare its 'Show' rendering.
nameIsZ3 :: Assertion
nameIsZ3 = (show (name (solver z3Wasm)) == "Z3")
             @? "name (solver z3Wasm) must be Z3"

-- | (2) 'z3WasmCapabilities' equals native Z3's 'SolverCapabilities' unchanged
-- (Requirements 5.6, 10). Native Z3's capabilities are read off the public
-- 'z3' configuration's solver value.
capabilitiesMatchZ3 :: Assertion
capabilitiesMatchZ3 =
   sameCapabilities z3WasmCapabilities (capabilities (solver z3))
     @? "z3WasmCapabilities must equal native Z3's SolverCapabilities unchanged"

-- | (2, cont.) In particular IEEE-754 / arbitrary-precision floating-point
-- support stays advertised on the browser path because @libBF@ is compiled for
-- the WebAssembly target (Requirements 5.6, 10).
supportsIEEE754Retained :: Assertion
supportsIEEE754Retained = supportsIEEE754 z3WasmCapabilities
                            @? "z3WasmCapabilities must advertise supportsIEEE754 = True"

-- | (3) @'engine' ('solver' 'z3Wasm')@ is 'browserEngine' (Requirement 1.2).
--
-- An 'SMTEngine' is a rank-2 @forall@ function and is not comparable with
-- @(==)@, and the real 'browserEngine' is only compiled under @SBV_WASM@. We
-- therefore force the @engine@ field to WHNF (see 'forceEngine') and split on
-- the build:
--
--   * Under @SBV_WASM@: forcing succeeds (the field is the 'browserEngine'
--     closure), so we require 'Right'.
--   * Natively: the field is the documented @#else@ stub
--     (@error \"... only available on the WebAssembly (SBV_WASM) target\"@), so
--     forcing must throw an 'ErrorCall' naming the WebAssembly-only engine.
engineWiring :: Assertion
engineWiring = do
   r <- forceEngine (solver z3Wasm)
#ifdef SBV_WASM
   case r of
     Right () -> pure ()
     Left  e  -> assertFailure $ "engine (solver z3Wasm) should be browserEngine, but forcing it threw: " ++ show e
#else
   case r of
     Right () -> assertFailure "On the native build, engine (solver z3Wasm) must be the SBV_WASM-only stub, but forcing it succeeded."
     Left  e  -> let msg = show e
                 in ("WebAssembly" `isInfixOf` msg || "SBV_WASM" `isInfixOf` msg)
                      @? ("native stub error must name the WebAssembly-only engine, got: " ++ msg)
#endif

-- | (4) The default browser configuration is wired through CPP
-- (Requirement 7.5):
--
--   * Under @SBV_WASM@: @'defaultSMTCfg' == 'z3Wasm'@.
--   * Natively: @'defaultSMTCfg' == 'z3'@ (the @#else@ branch), and 'z3' and
--     'z3Wasm' are distinguishable, so the CPP selection is meaningful.
--
-- 'SMTConfig' has no 'Eq' instance; configs are compared via 'cfgSig'.
defaultSMTCfgWiring :: Assertion
defaultSMTCfgWiring =
#ifdef SBV_WASM
   (cfgSig defaultSMTCfg == cfgSig z3Wasm)
     @? "under SBV_WASM, defaultSMTCfg must be z3Wasm"
#else
   do (cfgSig defaultSMTCfg == cfgSig z3)
        @? "natively, defaultSMTCfg must be z3"
      (cfgSig z3 /= cfgSig z3Wasm)
        @? "the z3 and z3Wasm configurations must be distinguishable"
#endif

-- | Force the @engine@ field of a solver value to weak-head normal form,
-- capturing any exception. The explicit monomorphic annotation (@res = ()@)
-- instantiates the rank-2 'SMTEngine' @forall@ so the value can be 'evaluate'd;
-- it does /not/ apply the engine, so 'browserEngine' is never executed — only
-- forced to WHNF (an ordinary function closure on the browser build, the
-- @error@ stub on the native build).
forceEngine :: SMTSolver -> IO (Either SomeException ())
forceEngine s = try $ do
   let e = engine s :: SMTConfig -> State -> Text -> (State -> IO ()) -> IO ()
   _ <- evaluate e
   pure ()

-- | A distinguishing signature for an 'SMTConfig', used to compare configs in
-- the absence of an 'Eq' instance. It captures the solver name (via 'Show', as
-- 'Solver' has no 'Eq'), the executable, the command-line options the solver
-- would pass, and the start-up options (via 'Show', as 'SMTOption' has no
-- 'Eq'). These differ between 'z3' (executable @\"z3\"@, options
-- @[\"-nw\",\"-in\",\"-smt2\"]@) and 'z3Wasm' (no executable, no options), so
-- the signature uniquely tells the two apart.
cfgSig :: SMTConfig -> (String, String, [String], [String])
cfgSig cfg = ( show (name       (solver cfg))
             , executable (solver cfg)
             , options    (solver cfg) cfg
             , map show (solverSetOptions cfg)
             )

-- | Field-by-field equality of two 'SolverCapabilities' (which has no derived
-- 'Eq' instance). Every field is compared so that any future capability change
-- on either the native Z3 or the Z3_WASM side is caught here.
sameCapabilities :: SolverCapabilities -> SolverCapabilities -> Bool
sameCapabilities a b =
      supportsQuantifiers     a == supportsQuantifiers     b
   && supportsDefineFun       a == supportsDefineFun       b
   && supportsDistinct        a == supportsDistinct        b
   && supportsBitVectors      a == supportsBitVectors      b
   && supportsADTs            a == supportsADTs            b
   && supportsUnboundedInts   a == supportsUnboundedInts   b
   && supportsReals           a == supportsReals           b
   && supportsApproxReals     a == supportsApproxReals     b
   && supportsDeltaSat        a == supportsDeltaSat        b
   && supportsIEEE754         a == supportsIEEE754         b
   && supportsSets            a == supportsSets            b
   && supportsOptimization    a == supportsOptimization    b
   && supportsPseudoBooleans  a == supportsPseudoBooleans  b
   && supportsCustomQueries   a == supportsCustomQueries   b
   && supportsGlobalDecls     a == supportsGlobalDecls     b
   && supportsDataTypes       a == supportsDataTypes       b
   && supportsLambdas         a == supportsLambdas         b
   && supportsSpecialRels     a == supportsSpecialRels     b
   && supportsDirectTesters   a == supportsDirectTesters   b
   && supportsFlattenedModels a == supportsFlattenedModels b

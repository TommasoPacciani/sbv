# Implementation Plan: SBV Browser WASM Backend

## Overview

This plan implements **SBV_Browser**: a browser-usable build of SBV (v14.2) that drives the
`z3-solver` WASM npm package through GHC's WebAssembly JSFFI instead of spawning an OS Z3 process.
The work is a second `SMTEngine` implementation (`browserEngine`) plus the cross-cutting CPP/cabal
plumbing that keeps the native build behaviorally identical while removing `System.Process`,
`System.Directory`, and `System.Environment` from the browser path (libBF is retained and compiled
for wasm).

Implementation language is **Haskell** (the design is concrete Haskell over the existing SBV code
base; no pseudocode language selection is required). Property-based tests use **QuickCheck** (already
a dependency of `SBVTestSuite`), one test per correctness property, each tagged with a comment of the
form `-- Feature: sbv-browser-wasm-backend, Property N: <text>`.

The build order follows the seam: first the `MockBridge` test harness and shared types, then the
real `WasmBridge` and its state machine, then `browserEngine`, then the `z3Wasm` solver value and
config, then the cross-cutting virtualization (transcript sink, `safeWith`, concurrency, libBF
compilation for wasm), then the cabal/CPP wiring, and finally the property/static/smoke tests.

## Tasks

- [x] 1. Define shared browser-path types and the bridge interface
  - [x] 1.1 Create `Data.SBV.SMT.WasmBridge` skeleton with the bridge data types and the abstract interface
    - Create `Data/SBV/SMT/WasmBridge.hs` (module header, `OPTIONS_GHC -Wall`, export list)
    - Define `newtype WasmSolver = WasmSolver JSVal`, `data WasmSolverState = NotLoaded | Loading | Ready WasmSolver | Failed SolverFailure`, and `data SolverFailure = SolverRejected String | SolverTimedOut String | SolverLoadError String | SolverInitError String`
    - Declare the interface signatures that both the real bridge and the test `MockBridge` will satisfy: `sendCommand :: WasmSolver -> Maybe Int -> Text -> IO (Either SolverFailure Text)`, `acquireSolver :: IO WasmSolver`, and `release :: WasmSolver -> IO ()`
    - Keep all JSFFI imports out of this skeleton commit so the types compile under a normal (native) GHC for the test harness; gate JS-only code behind `#ifdef SBV_WASM` in later tasks
    - _Requirements: 1.1, 3.1, 13.1, 13.2_

- [x] 2. Build the MockBridge test harness
  - [x] 2.1 Implement the `MockBridge` reusable harness
    - Create `SBVTestSuite/Utils/MockBridge.hs` implementing the same `sendCommand`/`acquireSolver`/`release` interface as `Data.SBV.SMT.WasmBridge`
    - Record every message sent (ordered transcript of `Text`), expose scripted responses, scripted `SolverFailure`s, and scripted timing/delay so `Promise.race` timeout behavior can be simulated deterministically
    - Provide a capturing native transport mock (records the byte sequence handed to a solver) so Property 1 can compare browser vs native transmission
    - Register `Utils.MockBridge` in the `SBVTest` test-suite `other-modules` list in `sbv.cabal`
    - _Requirements: 3.3, 4.2_

- [ ] 3. Implement the WasmBridge JSFFI bindings and async→sync primitive
  - [x] 3.1 Implement the JSFFI imports and Haskell-facing `sendCommand`
    - Under `#ifdef SBV_WASM` in `Data.SBV.SMT.WasmBridge`, add `foreign import javascript safe` bindings: `js_initZ3Wasm :: IO JSVal`, `js_send :: JSVal -> JSString -> IO JSString`, `js_release :: JSVal -> IO ()`
    - Implement `sendCommand`: convert `Text`↔`JSString`, await the `js_send` Promise, translate a Promise rejection into `SolverRejected`, and return `Either SolverFailure Text`
    - Implement `release` over `js_release` so it is idempotent and never throws across the boundary
    - _Requirements: 2.1, 2.2, 3.1, 3.2, 13.4_
  - [x] 3.2 Implement the JS-side Query_Timeout via `Promise.race`
    - When `sendCommand` is given `Just µs`, race the `js_send` Promise against a `setTimeout`-backed timer Promise on the JS side; on timer-win return `SolverTimedOut` naming the command
    - When given `Nothing`, create no timer and await unbounded (matching Native_SBV), explicitly not using `System.Timeout`
    - _Requirements: 3.5, 13.5, 13.6_
  - [-] 3.3 Write property test for ordering / single-in-flight (via MockBridge)
    - **Property 4: Responses are delivered in command order, one in flight at a time**
    - **Validates: Requirements 3.3**
  - [-] 3.4 Write property test for Query_Timeout bounding (via MockBridge scripted timing)
    - **Property 6: Query_Timeout bounds the wait; absence waits indefinitely**
    - **Validates: Requirements 1.6, 3.5, 13.5**

- [ ] 4. Implement the one-time initialization state machine and single-in-flight guard
  - [x] 4.1 Implement `acquireSolver` over `WasmSolverState`
    - Add a module-level `IORef WasmSolverState` (initial `NotLoaded`); implement `acquireSolver`: `NotLoaded` → set `Loading`, call `js_initZ3Wasm`, then transition to `Ready`/`Failed` and wake awaiters; `Loading` → await the same in-flight init Promise (no re-init); `Ready h` → return `h`; `Failed e` → throw a descriptive `SBVException` naming the load vs init phase
    - Distinguish `SolverLoadError` (module load failed) from `SolverInitError` (loaded but instance creation failed) so the two are textually distinguishable
    - _Requirements: 5.3, 5.4, 5.5, 13.1, 13.2_
  - [x] 4.2 Implement the single-slot in-flight ordering guard
    - Add an `IORef Bool`/`MVar ()`-as-mutex (not for thread draining) that `sendCommand` claims before awaiting and releases immediately after delivering the response, refusing a new await while held
    - _Requirements: 3.3_
  - [-] 4.3 Write property test for at-most-once initialization and no stranded operations (via MockBridge)
    - **Property 7: Initialization happens at most once and never strands queued operations**
    - **Validates: Requirements 5.3, 5.4, 5.5**

- [ ] 5. Implement the BrowserEngine
  - [x] 5.1 Implement `browserEngine :: SMTEngine` closures over the bridge
    - Create `Data/SBV/SMT/BrowserEngine.hs` exporting `browserEngine`, mirroring `runSolver`'s structure: build `send`/`ask`/`getResponseFromSolver`/`terminateSolver`/`cleanUp` closures that call `WasmBridge.sendCommand` instead of `TIO.hPutStrLn`/`hGetLine`
    - `ask` reproduces the native short-circuit: after `T.dropWhile isSpace command`, if `T.null` or prefix `";"`, return `"success"` and forward nothing
    - `getResponseFromSolver` reuses `Data.SBV.Utils.SExpr.parenDeficit` accumulation, returning only when parentheses are balanced AND the s-expression is complete; never short-read into the next response
    - Use no handle I/O (`hGetLine`/`hReady`/`hGetChar`/`hFlush`/`hClose`/`hGetContents`) and no `forkIO`/`MVar` draining
    - See design "Module layering and import direction (acyclicity)": transcribe `sendAndGetSuccess` locally; do not import `SMT.SMT`/`Control.*` (Rules R1, R2)
    - _Requirements: 1.2, 1.3, 2.3, 2.4, 2.5, 9.2_
  - [x] 5.2 Construct the `QueryState` and run the continuation with the print-success heartbeat
    - Reuse the existing `(set-option :print-success true)` heartbeat coordination and global-declarations/dump-`pgm` sequence (the same `sendAndGetSuccess` flow used natively, not reimplemented)
    - Build `QueryState { queryAsk, querySend, queryRetrieveResponse = getResponseFromSolver Nothing, queryConfig = cfg, queryTerminate = cleanUp, queryTimeOutValue = Nothing, queryAssertionStackDepth = 0 }` and store it in `rQueryState ctx`, then invoke the continuation
    - _Requirements: 1.3, 6.1, 6.2, 6.3_
  - [x] 5.3 Implement `cleanUp`/`terminateSolver` finalization and the unconfigured-fields error
    - `cleanUp` releases WASM resources via `WasmBridge.release` and re-raises the original forwarded exception (never substituting a resource-release error); task success = a complete response to the final command was retrieved, independent of any `ExitCode`; no `waitForProcess`/`terminateProcess`
    - If the `queryAsk`/`querySend`/`queryRetrieveResponse` communication fields are not configured, send nothing and report a configuration error
    - _Requirements: 1.4 (first), 8.1, 8.2, 8.3, 8.4, 8.5_
  - [-] 5.4 Surface Solver_Failure as SBVException carrying command + partial response
    - In the `ask`/`getResponseFromSolver` path, on `Left SolverFailure` before a complete balanced s-expression, raise `SBVException` with `sbvExceptionSent` = command and `sbvExceptionReceived` = partial text, release the request's resources, and return no result; route non-`success`/unparseable responses through the existing `sendAndGetSuccess` failure construction
    - _Requirements: 1.5, 2.6, 3.4, 13.3, 13.4_
  - [~] 5.5 Write property test for response accumulation (via MockBridge chunked s-expressions)
    - **Property 2: Response accumulation returns the complete balanced s-expression**
    - **Validates: Requirements 2.4**
  - [~] 5.6 Write property test for empty/comment short-circuit (via MockBridge)
    - **Property 3: Empty and comment commands are short-circuited**
    - **Validates: Requirements 2.5**
  - [~] 5.7 Write property test for failure surfacing (via MockBridge scripted failures)
    - **Property 5: Failures surface as an SBVException carrying the command and partial response**
    - **Validates: Requirements 1.5, 2.6, 3.4, 13.3, 13.4**
  - [~] 5.8 Write property test for aborting-cleanup exception fidelity (via MockBridge scripted release outcomes)
    - **Property 10: Aborting cleanup re-raises the original exception after releasing resources**
    - **Validates: Requirements 8.3, 8.4, 8.5**

- [~] 6. Checkpoint - Ensure engine and bridge tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 7. Implement the Z3_WASM solver value and configuration
  - [x] 7.1 Implement `Data.SBV.Provers.Z3Wasm` with `z3Wasm :: SMTSolver` and `z3WasmCapabilities`
    - Create `Data/SBV/Provers/Z3Wasm.hs` mirroring `Data.SBV.Provers.Z3`: `name = Z3`, `executable = ""`, `preprocess = id`, `options = const []`, `engine = browserEngine`
    - Define `z3WasmCapabilities` by copying Z3's `SolverCapabilities` unchanged (including `supportsIEEE754 = True`), because arbitrary-precision/IEEE floating-point support is retained on the browser path (libBF is compiled for wasm)
    - _Requirements: 5.1, 5.2, 5.6, 7.1, 10_
  - [x] 7.2 Add the `z3Wasm :: SMTConfig` wrapper and CPP-select `defaultSMTCfg` in `Data.SBV.Provers.Prover`
    - Add `z3Wasm = mkConfig Z3Wasm.z3Wasm SMTLib2 [ Control.OptionKeyword ":smtlib2_compliant" ["true"] ]` and export it
    - CPP: `#ifdef SBV_WASM` set `defaultSMTCfg = z3Wasm` else `defaultSMTCfg = z3`
    - _Requirements: 5.1, 7.5_
  - [-] 7.3 Write unit tests for the Z3_WASM configuration wiring
    - Assert `engine (solver z3Wasm)` is `browserEngine`; `options (solver z3Wasm) cfg == []`; `z3WasmCapabilities` equals Z3's capabilities unchanged (including `supportsIEEE754 = True`); under `SBV_WASM`, `defaultSMTCfg == z3Wasm`
    - _Requirements: 1.2, 5.2, 5.6, 7.5_

- [ ] 8. Implement the transcript sink virtualization
  - [x] 8.1 Create `Data.SBV.SMT.TranscriptSink` and route transcript functions through it
    - Create `Data/SBV/SMT/TranscriptSink.hs` defining `data TranscriptSink = FileSink FilePath | BrowserSink (Text -> IO ())`
    - Refactor `startTranscript`/`recordTranscript`/`finalizeTranscript` in `Data.SBV.SMT.Utils` to emit the same textual content (start banner, `SentMsg`/`RecvMsg`/`DebugMsg` records, finalize banner) through a `TranscriptSink`; native uses `FileSink` (existing `writeFile`/`appendFile`), browser uses `BrowserSink` appending to an in-memory `IORef Text`/console with no OS file write
    - CPP-guard `startTranscript`'s `findExecutable` call to a no-op on the browser path
    - _Requirements: 7.1, 11.1, 11.2_
  - [-] 8.2 Write property test for transcript-sink content equivalence
    - **Property 11: The transcript sink retains identical content**
    - **Validates: Requirements 11.2**

- [x] 9. Virtualize `safeWith` and route concurrent combinators
  - [x] 9.1 CPP-guard `getCurrentDirectory` in `Data.SBV.Provers.Prover.safeWith`
    - Under `#ifdef SBV_WASM`, skip `getCurrentDirectory` and make `mkRelative = id` so each `SafeResult` reports its source-location path unmodified; `#else` keeps the existing relativization
    - _Requirements: 11.3_
  - [x] 9.2 CPP-route concurrent combinators to a synchronous unsupported-operation error on the browser path
    - Under `#ifdef SBV_WASM`, make `proveWithAny`/`proveWithAll`/`satWithAny`/`satWithAll` raise an `SBVException` naming the invoked combinator, returned synchronously (no `forkIO`/`async`/await), after ensuring no WASM session is left active; single-solver `prove`/`sat`/`allSat`/`optimize` keep running on the single thread with no `forkIO`
    - _Requirements: 9.1, 9.4, 9.5_
  - [x] 9.3 Implement the un-virtualizable filesystem-op explicit error helper
    - Add a shared helper (browser path) that, when a Solving_API code path attempts an un-virtualizable OS filesystem operation, prevents the access and raises an explicit `SBVException` naming the unsupported filesystem operation
    - _Requirements: 11.4_
  - [x] 9.4 Write property test for `safeWith` path reporting
    - **Property 12: safeWith reports source-location paths unmodified**
    - **Validates: Requirements 11.3**
  - [x] 9.5 Write property test for synchronous concurrent-combinator rejection
    - **Property 13: Concurrent combinators are rejected synchronously without leaving a session active**
    - **Validates: Requirements 9.4, 9.5**

- [x] 10. Compile libBF for the WASM target and retain the floating-point code paths
  - [x] 10.1 Revert any prior `#ifdef SBV_WASM` floating-point exclusion in `Data.SBV.Core.Operations` and `Data.SBV.Core.Floating` and confirm the FP paths build unchanged on the browser path
    - Remove the previously-added `#ifndef SBV_WASM` guards around the `LibBF` import (restore the plain `import LibBF`) in `Data.SBV.Core.Operations` and `Data.SBV.Core.Floating`
    - Remove the `unsupportedFPOp`/unsupported-feature helper stubs and their `#ifdef SBV_WASM` call sites that were added for the old exclusion approach
    - Confirm `Data.SBV.Core.Operations`, `Data.SBV.Core.Floating`, `Data.SBV.Core.SizedFloats`, and `Data.SBV.Utils.CrackNum` compile unchanged for both native and wasm; `libBF`'s bundled portable C is compiled by the wasm clang toolchain
    - _Requirements: 10.2, 10.3, 10.4_

- [ ] 11. Wire the dual-target build configuration in `sbv.cabal`
  - [~] 11.1 Add `arch(wasm32)` conditionals to the library stanza
    - In the `if arch(wasm32)` branch: add `cpp-options: -DSBV_WASM`, drop `process`/`directory` from `build-depends` (KEEP `libBF`, whose bundled C is compiled for wasm), and add the new modules (`Data.SBV.SMT.WasmBridge`, `Data.SBV.SMT.BrowserEngine`, `Data.SBV.Provers.Z3Wasm`, `Data.SBV.SMT.TranscriptSink`)
    - In the `else` branch: keep `process`, `directory`, `libBF` and the existing module set so the native dependency set and behavior are unchanged
    - _Requirements: 10.1, 10.5, 10.6, 12.1, 12.2, 12.3, 12.5, 12.6_

- [~] 12. Checkpoint - Ensure native build and existing suite are unchanged
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 13. Add structural / "no-OS-API" static checks
  - [~] 13.1 Implement static source-scan tests over the browser Solving_API path
    - Add `SBVTestSuite/TestSuite/Wasm/Static.hs` asserting the `#ifdef SBV_WASM` source of `WasmBridge`/`BrowserEngine`/`Z3Wasm`/`TranscriptSink` and the guarded sections reference no `System.Process`, `System.Directory`, or `System.Environment` symbol; no `forkIO`/`MVar` draining; no `commTimeOutScaler`/`setCommandTimeOut`/`defaultLineTimeOut`; timeout enforced via the JS race, not `System.Timeout`; response parsing/model extraction reuse existing functions with no alternative parser/extractor; browser path exposes the same Solving_API signatures as native
    - Register the module in `SBVTest.hs` and `sbv.cabal`
    - _Requirements: 2.1, 2.3, 4.3, 4.4, 7.2, 7.3, 7.4, 8.1, 9.2, 11.1, 12.3, 13.6, 14.1_

- [ ] 14. Add query-mode and session property tests
  - [~] 14.1 Write property test for session state preservation (via MockBridge push/pop/declare/assert sequences)
    - **Property 8: Query sessions preserve solver state across commands**
    - **Validates: Requirements 6.1, 6.3**
  - [~] 14.2 Write property test for invalid stack/session rejection (via MockBridge)
    - **Property 9: Stack and session operations are rejected when invalid**
    - **Validates: Requirements 6.4, 6.5, 6.6**

- [ ] 15. Add transmission-parity and example/edge unit tests
  - [~] 15.1 Write property test for byte-identical transmission (browser vs native capturing mock)
    - **Property 1: Browser transmission is byte-identical to native**
    - Drive `browserEngine` over `MockBridge` and the native engine over the capturing transport mock for the same generated problems; compare transmitted byte sequences (excluding OS command-line options)
    - **Validates: Requirements 2.2, 4.1, 4.2**
  - [~] 15.2 Write unit/example tests for engine wiring and error distinctions
    - `(set-option :print-success true)` heartbeat returns `success` (6.2); unconfigured-fields configuration error (1.4 first); load- vs init-phase error distinction (13.1, 13.2); un-virtualizable FS-op error (11.4); final-command success independent of `ExitCode` (8.2)
    - _Requirements: 1.4 (first), 6.2, 8.2, 11.4, 13.1, 13.2_

- [ ] 16. Add solver-backed parity property tests
  - [~] 16.1 Write property test for classification parity (native Z3 vs Z3_WASM, reduced budget)
    - **Property 14: Classification matches native**
    - Run 20–50 randomized iterations over bool/bit-vector/unbounded-integer/real generators; assert identical classification from {satisfiable, unsatisfiable, unknown}
    - **Validates: Requirements 14.2** (and 10.3)
  - [~] 16.2 Write property test for model soundness (reduced budget)
    - **Property 15: A satisfiable model satisfies every submitted constraint**
    - Run 20–50 randomized iterations; assert the returned model evaluates every submitted constraint to true, using SBV's existing model-extraction logic
    - **Validates: Requirements 14.3, 14.4** (and 10.3)

- [ ] 17. Add build/integration smoke tests
  - [~] 17.1 Add a CI script that builds the `arch(wasm32)` target and scans the artifact
    - Add a build smoke script (e.g. under `buildUtils/`) that runs the native build + golden tests unchanged, runs the `wasm32-wasi-cabal build`, verifies a loadable artifact, verifies the wasm artifact LINKS libBF (its bundled portable C compiled in) and that an arbitrary-precision floating-point solve works through the compiled libBF; assert that if the bundled libBF C sources fail to compile/link for wasm the build fails with detailed errors rather than silently producing an artifact (10.6); separately keep a partial-exclusion check that a leftover `System.Process`/`System.Directory`/`System.Environment` dependency on the Solving_API path fails the build (12.4)
    - Wire the script into `.github/workflows/ci.yml`
    - _Requirements: 10.1, 10.3, 10.4, 10.6, 12.1, 12.2, 12.4, 12.5_

- [~] 18. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional (tests) and can be skipped for a faster MVP; core implementation tasks are never optional.
- Each task references specific requirement sub-clauses (and, for PBT tasks, the design property number) for traceability.
- P1–P13 are exercised through the `MockBridge` harness (Task 2) and need no real solver; P14–P15 are solver-backed at a reduced iteration budget (20–50) but still randomized.
- Every property-based test carries a `-- Feature: sbv-browser-wasm-backend, Property N: <text>` comment and uses QuickCheck with a minimum of 100 iterations for P1–P13.
- The native build and behavior remain byte-for-byte identical: all browser code lives behind `#ifdef SBV_WASM` and `if arch(wasm32)` cabal conditionals.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["3.1", "8.1", "9.1", "10.1"] },
    { "id": 2, "tasks": ["2.1", "3.2", "5.1", "9.2"] },
    { "id": 3, "tasks": ["4.1", "5.2", "7.1", "9.3"] },
    { "id": 4, "tasks": ["4.2", "5.3", "7.2", "9.4", "9.5"] },
    { "id": 5, "tasks": ["5.4", "3.3", "3.4", "4.3", "7.3", "8.2"] },
    { "id": 6, "tasks": ["11.1"] },
    { "id": 7, "tasks": ["5.5", "5.6", "5.7", "5.8", "14.1", "14.2"] },
    { "id": 8, "tasks": ["15.1", "15.2", "16.1", "16.2", "13.1", "17.1"] }
  ]
}
```

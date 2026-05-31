# Demo notes (for the review)

## The one-liner
We run **unmodified SBV** in the browser. SBV thinks it's spawning a solver
process and talking to it over Unix pipes; in reality the "OS" is faked and the
solver is a `wasm32-wasi` binary in another Web Worker, connected by
`SharedArrayBuffer`.

## What to show live
```sh
cd web && npm run serve            # http://localhost:8080
```
The page prints, computed entirely client-side:
```
sat   (x * 3 == 1 :: SWord8):  Satisfiable. Model: s0 = 171 :: Word8
prove (x + 1 /= x :: SWord8):  Q.E.D.
```
(171·3 = 513 ≡ 1 mod 256.) Headless-Chrome and Node checks reproduce it:
`node web/test/e2e.test.mjs`, `bash web/test/run-browser-check.sh`.

## Why this design (the headline)
- **SBV is pristine.** We *reverted* the previous in-tree browser fork (deleted
  `WasmBridge`/`BrowserEngine`/`Z3Wasm`, removed every `#ifdef SBV_WASM`). SBV's
  real `runSolver` runs unchanged. Upgrading SBV no longer means re-doing a port.
- **All browser-specific code is out of tree:** a ~70-line Haskell shim package
  (`os-shim`), the JS runtime (`web/src/`), and a 2-line `cabal` stanza.
- **The solver is swappable.** It's selected by executable name, exactly like
  native SBV. Boolector today; cvc5/Bitwuzla/z3 later with zero SBV changes.

## How it works (30 seconds)
1. SBV (GHC→wasm) runs in a Worker and calls `runInteractiveProcess "boolector"`.
2. The shim's `System.Process` asks the page to start a second Worker running
   `boolector.wasm`, and hands SBV three `fdToHandle'` pipe handles.
3. Those handles are `browser_wasi_shim` fds backed by `SharedArrayBuffer` ring
   buffers; blocking reads use `Atomics.wait`. SBV's `hPutStrLn`/`hGetLine` work
   verbatim. SMT-LIB2 flows in, answers flow back.

## What we deliberately did NOT do
- **No forking z3.** Building z3→wasm needed source edits for wasi-libc gaps
  (e.g. missing `fenv` macros). Forking z3 reintroduces the maintenance burden we
  removed from SBV, so we used a maintained prebuilt WASI solver (YoWASP Boolector).
- **No Microsoft `z3-solver` shortcuts.** The old path replayed the whole script
  per command (O(n²)) and couldn't set `:global-declarations`. The native-process
  model has neither problem — state lives in one long-lived solver process.

## Honest limitations / next steps
- Boolector ⇒ bit-vector/array theories only (demo is `SWord8`). For
  integers/reals/floats: build a `wasm32-wasi` cvc5/Bitwuzla, or wrap the
  emscripten z3 as a persistent-context pipe-process. Either is a drop-in.
- Single-threaded solver; no query timeouts wired yet (pipe already supports a
  deadline). Both are incremental, not architectural.

## Proof points (all green)
`pipe-pingpong` (blocking SAB pipe) · `solver-pipe` (real boolector over pipes) ·
`hs-probe` (GHC-wasm Handle I/O over a PipeFd) · `e2e` (full SBV→Boolector) ·
`run-browser-check` (the real page in headless Chrome).

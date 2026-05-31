# Requirements — full-theory SMT solvers (z3 + cvc5) from source, in the browser

## Goal
Run pristine SBV's native engine in the browser solving **Int / Real / Float**
(not just bit-vectors) by building **z3** and **cvc5** from source to
**single-threaded emscripten WASM** and driving each as a faked stdin/stdout
process over the existing `SharedArrayBuffer` pipes — the clean drop-in that
needs **no SBV source change** and **no nested reader worker**.

## Requirements (EARS)

- **R1 From-source & reproducible.** WHEN a solver is built, the build SHALL use
  a pinned solver tag and a pinned emscripten (emsdk) version via one script per
  solver, with no manual steps.
- **R2 Drop-in process model.** Each solver SHALL run as a command that reads
  SMT-LIB2 on **stdin** and writes answers on **stdout** — the same contract as
  `boolector.wasm` — selected purely by executable name. SBV source SHALL remain
  byte-for-byte upstream.
- **R3 Single-threaded.** Each solver WASM SHALL be built without pthreads, so a
  dedicated Web Worker MAY block on the SAB pipe (`Atomics.wait`) for stdin. No
  nested reader worker; the Node and browser code paths SHALL be identical.
- **R4 End-to-end full theories.** `satWith z3`/`satWith cvc5` of `SInteger`,
  `SReal`, and `SDouble` SHALL succeed live in both headless Chrome and Node.
- **R5 Robustness.** Builds SHALL fail loudly on version drift; every artifact
  SHALL pass a standalone SMT2 smoke test (sat + get-value) before integration;
  the existing bit-vector Boolector MVP SHALL stay green.
- **R6 Multi-solver routing.** The page broker SHALL route `boolector` → the WASI
  worker and `z3`/`cvc5` → the emscripten-CLI worker; adding/swapping a solver
  SHALL be an executable-name change only.

## Out of scope
- Multi-threaded / portfolio solving (`parallel.enable`).
- Query timeouts (tracked separately; `poll.js` exists but is not wired here).
- A true `wasm32-wasi` z3/cvc5 (no prebuilt exists; a wasi port needs solver
  source patches — rejected by the project's "don't patch solvers" principle).

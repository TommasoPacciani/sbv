# CEGIS / async solver-handle on wasm — investigation

## Status: BLOCKED on the single-threaded wasm RTS (verification works; synthesis does not)

## Finding
Grisette's CEGIS has two layers:
- `solverGenericCEGIS`, `solverCegis`, `solverCegisForAll`, … — the **algorithm**,
  parameterized over a `Solver handle` (only needs the `Solver` class methods).
- `cegis`, `cegisForAll`, … — open a handle via `newSolver config` and delegate.

The only `Solver` instance, `SBVSolverHandle` (`newSolver`), runs the solver in a
`Control.Concurrent.Async` thread, talks to it over STM `TChan`s, and tears down
with `throwTo`. On the single-threaded GHC-wasm RTS, a forked green thread doing
the blocking foreign solver read (`Atomics.wait`) plus async-exception teardown
raises an uncatchable `WebAssembly.Exception`.

**Empirically anchored this session:** `solve` (async handle) traps; `solveSync`
(`runSBVIncremental cfg . monadicSolverSolve`, main thread, identical solver work)
succeeds in Node + headless Chrome. So the async **handle** is the blocker, not
Grisette's logic, SBV, or the solver bridge.

## Why a synchronous `Solver` handle isn't a drop-in
`runSMTWith cfg (query act)` runs `act` to completion in one call — it can't be
paused to accept external commands. The handle's async-thread+channels exist
precisely to interleave an external command stream with a live `query` session.
Without threads you can't keep one session alive across external calls.

## Recommended path — out-of-tree synchronous CEGIS (no Grisette fork)
CEGIS-for-all only needs: (1) a persistent **synth** role (∃s) accumulating
counterexample constraints, and (2) a **verify** role (∀x) where `s` is concrete.
Because the verify query has `s` fixed, it is independent of the synth session —
so the whole loop can run on the main thread as repeated `runSBVIncremental`
calls, with the synth re-run from scratch each round over all collected
counterexamples (stateless resynth). Sketch:

```
loop cexs = do
  -- synth: find s s.t. spec(x_i) = sketch(s,x_i) for all collected cex x_i
  ms <- solveSync z3 (andAll [ eval spec_i .== evalSketch s_i | x_i <- cexs ])
  case ms of
    Left _      -> pure Nothing                 -- no candidate => fail
    Right model -> do
      let s = concretize holes model
      -- verify: exists x. spec(x) /= sketch(s,x) ?
      mv <- solveSync z3 (eval spec ./= evalSketch s)
      case mv of
        Left Unsat   -> pure (Just s)            -- verified for all x
        Right cexMdl -> loop (extractInput cexMdl : cexs)
```
All pieces (`evalSym`, `extractSym`, model/symbol-set ops, `solveSync`) are
exported and already run on wasm. This reuses the proven synchronous path; it is
a real but bounded reimplementation of `solverGenericCEGIS` against the main
thread instead of the async handle.

## Alternatives
- **Threaded wasm RTS / working forkIO+blocking-foreign:** would let the existing
  `cegisForAll` run unchanged. Needs GHC-wasm RTS support (not available today);
  worth re-checking on RTS updates.
- **Patch Grisette** to add a synchronous `Solver` instance / CEGIS driver —
  forks Grisette; against the keep-upstream-pristine principle.

## Scope reminder
Supported on wasm now: full symbolic modeling + **one-shot/verification** solving
(`solveSync`). Not yet: synthesis (CEGIS), the persistent `Solver` handle, and
`withTimeout` (separate `System.Timeout` trap). All three share the same root:
RTS concurrency / async on the single-threaded wasm runtime.

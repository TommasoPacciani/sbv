# Session summary — SBV in the browser (native engine + faked OS)

Branch `wasm/native-process-prototype` (off `wasm/12.1`). Local only, not pushed.

## What we agreed on (principles)

- **Don't fork SBV, don't fork the solver.** Both are consumed pristine. All
  browser-specific code lives out of tree: a Haskell shim package, the `web/` JS
  runtime, and a tiny `cabal` stanza. Bumping SBV/solver = rebuild, not re-patch.
  This was the explicit reason we *reverted* the earlier in-tree browser fork.
- **Use the native engine, fake the OS around it.** SBV's real `runSolver`
  (`System.Process` + pipe `Handle`s) runs unchanged; we shim the OS so it spawns
  an in-browser solver and talks SMT-LIB2 over pipes — exactly like desktop.
- **Reuse other people's maintained work; avoid building/patching solvers.**
  Rejected building Z3→wasm (needed edits to z3 sources for wasi-libc gaps).
- **Solver is swappable by executable name** (SBV's existing multi-solver design).
- **Long-term goal:** full interop with Grisette (Grisette → SBV → solver), which
  requires SBV's full theory range working in the browser.

## What we did (all verified; commits in order)

1. `9485f97` — baseline + `requirements.md` / `design.md`.
2. `d94723f` — **solver, no build/fork:** vendored YoWASP's prebuilt
   `wasm32-wasi` **Boolector**; validated under `node:wasi` that it answers SBV's
   exact stdin protocol (`:print-success`, `check-sat`, `get-value`).
3. `0203d207` — **runtime** (2 Opus subagents, re-verified): `sabpipe.js`
   (blocking `SharedArrayBuffer` ring buffer), `pipefd.js` (`browser_wasi_shim`
   `Fd`), `solver-worker.js`. Proven: the real `boolector.wasm` runs under the
   browser WASI shim over the pipes.
4. `67fde4f` — **de-risk probe:** a standalone GHC-wasm program proved
   `hPutStrLn`/`hGetLine` over `fdToHandle'` of a *blocking* `PipeFd` works with
   no `poll_oneoff`. Gave the exact OS-shim recipe.
5. `6f46d1f` — **MVP:** restored pristine SBV 12.1 (deleted
   `WasmBridge`/`BrowserEngine`/`Z3Wasm`, removed every `#ifdef SBV_WASM`), added
   the out-of-tree `os-shim` package (`System.Process`/`System.Directory`), wired
   it via `sbv.cabal` arch(wasm32) + `cabal.project.wasm`, rebuilt `lib:sbv`+demo
   to wasm. Headless e2e passes: `sat (x*3==1 :: SWord8)` → x=171, `prove (x+1/=x)`
   → Q.E.D. Two `PipeFd` fixes found by testing: `fd_filestat_get` (char device)
   and `fd_prestat_get`→`BADF` (else wasi-libc preopen scan `_Exit(71)`).
6. `09efc96` — docs: rewrote `README.md`, added `DEMO.md` + headless-Chrome check
   (`test/run-browser-check.mjs` / `run-browser-check.sh`); dropped stale
   z3-solver glue. **Verified in a real browser.**
7. `00b6a56` — explored the 3 limitations (each node-verified; see below).

**Working tree state:** pristine SBV source; `os-shim/`; `web/src/*` runtime;
`web/main.js` broker; `wasm/Main.hs` demo; `web/solver/boolector.wasm`.

**Tests (all green):** `pipe-pingpong`, `solver-pipe`, `hs-probe/probe`, `e2e`,
`run-browser-check` (live page), `z3-pipe`, `poll`, `threads-spike/demo`.

## What we left undone

The three limitations were *explored and unit-proven* but **not yet wired into
the live SBV browser demo**:

- **Full theories (int/real/float) — highest priority (Grisette).**
  `web/src/z3-pipe-worker.js` runs the existing emscripten Z3 as a
  persistent-context pipe-process; `z3-pipe.test.mjs` proves Int/Real over the
  pipes; `main.js` routes exec name `z3` to it. **Left:** `MainFull.hs` +
  SBV-wasm rebuild targeting `z3`; add `z3-solver` to `package.json`; adapt the
  worker's reader from Node `worker_threads` to a browser nested Worker /
  `Atomics.waitAsync`. Then run `satWith z3` of an `SInteger` end-to-end.
- **Query timeouts.** `web/src/poll.js` implements `poll_oneoff` (clock + fd-read
  readiness); `pipefd.js` gained `bytesAvailable()`; `poll.test.mjs` green.
  **Left:** call `installPoll` in `sbv-worker.js` and thread SBV's query timeout
  into the response `PipeFd` deadline so a hung `check-sat` aborts.
- **Multi-threaded solver.** `web/threads-spike/` has a plan + a
  `wasi_thread_spawn` host shim + a shared-memory Atomics demo. **Caveat:** the
  demo proves the *mechanism* (JS Atomics on shared memory), not a real
  `wasi_thread_spawn` wasm. **Left:** build a `wasm32-wasi-threads` solver
  (Bitwuzla suggested first; ~2–4 days) — low priority since a single
  `check-sat` is single-threaded anyway.

**Also not done:** never pushed the branch; live demo is bit-vector only until
full theories are integrated; no Grisette query exercised yet.

## Recommended next step

Integrate full theories end-to-end (the browser-Worker reader adaptation + a
full-theory SBV rebuild), then drive a Grisette-generated query through it. That
is the unlock for Grisette interop.


---

## Milestone — full theories live in the browser (z3 from source)

z3 built **from source** as a single-threaded emscripten ES6 module
(`web/solver/z3.{js,wasm}`, `build-z3.sh`) and driven as a drop-in stdin/stdout
pipe-process via the new `web/src/emscripten-cli-worker.js` (blocking
`Module.stdin` over the SAB pipes — no nested reader worker; same code path in
Node and browser). `main.js` routes `z3` to it; `wasm/Main.hs` adds
`satWith z3` over `SInteger`/`SReal`/`SDouble` + a `proveWith`.

**Verified in real headless Chrome** (`run-browser-check.sh`): pristine SBV's
native engine solves `SInteger`=4, `SReal`=2.5, `SDouble`=2.5, `prove` Q.E.D.,
with Boolector bit-vectors still green. Node tests (`emscripten-cli`, `e2e`,
`pipe-pingpong`, `solver-pipe`) all green. A browser-only module-path bug (worker
resolved the solver URL relative to `src/`) was found and fixed during the
headless check — the Node test had masked it.

**Backlog:** cvc5 from source (`.kiro/specs/full-theory-browser-solvers/cvc5-blocker.md`)
— builds but its emscripten CLI throws on `callMain`; needs the corrected
`--wasm=JS` recipe. Not on the Grisette critical path.


---

## Milestone — incremental query mode works; timeout characterized

**#2 Incremental (query mode) — WORKS, verified.** `wasm/Main.hs` now runs a
`runSMTWith z3 $ query $ do { push; constrain; checkSat; getValue; pop; ... }`
exercising push/pop, repeated `check-sat`, and `get-value` over the z3 pipe.
Result `(3,7) then x=7 -> 7` confirmed in Node (`e2e`) and headless Chrome
(`run-browser-check`). This is the Grisette-relevant capability.

**#3 Timeouts — wired poll, but RTS-timeout traps.** `installPoll` (poll.js) is
now installed in both `sbv-worker.js` and the node harness (registers solver
read fds; `poll_oneoff` no longer throws "unimplemented"). However, SBV's
`setTimeOut` makes the response reader wrap `hGetLine` in
`System.Timeout.timeout`, which relies on the threaded RTS timer + async
exceptions; on the single-threaded wasm RTS during a blocking foreign read this
raises an **uncatchable `WebAssembly.Exception`** (crashes the worker). So
solver-side query timeouts are deferred (limitation B): the fix is to thread a
deadline into the `PipeFd` read (`deadlineMs`, already supported) so a hung
solver returns control to the RTS, instead of relying on `System.Timeout`.
Normal (non-timeout) solving is unaffected.

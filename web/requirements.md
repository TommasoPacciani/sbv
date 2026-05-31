# Requirements: SBV in the browser via a shimmed native solver process

## Intent

Run SBV in the browser by driving its **unmodified native solver engine**
(`runSolver` in `Data.SBV.SMT.SMT`) against an in-browser SMT solver compiled to
`wasm32-wasi`. SBV must stay as close to upstream as possible: the browser path
replaces only the *transport* (process spawn + pipes + a faked filesystem),
never the solver-coordination logic. The current bespoke `BrowserEngine.hs`,
which duplicates `runSolver`'s logic and forces capability deviations, is
retired.

Primary motivations:
- Eliminate the `z3-solver` O(n^2) script-replay (persistent process keeps state).
- Restore byte-identical native behavior, including `:global-declarations`.
- Make the solver backend swappable and long-term maintainable.

## Glossary
- **Shim**: browser/JS-side code emulating OS facilities (process, pipes, FS).
- **Solver process**: a `wasm32-wasi` SMT solver command (e.g. `z3 -in`).
- **SAB**: `SharedArrayBuffer` (requires COOP/COEP cross-origin isolation).

## R1 — SBV stays upstream-faithful
User story: As a maintainer, I want SBV's engine reused unmodified so upstream
updates merge cleanly.
1. The browser path SHALL execute SBV's native `runSolver` coordination
   (heartbeat, `sendAndGetSuccess`, paren-balanced response accumulation,
   query-state construction) without duplicating it.
2. SBV-side changes SHALL be limited to a single, well-isolated transport seam
   (import swap / mixin), with no edits to solver-coordination logic.
3. `BrowserEngine.hs` SHALL be removed once the native path is in place.
4. WHEN built natively THEN the seam SHALL resolve to the stock
   `System.Process`/`System.IO` implementations with no behavioral change.

## R2 — Process shim
User story: As SBV's engine, I want to spawn and manage a solver process.
1. The shim SHALL provide a `runInteractiveProcess`-equivalent returning
   (stdin, stdout, stderr) handles plus a process handle, backed by an
   in-browser solver instance.
2. The shim SHALL support `terminateProcess`, `waitForProcess`, and
   `getProcessExitCode` semantics sufficient for `runSolver`'s lifecycle/cleanup.
3. The solver process SHALL be **persistent** for the whole session: one process
   per solve, state preserved across commands (NO per-command re-evaluation).

## R3 — Pipe / stdio transport
User story: As SBV, I want normal blocking stdio over the solver's pipes.
1. stdin/stdout/stderr SHALL be exposed as WASI file descriptors usable as
   ordinary GHC `Handle`s, so `hPutStrLn`/`hFlush`/`hGetLine`/`hGetChar` work
   unchanged.
2. The transport SHALL support `hReady`-style non-blocking availability checks
   (used by `runSolver` to drain stdout/stderr on timeout).
3. WHEN SBV performs a blocking read with no data THEN the reading thread SHALL
   block (not busy-spin) until data arrives or timeout fires.

## R4 — Execution context for blocking I/O
User story: As the app, I need synchronous WASI stdio without freezing the UI.
1. The SBV wasm module SHALL run in a Web Worker (off the main thread) so
   synchronous blocking `fd_read` is permitted.
2. Solver<->SBV stdio SHALL be backed by an SAB pipe (blocking reads via
   `Atomics.wait`), with the solver running in the same or a sibling worker.
3. The page SHALL communicate with the SBV worker via `postMessage`; results
   returned asynchronously to the UI.

## R5 — Filesystem shim
User story: As the solver/SBV, I want the file operations they assume to work.
1. The shim SHALL provide a virtual filesystem sufficient for solver startup and
   for SBV transcript/dump features (temp paths, read/write of generated SMT2).
2. Filesystem state MAY be in-memory (non-persistent) unless persistence is
   later required; absence of persistence SHALL NOT break solving.

## R6 — Capability parity
User story: As a user, I want browser results identical to native.
1. The browser solver config SHALL advertise capabilities identical to native
   (in particular `supportsGlobalDecls = True`).
2. The SMT-LIB2 command stream, response parsing, and model extraction SHALL be
   byte-identical to the native path for non-incremental and incremental
   (`push`/`pop`, `allSat`) sessions.

## R7 — Solver-agnostic backend
User story: As a researcher, I want to swap solvers with minimal effort.
1. The transport SHALL be solver-neutral: any SMT-LIB2-over-stdio solver built
   to `wasm32-wasi` SHALL be usable by selecting an executable name + args, with
   no SBV coordination changes.
2. Z3 SHALL be the primary backend. cvc5, Bitwuzla, and Yices2 are accepted
   candidate secondaries (must speak SMT-LIB2 on stdin/stdout).

## R8 — Performance
User story: As a user, I want fast solving and startup.
1. Per-session solver work SHALL be O(commands), not O(commands^2).
2. Default builds MAY be single-threaded WASI; a single `check-sat` is
   single-threaded on native too, so this is acceptable.
3. Optional: a `wasi-threads`/WASIX multithreaded solver build MAY be provided to
   enable Z3 `parallel.enable` portfolio solving; this is an optimization, not a
   requirement.
4. The solver wasm module SHALL be compiled with `compileStreaming` and cached
   (Cache API / IndexedDB) to minimize cold-start cost.

## R9 — Timeouts
1. Query timeouts SHALL be honored on the browser path (via `System.Timeout` if
   functional under the wasm RTS, otherwise an equivalent timer-backed mechanism).
2. On timeout, the shim SHALL still permit draining residual stdout/stderr
   (R3.2) before reporting `SolverTimeout`.

## R10 — Build & packaging
1. A reproducible `wasi-sdk` build pipeline SHALL produce the solver `.wasm`
   (z3 first), checked or scripted into `web/`.
2. Cross-origin isolation headers (`COOP: same-origin`, `COEP: require-corp`)
   SHALL be served (required for SAB).

## R11 — Verification
1. A parity test SHALL compare the browser SMT-LIB2 stream and results against
   native for a representative suite (bit-vectors, integers, IEEE floats,
   push/pop, allSat).
2. CI or a documented manual procedure SHALL exercise the demo end-to-end.

## Known risks / open questions
- `System.Process` (`process` pkg) compiles for `wasm32-wasi` but its spawn is
  non-functional at runtime (no `posix_spawn`/WASI proc API, WASI #414); the seam
  must therefore replace runtime behavior, not just rely on the stock package.
- `System.Timeout` behavior under the single-threaded wasm RTS needs validation
  (R9.1 fallback).
- GHC targets wasi-libc, not Wasmer WASIX; WASIX's native `proc_spawn`/fork is
  not directly usable from GHC output, so the process model is emulated in the
  worker host rather than via WASIX syscalls.
- Single-threaded default forgoes Z3 `parallel.enable` (R8.3).

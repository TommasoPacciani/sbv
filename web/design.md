# Design: SBV in the browser via a shimmed native solver process

## 0. North star (maintainability)

Keep the **SBV source tree pristine upstream**. Today the browser build edits
`SMT.hs`, `Utils.hs`, `Prover.hs`, `sbv.cabal` with `#ifndef SBV_WASM` and adds
`WasmBridge`/`BrowserEngine`/`Z3Wasm` (which *duplicates* `runSolver`). That is
the drift liability.

New rule: **zero edits to SBV.** Everything wasm-specific lives in three places
outside SBV's modules:

1. A separate Haskell **OS-shim package** (`sbv-wasm-os`) that provides the
   `System.Process` / `System.Directory` / `System.Environment` symbols SBV's
   *native* path imports. It is wired in with Cabal `mixins:` so upstream
   `import System.Process` resolves to the shim with no source change.
2. A **JS host** (browser_wasi_shim + SharedArrayBuffer pipes + workers).
3. `cabal.project.wasm` (toolchain + mixins). No `-DSBV_WASM`.

Bumping SBV then = change a version pin + rebuild. A parity test guards drift.

Net effect on SBV: `defaultSMTCfg = z3` (the **native** Z3 config, `executable
= "z3"`) is reused unchanged; `findExecutable "z3"` succeeds in the shim;
`runInteractiveProcess` spawns the wasm solver. `runSolver` runs verbatim.

## 1. Solver selection

Backends must (a) speak SMT-LIB2 on stdin/stdout and (b) build to `wasm32-wasi`.
Under the process shim, adding one is just an executable name — no SBV change.

| Solver | Role | Why | Notes |
|---|---|---|---|
| **Z3** | primary | matches current default; widest theories (BV, int/real, FP, arrays, quantifiers, strings) | wasi-sdk build of the CLI (`z3 -in`) |
| **Bitwuzla** | secondary | very fast BV/FP/arrays/UF; modern | C++ / CMake; supersedes Boolector |
| **cvc5** | optional | strings, quantifiers, broad SMT-LIB2 | larger; add if needed |
| **Yices2** | optional | small, fast, C; cheap to ship | `yices-smt2` SMT-LIB2 mode |

Boolector already has a public wasm build (`yowasp-boolector`) — proof the model
works — but it is archived; prefer **Bitwuzla**. **Ship Z3 first**, structure the
build so Bitwuzla/cvc5/Yices2 drop in. All run single-threaded by default
(fine: a single `check-sat` is single-threaded on native too; portfolio
`parallel.enable` is an opt-in later optimization via a wasi-threads build).

## 2. The OS surface SBV's native path touches — and how each is solved

Enumerated from `runSolver` (`SMT.hs`), `Utils.hs`, `Prover.hs`:

### A. Process spawn — `runInteractiveProcess execPath opts _ _`
Need `(inh, outh, errh, ProcessHandle)`.
Solution: shim allocates 3 SAB pipes (cmd, resp, err), ensures a **solver Web
Worker** is running bound to those pipes, and returns three real GHC `Handle`s
built from WASI fds via `fdToHandle`, plus a `ProcessHandle` referencing the
worker. Persistent process ⇒ no replay, state preserved like native.

### B. Process lifecycle — `waitForProcess`, `terminateProcess`
Solution: `terminateProcess` posts terminate/reset to the solver worker;
`waitForProcess` blocks on an exit word in a control SAB (set when the solver
hits `(exit)` / returns from `_start`). Returns `ExitSuccess`.

### C. Pipe byte I/O — `hPutStrLn`, `hFlush`, `hGetLine`, `hGetChar`, `hGetContents`, `hClose`
Solution: the returned handles are ordinary GHC `Handle`s over WASI fds; a
custom browser_wasi_shim `Fd` (`PipeFd`) backs `fd_read`/`fd_write` with a SAB
ring buffer. No change to `base`/`System.IO`.

### D. Blocking read + timeout — `hGetLine` blocks; `System.Timeout` cannot interrupt a synchronous foreign read
Solution: enforce the deadline **inside** `PipeFd.fd_read` via
`Atomics.wait(view, i, expected, timeoutMs)`. On deadline return 0 bytes
(EOF-like) so the Haskell read returns and SBV's existing
timeout/`grab outh/errh` path runs. `System.Timeout` is left as the outer guard
only. (This is why blocking lives in the pipe, not the RTS.)

### E. Non-blocking poll — `hReady` (→ `hWaitForInput 0` → `poll_oneoff`)
Solution: `PipeFd` exposes a fill-level check; implement `poll_oneoff` to report
readiness without blocking.

### F. Executable discovery — `findExecutable "z3"`, `getEnv "SBV_Z3"`
Solution: shim `System.Directory.findExecutable nm` returns `Just ("/bin/"++nm)`
for known solver names (so the native Z3 config resolves); shim
`System.Environment.getEnv` reads WASI `environ` or throws `DoesNotExist`, so SBV
falls back to defaults.

### G. Working directory — `getCurrentDirectory`
Solution: shim returns `"/"`.

### H. Transcript / file output — `transcript = Just path` ⇒ `openFile`/`hPutStr`
Solution: browser_wasi_shim in-memory FS (`Directory`/`File`) mounted writable;
real WASI `path_open`/`fd_write`. Optionally surface written files as downloads.
Default config writes nothing, so this is opt-in.

### I. Clock / time — `getCurrentTime`, `getZonedTime`, timing
Solution: WASI `clock_time_get` (browser_wasi_shim, already works).

### J. Randomness — temp names, `random`
Solution: WASI `random_get` (browser_wasi_shim, already works).

### K. Reactor program stdio — `putStr report`
Solution: `ConsoleStdout` routing to the page (already in `loader.mjs`).

### L. Concurrency — green-thread `forkIO` (draining)
Solution: reads are deadline-bounded and the two ends live in separate workers,
so no preemptive cross-thread drain is needed; GHC wasm green threads suffice.
(Risk R-3 below.)

## 3. Tools used for the OS layer (summary)

| Concern | Tool / project |
|---|---|
| WASI syscalls, virtual FS, custom fds, poll | **@bjorn3/browser_wasi_shim** (already a dep) |
| Blocking pipes across threads + deadlines | **SharedArrayBuffer + Atomics** |
| Process model / off-main-thread blocking | **Web Workers** (optionally **Comlink** for ergonomics) |
| Build solvers to wasm | **wasi-sdk** (clang + libc++) |
| Compile SBV (pristine) | **GHC wasm backend** via **ghc-wasm-meta** |
| `System.Process/Directory/Environment` shim | small Haskell pkg **`sbv-wasm-os`** + Cabal **`mixins:`** |
| Static host headers (COOP/COEP) | **Vite** (or any host) |

Alternative all-in-one (if we prefer not to hand-roll the broker): **@wasmer/sdk**
provides spawn + virtual FS + non-blocking stdio + threads in one package; it
would replace tools rows 1–3. Heavier dep; keep as fallback.

## 4. Topology

```
main thread (page) ── broker: spawns workers, allocates SABs, COOP/COEP
   │ postMessage (results)
Worker A: sbv-wasm        Worker B: z3-wasi (z3 -in)
  WASI=browser_wasi_shim    WASI=browser_wasi_shim
  inh  ─cmd  SAB──────────▶ fd0 (stdin,  blocking read)
  outh ◀─resp SAB────────── fd1 (stdout, flush per cmd)
  errh ◀─err  SAB────────── fd2 (stderr)
```

SBV writes a command to `inh`+flush → solver (blocked on fd0) wakes, solves,
writes fd1+flush → SBV (blocked on `outh`) wakes. Strictly ping-pong; matches the
native pipe protocol byte-for-byte.

## 5. Prototype sketch (minimal)

### `web/src/sabpipe.js` — one-directional byte pipe over a SAB
```js
// Layout: [0]=write index, [1]=read index, [2..]=ring bytes. Atomics on int32 view.
const HDR = 2, CAP = 1 << 16;
export function makePipe() { return new SharedArrayBuffer(4 * (HDR + CAP)); }

export class Pipe {
  constructor(sab) { this.i32 = new Int32Array(sab); this.cap = CAP; }
  write(bytes) {                              // producer (+ wake reader)
    const a = this.i32; let w = Atomics.load(a, 0);
    for (const b of bytes) { a[HDR + (w % this.cap)] = b; w++; }
    Atomics.store(a, 0, w); Atomics.notify(a, 0);
  }
  // Blocking read up to max bytes; returns [] on deadline (EOF-like).
  read(max, deadlineMs) {
    const a = this.i32, out = [];
    while (out.length < max) {
      let w = Atomics.load(a, 0), r = Atomics.load(a, 1);
      if (r === w) {                          // empty: block on producer
        if (out.length) break;                // deliver what we have
        if (Atomics.wait(a, 0, w, deadlineMs ?? Infinity) === 'timed-out') return out;
        continue;
      }
      out.push(a[HDR + (r % this.cap)] & 0xff); Atomics.store(a, 1, r + 1);
    }
    return out;
  }
  available() { return Atomics.load(this.i32, 0) - Atomics.load(this.i32, 1); }
}
```

### `web/src/pipefd.js` — browser_wasi_shim Fd over a Pipe
```js
import { Fd } from '@bjorn3/browser_wasi_shim';
export class PipeFd extends Fd {
  constructor(pipe, deadlineMs) { super(); this.p = pipe; this.deadline = deadlineMs; }
  fd_read(size) {                              // blocking; honors deadline (R-D)
    const bytes = this.p.read(size, this.deadline);
    return { ret: 0, data: new Uint8Array(bytes) };
  }
  fd_write(data) { this.p.write(data); return { ret: 0, nwritten: data.byteLength }; }
  // poll readiness for hReady (R-E)
  fd_pread() { return { ret: 0, data: new Uint8Array(0) }; }
}
```

### `os-shim/System/Process.hs` — the only thing SBV "sees" (mixed in)
```haskell
module System.Process (runInteractiveProcess, waitForProcess, terminateProcess, ProcessHandle) where
import GHC.IO.Handle.FD (fdToHandle)
import System.IO (Handle); import System.Exit (ExitCode(..)); import System.Posix.Types (Fd(..))

newtype ProcessHandle = PH Int
-- JS host pre-registers the solver's pipe fds and returns their numbers + a worker id.
foreign import javascript unsafe "spawnSolver($1)"
  js_spawn :: JSString -> IO Int     -- returns base fd; in=base, out=base+1, err=base+2

runInteractiveProcess :: FilePath -> [String] -> Maybe a -> Maybe b
                      -> IO (Handle, Handle, Handle, ProcessHandle)
runInteractiveProcess exe _opts _ _ = do
  base <- js_spawn (toJSString exe)
  inh  <- fdToHandle (Fd (fromIntegral base))
  outh <- fdToHandle (Fd (fromIntegral (base+1)))
  errh <- fdToHandle (Fd (fromIntegral (base+2)))
  pure (inh, outh, errh, PH base)

waitForProcess   _ = pure ExitSuccess
terminateProcess (PH b) = js_terminate b
foreign import javascript unsafe "terminateSolver($1)" js_terminate :: Int -> IO ()
```
(`System/Directory.hs` and `System/Environment.hs` shims are ~10 lines each:
`findExecutable` → `Just ("/bin/"++nm)`, `getCurrentDirectory` → `"/"`,
`getEnv` → WASI environ or throw.)

### `cabal.project.wasm` — wire the shim in, no SBV edits
```
packages: . os-shim/
package sbv
  -- remap the OS modules to the shim; SBV's source imports are unchanged
  mixins: sbv-wasm-os (System.Process, System.Directory, System.Environment)
```

### Worker wiring (`solver-worker.js`, sketch)
Instantiate `z3.wasm` with `new WASI([...], [], [stdinPipeFd, stdoutPipeFd,
stderrPipeFd])` where the three `PipeFd`s wrap the shared SABs handed in via the
spawn message, then call `wasi.start(instance)`. The broker on the main thread
owns SAB allocation and answers `spawnSolver`.

## 6. Phased plan

1. Build `z3` to `wasm32-wasi` (wasi-sdk); verify `z3 -in` reads SMT-LIB2 from a
   file via the shim FS (no SBV yet).
2. Land `sabpipe.js` + `pipefd.js`; unit-test ping-pong between two workers.
3. Land `sbv-wasm-os`; compile **pristine** SBV with `cabal.project.wasm` mixins
   (drop `-DSBV_WASM`; delete `WasmBridge`/`BrowserEngine`/`Z3Wasm`).
4. Run `sat`/`prove` end-to-end through native `runSolver`; restore
   `supportsGlobalDecls = True` (automatic — native config reused).
5. Parity test vs native SMT-LIB2 transcript (R11). Add Bitwuzla as 2nd backend
   by name only.

## 7. Risks / open questions
- **R-1 stdout buffering:** wasi-libc may buffer the solver's stdout when not a
  tty → SBV hangs. Mitigate: `z3 -in` (interactive, flushes) and/or build with
  unbuffered stdout.
- **R-2 poll_oneoff/`hReady`:** confirm GHC wasm `hReady` routes to a path
  `PipeFd` can satisfy; else expose an explicit readiness fd.
- **R-3 forkIO draining:** confirm native `runSolver` needs no preemptive
  stderr-drain thread under the single-threaded wasm RTS.
- **R-4 nested workers:** if Worker A can't spawn Worker B, broker on main
  thread (pre-spawn solver at init) instead.
- **R-5 mixins reach:** confirm Cabal `mixins:` cleanly shadows `process` /
  `directory`; fallback is a one-line CPP import swap in `SMT.hs`.
- **R-6 System.Timeout:** won't interrupt a blocked syscall; deadlines are
  enforced at the pipe (R-D). Validate the outer `timeout` still behaves.

## 8. Update — what the prototype actually built

- **Solver:** rather than building z3 (which required *editing z3 sources* for
  wasi-libc gaps — a fork we explicitly reject), the MVP uses a **maintained
  prebuilt `wasm32-wasi` Boolector** (YoWASP). Selected by exec name, so z3/cvc5/
  Bitwuzla remain drop-ins. Demo theories are therefore bit-vector only.
- **Engine mode:** SBV runs as a **WASI command** (`_start`→`main`), not a
  reactor — the whole solver interaction is synchronous over blocking pipes, so
  the async/Promise reactor model and `hs_init` export are unnecessary.
- **Realised seam:** `os-shim` provides `System.Process`+`System.Directory`;
  `runInteractiveProcess` uses `fdToHandle'` (Stream + explicit `WriteMode`/
  `ReadMode`). Two `PipeFd` details were required: `fd_filestat_get` (char device,
  for GHC `fdType`) and `fd_prestat_get`→`BADF` (else wasi-libc's preopen scan
  `_Exit`s with `EX_OSERR`=71). See `DEMO.md` for run/verify.

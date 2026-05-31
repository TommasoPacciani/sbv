# Multi-threaded Wasm Solver in the Browser — Technical Plan

## Problem

The current solver worker (`solver-worker.js`) instantiates a single-threaded
`wasm32-wasi` module via `browser_wasi_shim`. Solvers like Z3 with
`parallel.enable` spawn pthreads internally. The browser *can* run threaded wasm
(shared memory + Web Workers + Atomics), but `browser_wasi_shim` does not
implement `wasi_thread_spawn`. This plan covers what's needed.

---

## (a) The wasi-threads ABI

The **wasi-threads** proposal (phase 2, merged into wasi-sdk ≥ 20) defines one
host import:

```wat
(import "wasi" "thread-spawn" (func $wasi_thread_spawn (param i32) (result i32)))
```

**Parameters:**
- `start_arg` (i32): opaque value passed to the new thread (typically a pointer
  into shared linear memory containing the thread's stack pointer + start routine).

**Return:** positive `tid` on success, negative errno on failure.

**What the host must do on each call:**

1. Allocate a fresh `tid` (monotonically increasing integer > 0).
2. Spawn a new execution context (Web Worker in browser, `worker_threads` in Node).
3. In that context, **re-instantiate the same `WebAssembly.Module`** with:
   - The **same shared `WebAssembly.Memory`** (the module's memory must be
     `shared` with a declared `maximum`).
   - The same WASI import object (or a minimal one — the child only needs
     memory-related imports; fd ops are typically main-thread only).
4. Call the module's **`wasi_thread_start`** export:
   ```wat
   (export "wasi_thread_start" (func (param $tid i32) (param $start_arg i32)))
   ```
5. When `wasi_thread_start` returns, the thread is done (Worker can terminate).

**Key invariants:**
- The module's linear memory is `(memory 1 N shared)` — created by the host with
  `new WebAssembly.Memory({initial, maximum, shared: true})`.
- All threads share the same memory; synchronization is via `Atomics` /
  `memory.atomic.*` wasm instructions.
- The host does NOT need to implement `pthread_create` — wasi-libc's pthread
  layer calls `wasi_thread_spawn` which the host provides.

---

## (b) Building a solver with wasm32-wasi-threads

wasi-sdk ≥ 20 ships a `wasm32-wasi-threads` target (sysroot with `-pthread`
support, `__wasi_thread_spawn` import).

```sh
# Example: build Z3 with threads
cmake -G Ninja -B build \
  -DCMAKE_C_COMPILER=wasm32-wasi-threads-clang \
  -DCMAKE_CXX_COMPILER=wasm32-wasi-threads-clang++ \
  -DCMAKE_C_FLAGS="-pthread" \
  -DCMAKE_CXX_FLAGS="-pthread" \
  -DCMAKE_EXE_LINKER_FLAGS="-pthread -Wl,--shared-memory,--max-memory=1073741824" \
  -DZ3_BUILD_LIBZ3_SHARED=OFF \
  -DZ3_SINGLE_THREADED=OFF \
  ...
ninja -C build
```

The resulting `.wasm` will:
- Have `(memory (;0;) 256 16384 shared)` (shared + maximum).
- Import `(import "wasi" "thread-spawn" ...)`.
- Export `wasi_thread_start`.

**Practical note:** Z3's build system needs minor patches for wasi-libc gaps
(no `fenv.h` rounding-mode macros, no `sigaction`). These are stub-able.

---

## (c) Alternative: @wasmer/sdk WASIX runtime

[Wasmer's JS SDK](https://github.com/aspect-build/aspect-workflows) provides a
**WASIX** runtime that already implements `wasi_thread_spawn` in the browser:

```js
import { init, WASI } from '@aspect-build/aspect-workflows'; // or @wasmer/sdk
await init();
const wasi = new WASI({ args: ['z3', '--smt2'], env: {} });
const instance = await wasi.instantiate(module, { /* extra imports */ });
wasi.start(instance); // threads spawn automatically
```

**Pros:** No custom thread-spawn code; handles stack allocation, TLS.
**Cons:** Large runtime (~2 MB), WASIX is a superset of WASI (non-standard
extensions), lock-in to Wasmer's toolchain, and the solver must be compiled
with Wasmer's `wasix-sdk` (or at minimum link against their libc).

For this project, a **minimal custom host** (option a) is preferable — it keeps
the architecture transparent and avoids a heavy dependency.

---

## (d) Constraints

| Constraint | Detail |
|---|---|
| Shared Memory | `new WebAssembly.Memory({initial, maximum, shared: true})` — `maximum` is **required** for shared memories. |
| COOP/COEP | `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` — **already set** in `vite.config.js`. Without these, `SharedArrayBuffer` is undefined. |
| `Atomics.wait` on main thread | **Illegal** in browsers (throws `TypeError`). All blocking waits must happen in Workers. The solver and its child threads all run in Workers, so this is fine. The broker/main thread must use `Atomics.waitAsync` or message-passing. |
| Module compilation | `WebAssembly.Module` is transferable via `postMessage`. Compile once on main thread, transfer to all child Workers — avoids redundant compilation. |
| Stack allocation | Each spawned thread needs its own stack region. wasi-libc's pthread layer allocates stack space from the shared linear memory before calling `wasi_thread_spawn`; the host just needs to call `wasi_thread_start` with the provided `start_arg`. |

---

## Integration with this project

The change is **isolated to `solver-worker.js`**:

1. When loading a threads-enabled solver, create `WebAssembly.Memory` with
   `{shared: true, maximum}` and pass it as the module's memory import.
2. Add `wasi.thread-spawn` to the import object, backed by the shim in
   `thread-spawn.mjs`.
3. Each spawned child is a new Worker running a small bootstrap that
   re-instantiates the module on the shared memory and calls `wasi_thread_start`.

The SAB pipes (`sabpipe.js`) are unaffected — they connect the *solver process*
(which may now be multi-threaded internally) to SBV. From SBV's perspective,
nothing changes.

---

## Effort estimate

| Task | Effort | Risk |
|---|---|---|
| Build Z3 with `wasm32-wasi-threads` | 2–4 days | Medium (wasi-libc gaps, Z3 build system) |
| Implement `wasi_thread_spawn` host | 1 day | Low (see `thread-spawn.mjs` in this spike) |
| Wire into `solver-worker.js` | 0.5 day | Low |
| Test with real threaded solver | 1–2 days | Medium (stack size tuning, deadlocks) |
| **Total** | **~1 week** | Dominated by the Z3 cross-compile |

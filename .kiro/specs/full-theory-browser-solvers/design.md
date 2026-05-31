# Design — full-theory solvers from source

## Key insight
The current `z3-pipe-worker.js` needs a nested reader sub-worker only because the
prebuilt emscripten z3 is **pthread-enabled** (its `eval_smtlib2_string`
dispatches to a worker, so the host thread cannot block). If we build the
solvers **single-threaded** from source, the worker can block directly on the
SAB cmd pipe via `Atomics.wait` — exactly like `solver-worker.js` does for the
WASI Boolector. So both solvers become true stdin/stdout pipe processes and the
browser path equals the Node path. This is the whole point of building from
source.

## Architecture (unchanged contract)
```
sbv-worker (pristine SBV)  --spawnSolver(exe,args)-->  broker (main.js)
   exe=boolector  -> solver-worker.js        (WASI command, blocks on pipe)
   exe=z3 | cvc5  -> emscripten-cli-worker.js (emscripten command, blocks on pipe)
                         stdin  <- cmd  SAB pipe (Atomics.wait)
                         stdout -> resp SAB pipe
                         stderr -> err  SAB pipe
```

## Build approach (per solver; pinned emsdk, single-threaded)
Common: shallow clone at a pinned tag; activate a pinned emsdk; build an ES6
`MODULARIZE`d module that runs the solver binary as an SMT2-from-stdin CLI;
copy `*.js`/`*.wasm` to `web/solver/`; delete the build tree. Build scratch in
`$HOME/sbvw-build/` (single disk ~12 G free → strictly sequential, clean up
between solvers; `--auto-download` deps for cvc5).

- **z3** (`Z3Prover/z3`, e.g. tag `z3-4.13.4`):
  ```
  emcmake cmake -B build -S z3 -DCMAKE_BUILD_TYPE=Release \
    -DZ3_SINGLE_THREADED=ON -DZ3_BUILD_LIBZ3_SHARED=OFF -DZ3_BUILD_EXECUTABLE=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-sMODULARIZE=1 -sEXPORT_ES6=1 -sALLOW_MEMORY_GROWTH=1 \
      -sEXIT_RUNTIME=1 -sINVOKE_RUN=0 -sEXPORTED_RUNTIME_METHODS=callMain"
  cmake --build build -j$(nproc) --target z3
  ```
  Run args: `['-smt2','-in']`. Reference (do not copy pthreads): the
  `z3-solver` npm `scripts/build-wasm.ts` already in `web/node_modules`.
- **cvc5** (`cvc5/cvc5`, recent tag): use its supported wasm path
  ```
  ./configure.sh production --static --auto-download --wasm=WASM \
    --wasm-flags="-sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORTED_RUNTIME_METHODS=callMain" \
    --name=build-wasm
  cd build-wasm && make -j$(nproc) cvc5
  ```
  Ensure **no** `-pthread`/`-sUSE_PTHREADS`. Run args: `['--lang','smt2','--incremental','-']`.
  Needs a pinned emsdk (system emcc 3.1.6 is too old for current cvc5); read
  cvc5 `INSTALL.rst` / `configure.sh` for the exact required version.

## New runtime piece — `web/src/emscripten-cli-worker.js`
Solver-agnostic. Receives `{ moduleUrl, args, cmdSab, respSab, errSab }`.
```
import { Pipe } from './sabpipe.js';
const enc = new TextEncoder();
export async function runCli({ moduleUrl, args, cmdSab, respSab, errSab }) {
  const cmd = new Pipe(cmdSab), resp = new Pipe(respSab), err = new Pipe(errSab);
  let buf = new Uint8Array(0), pos = 0;
  const stdin = () => {                         // blocking byte source (Atomics.wait)
    if (pos >= buf.length) { buf = cmd.readBytes(4096); pos = 0; if (!buf.length) return null; }
    return buf[pos++];
  };
  const Module = { noInitialRun: true, stdin,
    print:    s => resp.writeBytes(enc.encode(s + '\n')),
    printErr: s => err.writeBytes(enc.encode(s + '\n')) };
  const factory = (await import(moduleUrl)).default;   // ES6 emscripten module
  const inst = await factory(Module);
  inst.callMain(args);                          // blocks until SBV sends (exit)/EOF
  resp.close(); err.close();
}
// Node (worker_threads) and browser (Web Worker) entry: read sabs from the
// message/workerData, call runCli. Same file, both paths.
```
This replaces the special-cased `z3-pipe-worker.js` for the from-source builds.

## Integration points
- `main.js`: `emscriptenSolvers = {z3:'./solver/z3.js', cvc5:'./solver/cvc5.js'}`,
  args map; route those exe names to `emscripten-cli-worker.js`, everything else
  to `solver-worker.js`.
- `wasm/Main.hs`: keep the Boolector bit-vector queries; add
  `satWith z3`/`satWith cvc5` over `SInteger` (x*3==12 → 4), `SReal` (r*2==5 → 5/2),
  `SDouble`; one `proveWith`. Rebuild `sbv-wasm-demo.wasm` (documented cabal-wasm
  command), re-run post-link.
- `web/package.json`: drop the unused emscripten-pthread `z3-solver` dep once the
  from-source z3 lands; bump test script.

## Tests
- `web/test/emscripten-cli.test.mjs`: drive z3 then cvc5 through the worker over
  real pipes; assert `sat`, `x=4`, `r=5/2` (mirrors `z3-pipe.test.mjs`).
- Reuse `e2e.test.mjs` shape for an SBV→z3 `SInteger` end-to-end (Node).
- `run-browser-check.sh` for the live page.

## Disk / failure strategy
Sequential builds, `rm -rf` scratch between them, keep only `web/solver/*.{js,wasm}`.
If a build cannot complete (disk/version), it SHALL stop with a clear message and
leave the prior solver + MVP intact; integration of the other solver proceeds.

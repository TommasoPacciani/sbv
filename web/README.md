# Running SBV in the browser — native engine over a faked OS

This directory runs **pristine SBV** in the browser. SBV's *unmodified native
solver engine* spawns an SMT solver "process" and talks SMT-LIB2 to it over OS
pipes — exactly as it does on a desktop. The twist: there is no OS. A small
**out-of-tree shim** fakes `System.Process`/`System.Directory`, and the solver
is a prebuilt **`wasm32-wasi` Boolector** running in a second Web Worker, wired
to SBV over `SharedArrayBuffer` pipes.

The point of the prototype: **SBV stays byte-for-byte upstream.** All
browser-specific code lives in three out-of-tree places — a Haskell shim
package, some JS, and a small `cabal` stanza — so bumping SBV is a re-build, not
a re-patch.

## Architecture

```
 Web Worker A: sbv-wasm-demo.wasm            Web Worker B: boolector.wasm
   (pristine SBV, native engine)               (prebuilt wasm32-wasi, YoWASP)
   System.Process.runInteractiveProcess  ─┐
     => os-shim: js_spawnSolver           │   args: boolector --smt2 -m
   hPutStrLn/hGetLine over fdToHandle'    │         --output-format=smt2
            │  ▲                          │         --no-exit-codes --incremental
        cmd │  │ resp/err                 │
            ▼  │                          ▼
   PipeFd (browser_wasi_shim Fd)     PipeFd  ── stdin/stdout/stderr
            │  ▲                          │  ▲
            └──┴──── SharedArrayBuffer ring buffers (Atomics.wait) ──┴──┘
                         (broker on the main thread starts Worker B)
```

| File | Role |
|---|---|
| `../wasm/Main.hs` | Command-mode demo: `satWith`/`proveWith boolector` (bit-vectors). |
| `../os-shim/` | `sbv-wasm-os`: out-of-tree `System.Process`/`System.Directory`. |
| `src/sabpipe.js` | One-directional `SharedArrayBuffer` byte pipe; blocking via `Atomics`. |
| `src/pipefd.js` | A `browser_wasi_shim` `Fd` backed by a pipe. |
| `src/solver-worker.js` | Runs a `wasm32-wasi` solver with stdio on the pipes. |
| `src/sbv-worker.js` | Runs SBV; provides `spawnSolver`/`terminateSolver` host fns. |
| `main.js`, `index.html` | Page + broker (starts solver workers on demand). |
| `solver/boolector.wasm` | Prebuilt solver (see `solver/fetch-solver.sh`). |

## Build

One-time prerequisites: the `wasm32-wasi` GHC 9.15 (ghcup) and its wasi-sdk at
`~/.ghc-wasm/wasi-sdk`, plus a host `happy` (`cabal install happy`).

```sh
# 1. solver (prebuilt; no compile)
web/solver/fetch-solver.sh                  # -> web/solver/boolector.wasm

# 2. SBV + demo to wasm (builds lib:sbv + the os-shim + the demo)
PATH="$HOME/.local/bin:$PATH" cabal --project-file=cabal.project.wasm \
  --with-compiler=$HOME/.ghcup/bin/wasm32-wasi-ghc-9.15 \
  --with-hc-pkg=$HOME/.ghcup/bin/wasm32-wasi-ghc-pkg-9.15 \
  --with-hsc2hs=$HOME/.ghcup/bin/wasm32-wasi-hsc2hs-9.15 \
  --with-happy=$HOME/.local/bin/happy --builddir=dist-wasm \
  build exe:sbv-wasm-demo
cp "$(find dist-wasm -path '*sbv-12.1*sbv-wasm-demo.wasm' | head -1)" web/sbv-wasm-demo.wasm

# 3. JSFFI glue (post-link emits the spawnSolver/terminateSolver import object)
cd web && node "$(wasm32-wasi-ghc-9.15 --print-libdir)/post-link.mjs" \
  -i sbv-wasm-demo.wasm -o sbv-wasm-demo.js
```

## Run

```sh
cd web && npm run serve          # vite on http://localhost:8080 (sends COOP/COEP)
```
Open <http://localhost:8080>. `SharedArrayBuffer` requires the
`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy:
require-corp` headers (vite sends them; any static host must too).

## Tests (Node — the exact browser code path)

```sh
node web/test/pipe-pingpong.test.mjs    # blocking cross-thread SAB pipe
node web/test/solver-pipe.test.mjs      # real boolector.wasm over the pipes
node web/hs-probe/probe.test.mjs        # GHC-wasm Handle I/O over a PipeFd
node web/test/e2e.test.mjs              # full: SBV native engine -> Boolector
bash web/test/run-browser-check.sh      # the real page in headless Chrome
```
Node stands in for the browser with three thin swaps: `worker_threads`↔Web
Worker, `fs`↔`fetch`, `parentPort`↔`postMessage`.

## Scope / limitations

- **Theory coverage:** Boolector is bit-vectors/arrays only — the live demo uses
  `SWord8`. Unbounded integers / reals / IEEE floats need a richer solver.
  Because the solver is just an executable name, a `wasm32-wasi` cvc5/Bitwuzla
  (or an emscripten-z3 wrapped as a pipe-process) drops in with **no SBV change**.
- **Single-threaded** solver (fine: a single `check-sat` is single-threaded on
  native too). `parallel.enable` portfolios would need a threaded build.
- **No query timeouts** in the prototype: `browser_wasi_shim` throws on
  `poll_oneoff`, which SBV only uses on the timeout path. The pipe supports a
  deadline (`Atomics.wait` timeout) when we want to wire it in.

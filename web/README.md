# Running SBV in the browser

This directory contains everything needed to run **SBV itself, compiled to
WebAssembly**, driving the official Microsoft **Z3 WebAssembly** build
(`z3-solver`) entirely inside a web browser — no operating-system process, no
server-side solver.

The pieces:

| File | Role |
|---|---|
| `../wasm/Main.hs` | GHC-wasm reactor entry point; exports `sbvRunDemos` to JS. |
| `sbvZ3Wasm.js` | Glue from SBV's `WasmBridge` JSFFI imports to `z3-solver` (`Z3.eval_smtlib2_string`). |
| `loader.mjs` | Instantiates the wasm with WASI + the JSFFI import object and runs the demo. |
| `index.html` | The page. |
| `package.json` / `vite.config.js` | JS deps (`z3-solver`, WASI shim) and a dev server with the required COOP/COEP headers. |

## 1. Build SBV + the demo for wasm

Prerequisites (one-time): the `wasm32-wasi` GHC 9.15 (ghcup) **and** its wasi-sdk
at `~/.ghc-wasm/wasi-sdk` (provides `wasm32-wasi-clang`; ghc-wasm-meta's setup
installs it), plus a host-runnable `happy`
(`cabal install happy --installdir ~/.local/bin`).

From the repository root, build the demo (this also builds `lib:sbv`). The
`cabal.project.wasm` project file adds the head.hackage overlay and the
nightly boot-package constraints, sets `-DSBV_WASM` via the cabal
`if arch(wasm32)` stanza, enables shared libs (needed for Template Haskell on
wasm), and keeps `libBF` (compiled from its bundled C):

```sh
PATH="$HOME/.local/bin:$PATH" cabal --project-file=cabal.project.wasm \
  --with-compiler=$HOME/.ghcup/bin/wasm32-wasi-ghc-9.15 \
  --with-hc-pkg=$HOME/.ghcup/bin/wasm32-wasi-ghc-pkg-9.15 \
  --with-hsc2hs=$HOME/.ghcup/bin/wasm32-wasi-hsc2hs-9.15 \
  --with-happy=$HOME/.local/bin/happy \
  --builddir=dist-wasm \
  build exe:sbv-wasm-demo -f-compile_examples
```

Copy the produced artifact into `web/`:

```sh
cp "$(find dist-wasm -name sbv-wasm-demo.wasm | head -1)" web/sbv-wasm-demo.wasm
```

## 2. Generate the JSFFI glue (post-link)

GHC emits a `ghc_wasm_jsffi` custom section; the post-linker turns it into an
ESM module that produces the import object:

```sh
cd web
node "$(wasm32-wasi-ghc-9.15 --print-libdir)/post-link.mjs" \
  -i sbv-wasm-demo.wasm -o sbv-wasm-demo.js
```

(That is also the `npm run postlink` script.)

## 3. Install JS deps and serve

```sh
cd web
npm install
npm run serve     # vite on http://localhost:8080 with COOP/COEP headers
```

Open <http://localhost:8080>. The page will load Z3, then print the results of
running `sat`/`prove` over bit-vectors, unbounded integers, and IEEE floats —
all solved in the browser.

> The cross-origin-isolation headers (`Cross-Origin-Opener-Policy: same-origin`
> and `Cross-Origin-Embedder-Policy: require-corp`) are required because
> `z3-solver` uses `SharedArrayBuffer`. Any static host must send them.

## Known difference from native: `:global-declarations`

**Problem.** Native SBV talks to a fresh `z3` *process* and, as its first
commands, sends `(set-option :print-success true)` then
`(set-option :global-declarations true)`. The browser path instead drives a
single **persistent Z3 context** through `Z3_eval_smtlib2_string` (that call is
what preserves solver state across commands). On that persistent context, Z3
rejects `:global-declarations` once the context has been initialized:

```
(error "line 1 column 67: error setting ':global-decls',
        option value cannot be modified after initialization")
```

i.e. the option is only settable on a brand-new context, before any other
command — which the fresh native process satisfies but the reused browser
context does not.

**Decision.** `z3Wasm` advertises `supportsGlobalDecls = False`
(`Data/SBV/Provers/Z3Wasm.hs`). SBV honors that capability and simply never
emits `(set-option :global-declarations true)` on the browser path. We did **not**
patch the SMT-LIB2 stream or rewrite responses — the deviation is expressed only
through the existing capability flag, so all command generation, response
parsing, and model extraction remain byte-identical to native.

**Consequence / trade-off.** This is a deliberate deviation from the spec's
Requirement 5.6 ("advertise the same capabilities as native Z3"). With
global-declarations off, Z3 treats declarations as *scoped*: a `pop` removes
declarations made since the matching `push`. Single-shot solving — `sat`,
`prove`, `optimize`, and `runSMTWith` without nested `push`/`pop` over shared
declarations — is unaffected (this is what the demo exercises). Incremental
query sessions that rely on declarations surviving a `pop` (e.g. some `allSat`
enumeration patterns) are limited, exactly as for any non-global-decls solver.
`supportsIEEE754` and every other capability remain identical to native.



`sat`/`prove` on the `SBV_WASM` target use `defaultSMTCfg = z3Wasm`, whose
engine is `browserEngine` (`Data.SBV.SMT.BrowserEngine`). That engine builds the
same `QueryState` the native engine builds, but its send/receive closures call
`WasmBridge.sendCommand` instead of OS pipes. On the wasm target those resolve
to `foreign import javascript` calls that `await` the `z3-solver` Promises,
suspending only the calling Haskell thread and yielding to the browser event
loop. Each SMT-LIB2 command goes to `Z3.eval_smtlib2_string`, which preserves
solver state across calls — so SBV's incremental `(set-option …)` /
`declare` / `assert` / `check-sat` / `get-model` sequence works unchanged, and
all SMT-Lib2 generation, response parsing, and model extraction are reused
exactly as on the native path.

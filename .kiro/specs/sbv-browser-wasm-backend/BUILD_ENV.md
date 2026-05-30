# Build Environment Facts (read this first — do NOT re-probe with `which`/`ghcup list`)

This note exists so task subagents have the exact toolchain + commands and avoid
re-discovering the environment. All facts below were verified at orchestration start.

## Project
- Repo root: `/home/t/Documents/papers/sigcomm/sbv/sbv`
- Package: `sbv` version 14.2, BSD-3, `Cabal-Version: 2.2`, `Build-Type: Simple`.
- Cabal file: `/home/t/Documents/papers/sigcomm/sbv/sbv/sbv.cabal`
- There is **no** `cabal.project` file; build from the repo root.

## Native toolchain (default — use this for everything except the wasm-only tasks)
- `cabal` → `/home/t/.ghcup/bin/cabal`, **cabal-install 3.14.2.0**
- `ghc`   → `/home/t/.ghcup/bin/ghc`, **GHC 9.10.3**
- A native solver is available: `z3` → `/home/t/.pyenv/shims/z3`, **Z3 version 4.15.0**.
  No other SMT solvers (cvc5, bitwuzla, yices, boolector) are installed.

### Native build / test commands (run from repo root)
- Build the library:               `cabal build lib:sbv`
- Build the test suite:            `cabal build SBVTest`
- Run the whole test suite:        `cabal test SBVTest`
- Run a single tasty test pattern: `cabal run SBVTest -- -p '<pattern>'`
  (the suite uses `tasty`/`tasty-quickcheck`/`tasty-hunit`/`tasty-golden`)
- If a dependency hiccup appears, the CI uses `cabal build --allow-newer all`.

Note: the very first `cabal build` may need `cabal update` once and will compile
dependencies (QuickCheck, tasty, libBF, etc.). Subsequent builds are incremental.

## WASM (browser-target) toolchain — ONLY needed for tasks 11.1 and 17.1
- GHC wasm cross compiler installed via **ghcup**, flavour **9.15**:
  - `wasm32-wasi-ghc-9.15`     → `/home/t/.ghcup/bin/wasm32-wasi-ghc-9.15`
  - `wasm32-wasi-ghc-pkg-9.15` → `/home/t/.ghcup/bin/wasm32-wasi-ghc-pkg-9.15`
  - `wasm32-wasi-hsc2hs-9.15`  → `/home/t/.ghcup/bin/wasm32-wasi-hsc2hs-9.15`
- There is **no** `wasm32-wasi-cabal` wrapper on PATH. Invoke the wasm build by
  pointing cabal at the cross compiler explicitly, and use a separate build dir
  and CABAL_DIR so it never clobbers the native `dist-newstyle`:

```
CABAL_DIR="$HOME/.ghc-wasm/.cabal" cabal \
  --with-compiler=$HOME/.ghcup/bin/wasm32-wasi-ghc-9.15 \
  --with-hc-pkg=$HOME/.ghcup/bin/wasm32-wasi-ghc-pkg-9.15 \
  --with-hsc2hs=$HOME/.ghcup/bin/wasm32-wasi-hsc2hs-9.15 \
  --builddir=dist-wasm \
  build lib:sbv
```

  - The wasm build selects the browser path automatically via the cabal
    `if arch(wasm32)` stanza (which sets `-DSBV_WASM`); native builds are
    untouched.
  - The wasm cabal config dir is created on first use under `$HOME/.ghc-wasm/.cabal`.
  - Building wasm deps from scratch is slow; only the two build/CI tasks (11.1,
    17.1) should attempt it. All PBT/unit tasks use the **native** build + MockBridge.

## Conventions for this spec
- All browser-only code is gated behind `#ifdef SBV_WASM` (source) and
  `if arch(wasm32)` (cabal). The native build must remain byte-for-byte
  behaviorally identical.
- The `#ifdef SBV_WASM` branches must never import `System.Process`,
  `System.Directory`, or `System.Environment`. `libBF` IS allowed on the wasm path.
- Property tests use **QuickCheck** through `tasty-quickcheck`, one property per
  test, each tagged with a comment:
  `-- Feature: sbv-browser-wasm-backend, Property N: <text>`
  P1–P13 use a minimum of 100 iterations and run via the `MockBridge` harness
  (`SBVTestSuite/Utils/MockBridge.hs`) — no real solver. P14–P15 are solver-backed
  (native `z3` is available) at a reduced budget (20–50 iterations).
- New test modules must be registered in `SBVTestSuite/SBVTest.hs` and in the
  `SBVTest` suite's `other-modules` in `sbv.cabal`.
- After any code change, verify with `cabal build` (and the relevant `cabal test`
  / `cabal run SBVTest -- -p ...`). Clean up temp files.

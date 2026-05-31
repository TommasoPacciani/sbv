# cvc5 wasm — blocker

## Status: BLOCKED (z3 from source works end-to-end; cvc5 does not)

## What was built
`web/solver/cvc5.{js,wasm}` from source (cvc5 src at `~/sbvw-build/cvc5`) via
emscripten with `--wasm=WASM` + `-sMODULARIZE=1 -sEXPORT_ES6=1`. The artifact is
**single-threaded** (no pthreads) and **honors `Module.stdin`**
(`createStandardStreams` uses `Module["stdin"]`) — so the worker model is sound.

## Symptom
`inst.callMain([...])` throws an **uncaught C++ exception pointer (~866368)
immediately**, even for `['--version']` (no stdin needed), with no stdout/stderr.
Auto-run via `factory({arguments:['--version']})` produces no output at all.
`getExceptionMessage` is not exported, so the throw can't be decoded as built.

## Root-cause lead
cvc5's official CI (`.github/workflows/ci.yml`) builds the wasm with **exactly**:
```
production --static --static-binary --auto-download --wasm=JS --wasm-flags='-s MODULARIZE'
```
i.e. `--wasm=JS`, not the `--wasm=WASM` used here — and the CI runs **no
regressions** on the wasm build, so cvc5's wasm-as-CLI is not upstream-validated.
The wrong target (+ extra flags) very likely produced a non-functional entry.

## Next steps (corrected recipe to try)
1. Activate the emscripten version cvc5 pins (read
   `.github/actions/install-dependencies/action.yml` in the cvc5 checkout).
2. `rm -rf build-wasm && ./configure.sh production --static --static-binary \
   --auto-download --wasm=JS --wasm-flags='-s MODULARIZE -s EXPORT_ES6=1 \
   -s EXPORTED_RUNTIME_METHODS=callMain,FS -s FORCE_FILESYSTEM=1 -s ASSERTIONS=2' \
   --name=build-wasm && cd build-wasm && make -j$(nproc) cvc5`.
3. `-sASSERTIONS=2` should turn the bare pointer into a readable abort message.
4. Confirm cvc5 can **stream** SMT2 from stdin (args to try, in order):
   `['--lang','smt2','--incremental']` (no file ⇒ stdin), then `+['-']`, then
   `['--lang','smt2']`. If cvc5 wasm only accepts a file (no streaming stdin),
   it cannot drive SBV's interactive protocol via the current worker — would need
   cvc5's Embind/JS API instead, a larger effort.
5. On success: route is already in `web/main.js`; add `satWith cvc5` Int/Real to
   `wasm/Main.hs`, rebuild the SBV wasm, extend `web/test/emscripten-cli.test.mjs`.

## Meanwhile
z3 (from source, single-threaded emscripten) delivers Int/Real/Float end-to-end
through pristine SBV — see `web/test/{emscripten-cli,e2e}.test.mjs`. cvc5 is a
second-solver nice-to-have and is deferred, not on the Grisette critical path.

# Tasks

- [x] 1. **z3 from source → single-threaded emscripten CLI** (R1, R3, R5)
  - Pinned emsdk + z3 tag; `web/solver/z3.{js,wasm}` + `build-z3.sh`. Node smoke
    test (sat, x=4) green.

- [x] 2. **Generalized blocking-stdin worker + route z3 + full-theory demo** (R2, R3, R4, R6)
  - `web/src/emscripten-cli-worker.js` (Node + browser entries); `main.js` routes
    `z3`; `wasm/Main.hs` adds `satWith z3` Int/Real/Float + a prove; SBV wasm
    rebuilt + post-linked. `web/test/emscripten-cli.test.mjs` green.

- [ ] 3. **cvc5 from source → single-threaded emscripten CLI + wire** — **BACKLOG**
  - Build produced `web/solver/cvc5.{js,wasm}` (single-threaded) but it throws on
    `callMain`. Root cause + corrected `--wasm=JS` recipe in `cvc5-blocker.md`.
    Not on the Grisette critical path.

- [x] 4. **Verify + summarize** (R4, R5)
  - Node: `pipe-pingpong`, `solver-pipe`, `emscripten-cli` (z3), `e2e` all green.
  - Headless Chrome (`run-browser-check.sh`): live page solves `SInteger`=4,
    `SReal`=2.5, `SDouble`=2.5, `prove` Q.E.D. — full theories in a real browser.
    Boolector bit-vector demo still green.

// ---------------------------------------------------------------------------
// loader.mjs
//
// Browser loader for the SBV WebAssembly demo. It wires together three pieces:
//
//   1. The GHC-wasm artifact `sbv-wasm-demo.wasm` (the SBV library + the
//      reactor entry point in wasm/Main.hs), built with the wasm32-wasi GHC.
//   2. `sbv-wasm-demo.js`, the ESM produced by GHC's `post-link.mjs`. Its
//      default export is `(__exports) => importObject_for_ghc_wasm_jsffi`,
//      built from the `ghc_wasm_jsffi` custom section. The generated function
//      bodies read `globalThis` (e.g. `sbvZ3Wasm.init()`), so the glue below
//      must be imported first to install `globalThis.sbvZ3Wasm`.
//   3. `sbvZ3Wasm.js`, the bridge to the `z3-solver` npm package.
//
// A WASI shim is required because the GHC runtime links against wasi-libc and
// needs `wasi_snapshot_preview1` imports (clock, random, stdout, ...), even in
// reactor mode.
// ---------------------------------------------------------------------------

import { WASI, OpenFile, File, ConsoleStdout } from '@bjorn3/browser_wasi_shim';
import './sbvZ3Wasm.js';                 // installs globalThis.sbvZ3Wasm (side effect)
import ghcWasmJSFFI from './sbv-wasm-demo.js';   // post-link.mjs output (default export)

function log(line) {
  const pre = document.getElementById('output');
  pre.textContent += line.endsWith('\n') ? line : line + '\n';
}

async function run() {
  log('Loading SBV (WebAssembly) and z3-solver ...');

  // WASI environment: empty argv/env; stdin is an empty file; stdout/stderr are
  // routed to the page so Haskell `putStr` output is visible.
  const wasi = new WASI([], [], [
    new OpenFile(new File([])),                              // fd 0: stdin
    ConsoleStdout.lineBuffered((s) => log(s)),               // fd 1: stdout
    ConsoleStdout.lineBuffered((s) => log('[stderr] ' + s)), // fd 2: stderr
  ]);

  const wasmModule = await WebAssembly.compileStreaming(fetch('./sbv-wasm-demo.wasm'));

  // __exports is filled in after instantiation (knot-tying): the JSFFI function
  // bodies close over it so they can call back into the wasm instance (e.g. to
  // manage JSVals and the RTS scheduler).
  const __exports = {};

  const instance = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghcWasmJSFFI(__exports),
  });

  Object.assign(__exports, instance.exports);

  // Reactor initialization: run wasi `_initialize` (which runs __wasm_call_ctors)
  // and then initialize the Haskell RTS.
  wasi.initialize(instance);
  instance.exports.hs_init(0, 0);

  log('Solving in the browser ...\n');

  // sbvRunDemos is a `foreign export javascript` returning a Promise<string>.
  const report = await instance.exports.sbvRunDemos();
  log('\n===== SBV result =====');
  log(typeof report === 'string' ? report : String(report));
}

run().catch((e) => {
  log('\nERROR: ' + (e && e.stack ? e.stack : String(e)));
});

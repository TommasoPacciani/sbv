// Node mirror of web/src/sbv-worker.js (parentPort/fs instead of postMessage/fetch),
// so the exact browser code path can be exercised headless.
import { parentPort } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { WASI, OpenFile, File, ConsoleStdout } from '@bjorn3/browser_wasi_shim';
import { makePipe, Pipe } from '../src/sabpipe.js';
import { PipeFd } from '../src/pipefd.js';
import ghcWasmJSFFI from '../sbv-wasm-demo.js';

const wasi = new WASI([], [], [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((s) => parentPort.postMessage({ type: 'stdout', line: s })),
  ConsoleStdout.lineBuffered((s) => parentPort.postMessage({ type: 'stderr', line: s })),
]);

globalThis.spawnSolver = (exe, argsStr) => {
  const cmdSab = makePipe(), respSab = makePipe(), errSab = makePipe();
  const base = wasi.fds.length;
  wasi.fds.push(new PipeFd(null, new Pipe(cmdSab)));
  wasi.fds.push(new PipeFd(new Pipe(respSab), null));
  wasi.fds.push(new PipeFd(new Pipe(errSab), null));
  parentPort.postMessage({ type: 'spawnSolver', cmdSab, respSab, errSab, exe, args: argsStr });
  return base;
};
globalThis.terminateSolver = (base) => parentPort.postMessage({ type: 'terminateSolver', base });

const mod = await WebAssembly.compile(readFileSync(new URL('../sbv-wasm-demo.wasm', import.meta.url)));
const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghcWasmJSFFI(__exports),
});
Object.assign(__exports, inst.exports);
try { wasi.start(inst); parentPort.postMessage({ type: 'done' }); }
catch (e) { parentPort.postMessage({ type: 'error', error: String((e && e.stack) || e) }); }

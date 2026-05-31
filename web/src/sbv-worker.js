// sbv-worker.js — runs the pristine SBV demo (sbv-wasm-demo.wasm) as a WASI
// command in a Web Worker. SBV's native engine calls runInteractiveProcess,
// which (via the sbv-wasm-os shim's JSFFI) calls globalThis.spawnSolver here:
// we allocate three SAB pipes, inject them as WASI fds for this instance, and
// ask the broker (main thread) to start the actual solver worker on those SABs.
import { WASI, OpenFile, File, ConsoleStdout } from '@bjorn3/browser_wasi_shim';
import { makePipe, Pipe } from './sabpipe.js';
import { PipeFd } from './pipefd.js';
import ghcWasmJSFFI from '../sbv-wasm-demo.js';

const wasi = new WASI([], [], [
  new OpenFile(new File([])),                                   // 0 stdin
  ConsoleStdout.lineBuffered((s) => postMessage({ type: 'stdout', line: s })), // 1
  ConsoleStdout.lineBuffered((s) => postMessage({ type: 'stderr', line: s })), // 2
]);

// Called synchronously from SBV's runInteractiveProcess (unsafe JSFFI).
// exe = "/bin/boolector", argsStr = newline-joined options.
globalThis.spawnSolver = (exe, argsStr) => {
  const cmdSab = makePipe(), respSab = makePipe(), errSab = makePipe();
  const base = wasi.fds.length;
  wasi.fds.push(new PipeFd(null, new Pipe(cmdSab)));   // base   : inh  (SBV writes)
  wasi.fds.push(new PipeFd(new Pipe(respSab), null));  // base+1 : outh (SBV reads)
  wasi.fds.push(new PipeFd(new Pipe(errSab), null));   // base+2 : errh (SBV reads)
  postMessage({ type: 'spawnSolver', cmdSab, respSab, errSab, exe, args: argsStr });
  return base;
};
globalThis.terminateSolver = (base) => postMessage({ type: 'terminateSolver', base });

const mod = await WebAssembly.compileStreaming(fetch(new URL('../sbv-wasm-demo.wasm', import.meta.url)));
const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghcWasmJSFFI(__exports),
});
Object.assign(__exports, inst.exports);
try {
  wasi.start(inst);                       // _start -> main; blocks on solver pipes
  postMessage({ type: 'done' });
} catch (e) {
  postMessage({ type: 'error', error: String((e && e.stack) || e) });
}

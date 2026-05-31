// grisette-worker.js — runs the Grisette demo (grisette-wasm-demo.wasm) as a
// WASI command in a Web Worker. Identical to sbv-worker.js but for the Grisette
// artifact. SBV's native engine (inside Grisette) spawns the solver via the
// os-shim's globalThis.spawnSolver, brokered on the main thread.
import { WASI, OpenFile, File, ConsoleStdout } from '@bjorn3/browser_wasi_shim';
import { makePipe, Pipe } from './sabpipe.js';
import { PipeFd } from './pipefd.js';
import { installPoll } from './poll.js';
import ghcWasmJSFFI from '../grisette-wasm-demo.js';

const wasi = new WASI([], [], [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((s) => postMessage({ type: 'stdout', line: s })),
  ConsoleStdout.lineBuffered((s) => postMessage({ type: 'stderr', line: s })),
]);

const pollFds = new Map();
installPoll(wasi, pollFds);

globalThis.spawnSolver = (exe, argsStr) => {
  const cmdSab = makePipe(), respSab = makePipe(), errSab = makePipe();
  const base = wasi.fds.length;
  const outFd = new PipeFd(new Pipe(respSab), null);
  const errFd = new PipeFd(new Pipe(errSab), null);
  wasi.fds.push(new PipeFd(null, new Pipe(cmdSab)), outFd, errFd);
  pollFds.set(base + 1, outFd); pollFds.set(base + 2, errFd);
  postMessage({ type: 'spawnSolver', cmdSab, respSab, errSab, exe, args: argsStr });
  return base;
};
globalThis.terminateSolver = (base) => postMessage({ type: 'terminateSolver', base });

const mod = await WebAssembly.compileStreaming(fetch(new URL('../grisette-wasm-demo.wasm', import.meta.url)));
const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghcWasmJSFFI(__exports),
});
Object.assign(__exports, inst.exports);
try { wasi.start(inst); postMessage({ type: 'done' }); }
catch (e) { postMessage({ type: 'error', error: String((e && e.stack) || e) }); }

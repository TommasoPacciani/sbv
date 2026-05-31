// Node worker that runs the Grisette demo wasm (Grisette -> SBV -> in-browser z3).
// Mirror of sbv-node-worker.mjs with the grisette-wasm-demo artifact.
import { parentPort } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { WASI, OpenFile, File, ConsoleStdout } from '@bjorn3/browser_wasi_shim';
import { makePipe, Pipe } from '../src/sabpipe.js';
import { PipeFd } from '../src/pipefd.js';
import { installPoll } from '../src/poll.js';
import ghcWasmJSFFI from '../grisette-wasm-demo.js';

const wasi = new WASI([], [], [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((s) => parentPort.postMessage({ type: 'stdout', line: s })),
  ConsoleStdout.lineBuffered((s) => parentPort.postMessage({ type: 'stderr', line: s })),
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
  parentPort.postMessage({ type: 'spawnSolver', cmdSab, respSab, errSab, exe, args: argsStr });
  return base;
};
globalThis.terminateSolver = (base) => parentPort.postMessage({ type: 'terminateSolver', base });

const mod = await WebAssembly.compile(readFileSync(new URL('../grisette-wasm-demo.wasm', import.meta.url)));
const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghcWasmJSFFI(__exports),
});
Object.assign(__exports, inst.exports);
try { wasi.start(inst); parentPort.postMessage({ type: 'done' }); }
catch (e) { parentPort.postMessage({ type: 'error', error: String((e && e.stack) || e) }); }

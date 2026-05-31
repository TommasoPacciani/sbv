import { parentPort, workerData } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import { WASI, OpenFile, File, ConsoleStdout, WASIProcExit } from '@bjorn3/browser_wasi_shim';
import { Pipe } from '../src/sabpipe.js';
import { PipeFd } from '../src/pipefd.js';
import ghcWasmJSFFI from './probe.js';

const cmdPipe = new Pipe(workerData.cmdSab);    // probe writes here (its hIn)
const respPipe = new Pipe(workerData.respSab);  // probe reads here (its hOut)

let out = '';
const wasi = new WASI([], [], [
  new OpenFile(new File([])),                       // 0 stdin
  ConsoleStdout.lineBuffered((s) => { out += s + '\n'; }), // 1 stdout
  ConsoleStdout.lineBuffered(() => {}),             // 2 stderr
]);

// Host fn the probe's JSFFI calls: inject the pipe fds and return the base index.
globalThis.spawnEcho = () => {
  const base = wasi.fds.length;
  wasi.fds.push(new PipeFd(null, cmdPipe));   // base   : probe writes -> cmd pipe
  wasi.fds.push(new PipeFd(respPipe, null));  // base+1 : probe reads  <- resp pipe
  return base;
};

const mod = await WebAssembly.compile(readFileSync(new URL('./probe.wasm', import.meta.url)));
const __exports = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghcWasmJSFFI(__exports),
});
Object.assign(__exports, inst.exports);

try {
  wasi.start(inst);                                  // _start -> main (blocks on hGetLine)
  parentPort.postMessage({ ok: true, result: out.trim() });
} catch (e) {
  if (e instanceof WASIProcExit && e.code === 0) parentPort.postMessage({ ok: true, result: out.trim() });
  else parentPort.postMessage({ ok: false, error: String(e && e.stack || e), out });
}

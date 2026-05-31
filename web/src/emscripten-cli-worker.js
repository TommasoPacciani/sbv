// emscripten-cli-worker.js – Runs any single-threaded emscripten CLI solver
// (z3, cvc5, etc.) with stdin/stdout/stderr over SAB pipes.
// Works as both a Node worker_threads worker and a browser Web Worker.
import { Pipe } from './sabpipe.js';

const enc = new TextEncoder();

export async function runCli({ moduleUrl, args, cmdSab, respSab, errSab }) {
  const cmd = new Pipe(cmdSab), resp = new Pipe(respSab), err = new Pipe(errSab);
  // Line-buffered stdin: after returning \n, return null to force a partial
  // read in the emscripten FS. This makes the C library process one line at a
  // time (interactive/incremental mode) instead of buffering all input.
  let sawNewline = false;
  const stdin = () => {
    if (sawNewline) { sawNewline = false; return null; }
    const byte = cmd.readBytes(1);
    if (!byte.length) return null;
    if (byte[0] === 10) sawNewline = true;
    return byte[0];
  };
  const factory = (await import(moduleUrl)).default;
  const inst = await factory({
    noInitialRun: true,
    stdin,
    print:    s => resp.writeBytes(enc.encode(s + '\n')),
    printErr: s => err.writeBytes(enc.encode(s + '\n')),
  });
  try { inst.callMain(args); } catch (e) { if (e?.status !== 0 && e?.name !== 'ExitStatus') throw e; }
  resp.close(); err.close();
}

// --- Entry points ---
if (typeof process !== 'undefined' && process.versions?.node) {
  // Node worker_threads entry
  const { workerData, isMainThread } = await import('node:worker_threads');
  if (!isMainThread && workerData?.cmdSab) {
    await runCli(workerData);
  }
} else if (typeof self !== 'undefined' && typeof self.postMessage === 'function') {
  // Browser Web Worker entry
  self.onmessage = (ev) => {
    const d = ev.data;
    if (!d.moduleUrl) d.moduleUrl = new URL(d.module, import.meta.url).href;
    runCli(d);
  };
}

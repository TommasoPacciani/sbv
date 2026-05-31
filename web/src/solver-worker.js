// solver-worker.js – runs a wasm32-wasi solver with stdio over SAB pipes.
import { Pipe } from './sabpipe.js';
import { PipeFd } from './pipefd.js';
import { WASI, WASIProcExit } from '@bjorn3/browser_wasi_shim';

export async function runSolver({ cmdSab, respSab, errSab, wasmPath, args }) {
  const cmdPipe = new Pipe(cmdSab);
  const respPipe = new Pipe(respSab);
  const errPipe = new Pipe(errSab);

  const fds = [
    new PipeFd(cmdPipe, null),   // fd 0: stdin
    new PipeFd(null, respPipe),  // fd 1: stdout
    new PipeFd(null, errPipe),   // fd 2: stderr
  ];

  const wasi = new WASI(args, [], fds);

  try {
    let bytes;
    if (typeof globalThis.process !== 'undefined' && globalThis.process.versions?.node) {
      const fs = await import('node:fs');
      bytes = fs.readFileSync(wasmPath);
    } else {
      const resp = await fetch(wasmPath);
      bytes = await resp.arrayBuffer();
    }
    const module = new WebAssembly.Module(bytes);
    const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi.wasiImport });
    wasi.start(instance);
  } catch (e) {
    if (!(e instanceof WASIProcExit)) throw e;
  } finally {
    respPipe.close();
    errPipe.close();
  }
}

// Web Worker entry point (browser): guard so node import doesn't blow up.
if (typeof self !== 'undefined' && typeof self.onmessage !== 'undefined') {
  self.onmessage = (ev) => runSolver(ev.data);
}

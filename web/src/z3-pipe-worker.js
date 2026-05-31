// z3-pipe-worker.js – Z3 as a persistent-context pipe-process over SAB pipes.
// Uses the emscripten Z3 from z3-solver (v4.15.0). ONE context, ONE thread for
// Z3 (the thread where emscripten pthreads can operate), with an async eval loop.
//
// Architecture: Z3's eval_smtlib2_string is async (dispatches to a pthread).
// Atomics.wait (blocking pipe reads) would starve the event loop and prevent
// pthread message processing. Solution: a sub-worker ("reader") blocks on the
// cmd pipe and forwards complete commands via postMessage; this thread (the Z3
// host) processes them asynchronously and writes responses to the resp pipe.

import { Pipe } from './sabpipe.js';

// ─── Reader worker code (runs in a sub-worker / worker_thread) ───────────────
// Blocks on the cmd pipe, extracts complete S-expression commands, posts them.
const READER_SOURCE = `
import { Pipe } from './sabpipe.js';
import { parentPort, workerData } from 'node:worker_threads';

const cmdPipe = new Pipe(workerData.cmdSab);
const enc = new TextEncoder();
const dec = new TextDecoder();
let buf = '';

while (true) {
  const chunk = cmdPipe.readBytes(4096);
  if (chunk.length === 0) { parentPort.postMessage({ type: 'eof' }); break; }
  buf += dec.decode(chunk);
  // Split on newlines; each line is one SMT-LIB2 command from SBV
  let nl;
  while ((nl = buf.indexOf('\\n')) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line.length > 0) parentPort.postMessage({ type: 'cmd', cmd: line });
  }
}
`;

export async function runZ3({ cmdSab, respSab, errSab }) {
  const respPipe = new Pipe(respSab);
  const errPipe = new Pipe(errSab);
  const enc = new TextEncoder();

  // Initialize z3-solver (the low-level wrapper gives us Z3 + em Module)
  const { createRequire } = await import('node:module');
  const { fileURLToPath } = await import('node:url');
  const { Worker: NodeWorker, isMainThread } = await import('node:worker_threads');
  const path = await import('node:path');

  // Locate z3-solver relative to this file
  const thisDir = path.dirname(fileURLToPath(import.meta.url));
  const require = createRequire(import.meta.url);
  const initModule = require('z3-solver/build/z3-built');

  const Mod = await initModule();

  // Create a persistent Z3 context
  const cfg = Mod._Z3_mk_config();
  const ctx = Mod._Z3_mk_context(cfg);
  Mod._Z3_del_config(cfg);
  // set_noop_error_handler is already called by the wrapper's mk_context

  function evalCmd(cmd) {
    // Z3_eval_smtlib2_string: synchronous on this thread (no pthread dispatch)
    // It processes the command on the persistent context and returns the output.
    return Mod.ccall('Z3_eval_smtlib2_string', 'string', ['number', 'string'], [ctx, cmd]);
  }

  // Spawn a reader sub-worker that blocks on the cmd pipe
  const readerCode = `
import { Pipe } from '${path.join(thisDir, 'sabpipe.js').replace(/\\/g, '/')}';
import { parentPort, workerData } from 'node:worker_threads';

const cmdPipe = new Pipe(workerData.cmdSab);
const dec = new TextDecoder();
let buf = '';

while (true) {
  const chunk = cmdPipe.readBytes(4096);
  if (chunk.length === 0) { parentPort.postMessage({ type: 'eof' }); break; }
  buf += dec.decode(chunk);
  let nl;
  while ((nl = buf.indexOf('\\n')) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line.length > 0) parentPort.postMessage({ type: 'cmd', cmd: line });
  }
}
`;

  return new Promise((resolve, reject) => {
    const reader = new NodeWorker(readerCode, {
      eval: true,
      workerData: { cmdSab },
    });

    reader.on('message', (msg) => {
      if (msg.type === 'eof') {
        Mod._Z3_del_context(ctx);
        respPipe.close();
        errPipe.close();
        resolve();
        return;
      }
      if (msg.type === 'cmd') {
        const cmd = msg.cmd;
        if (cmd === '(exit)') {
          Mod._Z3_del_context(ctx);
          respPipe.close();
          errPipe.close();
          reader.terminate();
          resolve();
          return;
        }
        try {
          const result = evalCmd(cmd);
          if (result && result.length > 0) {
            respPipe.writeBytes(enc.encode(result + '\n'));
          }
        } catch (e) {
          errPipe.writeBytes(enc.encode('error: ' + e.message + '\n'));
        }
      }
    });

    reader.on('error', (e) => {
      errPipe.writeBytes(enc.encode('reader error: ' + e.message + '\n'));
      reject(e);
    });
  });
}

// Web Worker entry point (browser): guard so node import doesn't blow up.
if (typeof self !== 'undefined' && typeof self.onmessage !== 'undefined') {
  self.onmessage = (ev) => runZ3(ev.data);
}

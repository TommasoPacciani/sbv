// emscripten-cli.test.mjs – Drives z3 through emscripten-cli-worker over SAB pipes.
// Main thread spawns the worker; a second worker_threads worker acts as fake-SBV.
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import { makePipe, Pipe } from '../src/sabpipe.js';
import path from 'node:path';

if (!isMainThread) {
  // --- Fake-SBV worker: write SMT-LIB2 commands, read responses ---
  const cmdPipe = new Pipe(workerData.cmdSab);
  const respPipe = new Pipe(workerData.respSab);
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  function send(cmd) { cmdPipe.writeBytes(enc.encode(cmd + '\n')); }
  function readLines(n, timeoutMs = 60000) {
    const lines = [];
    let buf = '';
    const deadline = Date.now() + timeoutMs;
    while (lines.length < n) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      const chunk = respPipe.readBytes(4096, remaining);
      if (chunk.length === 0) break;
      buf += dec.decode(chunk);
      let nl;
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line.length > 0) lines.push(line);
      }
    }
    return lines;
  }

  // Test 1: Integer (x*3==12 -> x=4)
  send('(set-option :print-success true)');
  send('(set-logic ALL)');
  send('(declare-const x Int)');
  send('(assert (= (* x 3) 12))');
  send('(check-sat)');
  send('(get-value (x))');
  const resp1 = readLines(6);
  parentPort.postMessage({ phase: 1, lines: resp1 });

  // Test 2: Real (r*2==5 -> r=5/2)
  send('(declare-const r Real)');
  send('(assert (= (* r 2.0) 5.0))');
  send('(check-sat)');
  send('(get-value (r))');
  const resp2 = readLines(4);
  parentPort.postMessage({ phase: 2, lines: resp2 });

  send('(exit)');
  process.exit(0);
} else {
  // --- Main thread: spawn emscripten-cli-worker + fake-SBV worker ---
  const cmdSab = makePipe();
  const respSab = makePipe();
  const errSab = makePipe();

  const thisDir = path.dirname(fileURLToPath(import.meta.url));
  const solverDir = path.resolve(thisDir, '..', 'solver');
  const moduleUrl = 'file://' + path.join(solverDir, 'z3.js');

  // Spawn the emscripten-cli-worker
  const workerPath = path.resolve(thisDir, '..', 'src', 'emscripten-cli-worker.js');
  const solverWorker = new Worker(workerPath, {
    workerData: { moduleUrl, args: ['-smt2', '-in'], cmdSab, respSab, errSab },
  });

  // Spawn fake-SBV worker (this file, non-main-thread path)
  const sbvWorker = new Worker(fileURLToPath(import.meta.url), {
    workerData: { cmdSab, respSab, errSab },
  });

  let pass = true;
  sbvWorker.on('message', (msg) => {
    if (msg.phase === 1) {
      console.log('Phase 1 (Int):', msg.lines);
      const expected = ['success', 'success', 'success', 'success', 'sat'];
      for (let i = 0; i < expected.length; i++) {
        if (msg.lines[i] !== expected[i]) { console.log(`  FAIL line ${i}: expected '${expected[i]}', got '${msg.lines[i]}'`); pass = false; }
      }
      if (!(msg.lines[5] || '').includes('4')) { console.log(`  FAIL: expected x=4, got '${msg.lines[5]}'`); pass = false; }
      else console.log('  OK: x = 4');
    }
    if (msg.phase === 2) {
      console.log('Phase 2 (Real):', msg.lines);
      if (msg.lines[0] !== 'success' || msg.lines[1] !== 'success') { console.log('  FAIL: expected success'); pass = false; }
      if (msg.lines[2] !== 'sat') { console.log(`  FAIL: expected sat, got '${msg.lines[2]}'`); pass = false; }
      const val = msg.lines[3] || '';
      if (!val.includes('5/2') && !val.includes('2.5') && !val.includes('(/ 5 2)') && !val.includes('(/ 5.0 2.0)')) {
        console.log(`  FAIL: expected r=5/2, got '${val}'`); pass = false;
      } else console.log('  OK: r = 5/2');
    }
  });

  sbvWorker.on('exit', () => {
    solverWorker.terminate();
    console.log(pass ? '\nPASS' : '\nFAIL');
    process.exit(pass ? 0 : 1);
  });

  solverWorker.on('error', (e) => { console.error('solver worker error:', e); pass = false; });
  sbvWorker.on('error', (e) => { console.error('sbv worker error:', e); pass = false; });
}

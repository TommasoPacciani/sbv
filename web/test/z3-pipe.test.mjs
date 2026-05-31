// z3-pipe.test.mjs – Proves full-theory (Int, Real) SMT solving over SAB pipes
// using the z3-solver emscripten build as a persistent-context pipe-process.
//
// Architecture: Z3 runs on the main thread (where emscripten pthreads work).
// A worker_threads Worker acts as "fake SBV", blocking on pipes.
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import { makePipe, Pipe } from '../src/sabpipe.js';

if (!isMainThread) {
  // ─── Worker role: fake SBV that writes commands and reads responses ─────────
  const cmdPipe = new Pipe(workerData.cmdSab);
  const respPipe = new Pipe(workerData.respSab);
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  function send(cmd) { cmdPipe.writeBytes(enc.encode(cmd + '\n')); }

  function readLines(n, timeoutMs = 30000) {
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

  // ─── Test 1: Integer arithmetic ────────────────────────────────────────────
  send('(set-option :print-success true)');
  send('(set-logic ALL)');
  send('(declare-const x Int)');
  send('(assert (= (* x 3) 12))');
  send('(check-sat)');
  send('(get-value (x))');

  const resp1 = readLines(6);
  parentPort.postMessage({ phase: 1, lines: resp1 });

  // ─── Test 2: Real arithmetic (same persistent context) ─────────────────────
  send('(declare-const r Real)');
  send('(assert (= (* r 2.0) 5.0))');
  send('(check-sat)');
  send('(get-value (r))');

  const resp2 = readLines(4);
  parentPort.postMessage({ phase: 2, lines: resp2 });

  send('(exit)');
  process.exit(0);
} else {
  // ─── Main thread: run Z3, spawn fake-SBV worker ────────────────────────────
  const cmdSab = makePipe();
  const respSab = makePipe();
  const errSab = makePipe();

  // Import and run Z3 on this (main) thread
  const { runZ3 } = await import('../src/z3-pipe-worker.js');

  // Start fake-SBV worker
  const sbvWorker = new Worker(fileURLToPath(import.meta.url), {
    workerData: { cmdSab, respSab, errSab },
  });

  let pass = true;

  sbvWorker.on('message', (msg) => {
    if (msg.phase === 1) {
      console.log('Phase 1 (Int): responses =', msg.lines);
      // Expect: success, success, success, success, sat, ((x 4))
      const expected = ['success', 'success', 'success', 'success', 'sat'];
      for (let i = 0; i < expected.length; i++) {
        if (msg.lines[i] !== expected[i]) {
          console.log(`  FAIL line ${i}: expected '${expected[i]}', got '${msg.lines[i]}'`);
          pass = false;
        }
      }
      // Check x=4 in the get-value response
      const valLine = msg.lines[5] || '';
      if (!valLine.includes('4')) {
        console.log(`  FAIL get-value: expected x=4, got '${valLine}'`);
        pass = false;
      } else {
        console.log('  OK: x = 4');
      }
    }
    if (msg.phase === 2) {
      console.log('Phase 2 (Real): responses =', msg.lines);
      // Expect: success, success, sat, ((r ...))
      if (msg.lines[0] !== 'success' || msg.lines[1] !== 'success') {
        console.log('  FAIL: expected success lines');
        pass = false;
      }
      if (msg.lines[2] !== 'sat') {
        console.log(`  FAIL: expected 'sat', got '${msg.lines[2]}'`);
        pass = false;
      }
      // r should be 5/2 or 2.5
      const valLine = msg.lines[3] || '';
      if (!valLine.includes('5/2') && !valLine.includes('2.5') && !valLine.includes('(/ 5 2)') && !valLine.includes('(/ 5.0 2.0)')) {
        console.log(`  FAIL get-value: expected r=5/2 or 2.5, got '${valLine}'`);
        pass = false;
      } else {
        console.log('  OK: r = 5/2');
      }
    }
  });

  sbvWorker.on('exit', () => {
    if (pass) {
      console.log('\nPASS');
      process.exit(0);
    } else {
      console.log('\nFAIL');
      process.exit(1);
    }
  });

  // Run Z3 (blocks until (exit) received)
  runZ3({ cmdSab, respSab, errSab }).catch((e) => {
    console.error('Z3 error:', e);
    process.exit(1);
  });
}

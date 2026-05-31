import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import { makePipe, Pipe } from '../src/sabpipe.js';

if (!isMainThread) {
  // Worker: read from pipeA, echo to pipeB
  const pipeA = new Pipe(workerData.sabA);
  const pipeB = new Pipe(workerData.sabB);
  const msg = pipeA.readBytes(1024);
  pipeB.writeBytes(msg);
  // Second read for wraparound test
  const msg2 = pipeA.readBytes(1024);
  pipeB.writeBytes(msg2);
  parentPort.postMessage('done');
} else {
  function assert(cond, msg) { if (!cond) { console.log('FAIL: ' + msg); process.exit(1); } }
  function arrEq(a, b) { if (a.length !== b.length) return false; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; }

  const CAP = 64; // small ring to force wraparound easily
  const sabA = makePipe(CAP);
  const sabB = makePipe(CAP);

  const worker = new Worker(fileURLToPath(import.meta.url), { workerData: { sabA, sabB } });

  const pipeA = new Pipe(sabA);
  const pipeB = new Pipe(sabB);

  // Test 1: basic round-trip (worker is blocking on readBytes right now)
  const payload1 = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  await new Promise(r => setTimeout(r, 30)); // let worker block
  pipeA.writeBytes(payload1);
  const echo1 = pipeB.readBytes(1024);
  assert(arrEq(echo1, payload1), 'round-trip mismatch');

  // Test 2: force ring wraparound by pre-advancing head/tail near capacity
  // We already consumed test1; now advance the internal pointers near the end.
  // Write (CAP-4) bytes to fill near end, read them back to advance head/tail.
  const filler = new Uint8Array(CAP - 4);
  for (let i = 0; i < filler.length; i++) filler[i] = 0xAA;
  pipeA.writeBytes(filler);
  // Worker will read these as part of msg2 — no, worker already did its second read attempt.
  // Actually the worker does a second readBytes after echoing the first. So let's feed it.
  // The filler IS the wraparound payload that wraps around the ring end.
  const echo2 = pipeB.readBytes(1024);
  assert(arrEq(echo2, filler), 'wraparound round-trip mismatch');

  // Test 3: deadline timeout on empty pipe
  const emptyPipe = new Pipe(makePipe(64));
  const t0 = Date.now();
  const result = emptyPipe.readBytes(10, 50);
  const elapsed = Date.now() - t0;
  assert(result.length === 0, 'deadline should return empty');
  assert(elapsed >= 40, 'deadline too fast: ' + elapsed + 'ms');

  worker.on('message', () => {
    console.log('PASS');
    process.exit(0);
  });
  worker.on('error', (e) => { console.log('FAIL: worker error: ' + e.message); process.exit(1); });
}

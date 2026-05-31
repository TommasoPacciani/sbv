// poll.test.mjs – tests for poll_oneoff over SAB pipes.
import { Worker, isMainThread, workerData, parentPort } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import { makePipe, Pipe } from '../src/sabpipe.js';
import { PipeFd } from '../src/pipefd.js';
import { installPoll } from '../src/poll.js';

// --- Worker role: write bytes after a delay ---
if (!isMainThread) {
  const { sab, delayMs } = workerData;
  const pipe = new Pipe(sab);
  setTimeout(() => pipe.writeBytes(new TextEncoder().encode('hello')), delayMs);
  // Keep worker alive briefly
  setTimeout(() => process.exit(0), delayMs + 200);
  // Block to prevent exit
  await new Promise(() => {});
}

// --- Helpers ---
const SUB_SIZE = 48;
const EVT_SIZE = 32;

function makeMemory(size) {
  const sab = new SharedArrayBuffer(size);
  return { buffer: sab, view: new DataView(sab), u8: new Uint8Array(sab) };
}

function writeClockSub(view, base, userdata, timeoutNs) {
  view.setBigUint64(base + 0, userdata, true);   // userdata
  view.setUint8(base + 8, 0);                    // tag = EVENTTYPE_CLOCK
  view.setBigUint64(base + 24, timeoutNs, true); // timeout (ns)
  view.setUint16(base + 40, 0, true);            // flags (relative)
}

function writeFdReadSub(view, base, userdata, fd) {
  view.setBigUint64(base + 0, userdata, true);   // userdata
  view.setUint8(base + 8, 1);                    // tag = EVENTTYPE_FD_READ
  view.setUint32(base + 16, fd, true);           // fd
}

function readEvent(view, base) {
  return {
    userdata: view.getBigUint64(base + 0, true),
    error: view.getUint16(base + 8, true),
    type: view.getUint8(base + 10),
    nbytes: view.getBigUint64(base + 16, true),
    flags: view.getUint16(base + 24, true),
  };
}

// --- Test harness ---
let passed = 0, failed = 0;
function assert(cond, msg) {
  if (cond) { passed++; }
  else { failed++; console.log(`  FAIL: ${msg}`); }
}

// --- Test (a): CLOCK-only poll with 50ms timeout ---
{
  console.log('Test (a): CLOCK-only poll ~50ms timeout');
  const mem = makeMemory(1024);
  const inPtr = 0, outPtr = SUB_SIZE * 2, neventsPtr = outPtr + EVT_SIZE * 2;

  writeClockSub(mem.view, inPtr, 42n, BigInt(50e6)); // 50ms in ns

  const fakeWasi = { wasiImport: {}, inst: { exports: { memory: mem } } };
  installPoll(fakeWasi, new Map());

  const t0 = performance.now();
  const ret = fakeWasi.wasiImport.poll_oneoff(inPtr, outPtr, 1, neventsPtr);
  const elapsed = performance.now() - t0;

  assert(ret === 0, `return value should be 0, got ${ret}`);
  const nevents = mem.view.getUint32(neventsPtr, true);
  assert(nevents === 1, `nevents should be 1, got ${nevents}`);
  const evt = readEvent(mem.view, outPtr);
  assert(evt.type === 0, `event type should be CLOCK(0), got ${evt.type}`);
  assert(evt.userdata === 42n, `userdata should be 42, got ${evt.userdata}`);
  assert(evt.error === 0, `error should be 0, got ${evt.error}`);
  assert(elapsed >= 40 && elapsed < 200, `elapsed ~50ms, got ${elapsed.toFixed(1)}ms`);
  console.log(`  elapsed: ${elapsed.toFixed(1)}ms`);
}

// --- Test (b): FD_READ on empty pipe with 50ms timeout -> clock fires ---
{
  console.log('Test (b): FD_READ on empty pipe + 50ms clock timeout');
  const pipeSab = makePipe(256);
  const pipe = new Pipe(pipeSab);
  const pipeFd = new PipeFd(pipe, null);

  const pipesByFd = new Map([[3, pipeFd]]);
  const mem = makeMemory(1024);
  const inPtr = 0, outPtr = SUB_SIZE * 4, neventsPtr = outPtr + EVT_SIZE * 4;

  // Sub 0: FD_READ on fd 3
  writeFdReadSub(mem.view, inPtr, 100n, 3);
  // Sub 1: CLOCK 50ms
  writeClockSub(mem.view, inPtr + SUB_SIZE, 200n, BigInt(50e6));

  const fakeWasi = { wasiImport: {}, inst: { exports: { memory: mem } } };
  installPoll(fakeWasi, pipesByFd);

  const t0 = performance.now();
  const ret = fakeWasi.wasiImport.poll_oneoff(inPtr, outPtr, 2, neventsPtr);
  const elapsed = performance.now() - t0;

  assert(ret === 0, `return value should be 0, got ${ret}`);
  const nevents = mem.view.getUint32(neventsPtr, true);
  assert(nevents === 1, `nevents should be 1 (clock), got ${nevents}`);
  const evt = readEvent(mem.view, outPtr);
  assert(evt.type === 0, `event type should be CLOCK(0), got ${evt.type}`);
  assert(evt.userdata === 200n, `userdata should be 200 (clock sub), got ${evt.userdata}`);
  assert(elapsed >= 40, `should have waited ~50ms, got ${elapsed.toFixed(1)}ms`);
  console.log(`  elapsed: ${elapsed.toFixed(1)}ms (timeout, no data)`);
}

// --- Test (c): FD_READ after data written -> returns immediately ---
{
  console.log('Test (c): FD_READ with data available -> immediate');
  const pipeSab = makePipe(256);
  const pipe = new Pipe(pipeSab);
  const pipeFd = new PipeFd(pipe, null);

  // Write data first
  pipe.writeBytes(new TextEncoder().encode('data'));

  const pipesByFd = new Map([[3, pipeFd]]);
  const mem = makeMemory(1024);
  const inPtr = 0, outPtr = SUB_SIZE * 4, neventsPtr = outPtr + EVT_SIZE * 4;

  writeFdReadSub(mem.view, inPtr, 100n, 3);
  writeClockSub(mem.view, inPtr + SUB_SIZE, 200n, BigInt(500e6)); // 500ms clock (should not fire)

  const fakeWasi = { wasiImport: {}, inst: { exports: { memory: mem } } };
  installPoll(fakeWasi, pipesByFd);

  const t0 = performance.now();
  const ret = fakeWasi.wasiImport.poll_oneoff(inPtr, outPtr, 2, neventsPtr);
  const elapsed = performance.now() - t0;

  assert(ret === 0, `return value should be 0, got ${ret}`);
  const nevents = mem.view.getUint32(neventsPtr, true);
  assert(nevents === 1, `nevents should be 1 (fd_read), got ${nevents}`);
  const evt = readEvent(mem.view, outPtr);
  assert(evt.type === 1, `event type should be FD_READ(1), got ${evt.type}`);
  assert(evt.userdata === 100n, `userdata should be 100, got ${evt.userdata}`);
  assert(evt.nbytes === 4n, `nbytes should be 4, got ${evt.nbytes}`);
  assert(elapsed < 10, `should be immediate (<10ms), got ${elapsed.toFixed(1)}ms`);
  console.log(`  elapsed: ${elapsed.toFixed(1)}ms (immediate)`);
}

// --- Test (d): FD_READ with data arriving mid-poll from another thread ---
{
  console.log('Test (d): FD_READ with data arriving mid-poll from worker');
  const pipeSab = makePipe(256);
  const pipe = new Pipe(pipeSab);
  const pipeFd = new PipeFd(pipe, null);

  // Spawn worker that writes after 30ms
  const worker = new Worker(fileURLToPath(import.meta.url), {
    workerData: { sab: pipeSab, delayMs: 30 }
  });

  const pipesByFd = new Map([[3, pipeFd]]);
  const mem = makeMemory(1024);
  const inPtr = 0, outPtr = SUB_SIZE * 4, neventsPtr = outPtr + EVT_SIZE * 4;

  writeFdReadSub(mem.view, inPtr, 100n, 3);
  writeClockSub(mem.view, inPtr + SUB_SIZE, 200n, BigInt(500e6)); // 500ms clock

  const fakeWasi = { wasiImport: {}, inst: { exports: { memory: mem } } };
  installPoll(fakeWasi, pipesByFd);

  const t0 = performance.now();
  const ret = fakeWasi.wasiImport.poll_oneoff(inPtr, outPtr, 2, neventsPtr);
  const elapsed = performance.now() - t0;

  assert(ret === 0, `return value should be 0, got ${ret}`);
  const nevents = mem.view.getUint32(neventsPtr, true);
  assert(nevents === 1, `nevents should be 1, got ${nevents}`);
  const evt = readEvent(mem.view, outPtr);
  assert(evt.type === 1, `event type should be FD_READ(1), got ${evt.type}`);
  assert(evt.userdata === 100n, `userdata should be 100, got ${evt.userdata}`);
  assert(elapsed >= 25 && elapsed < 200, `should wake ~30ms, got ${elapsed.toFixed(1)}ms`);
  console.log(`  elapsed: ${elapsed.toFixed(1)}ms (woke on data arrival)`);

  await worker.terminate();
}

// --- Summary ---
console.log(`\n${passed + failed} assertions: ${passed} passed, ${failed} failed`);
if (failed > 0) { console.log('FAIL'); process.exit(1); }
else { console.log('PASS'); process.exit(0); }

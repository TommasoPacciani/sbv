// solver-pipe.test.mjs – integration test: main thread (SBV role) drives boolector via SAB pipes.
import { Worker, isMainThread } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { makePipe, Pipe } from '../src/sabpipe.js';

if (!isMainThread) {
  // Worker: import and call runSolver with the message data.
  const { workerData } = await import('node:worker_threads');
  const { runSolver } = await import('../src/solver-worker.js');
  await runSolver(workerData);
  process.exit(0);
}

const repoRoot = path.resolve(fileURLToPath(import.meta.url), '..', '..', '..');
const wasmPath = path.join(repoRoot, 'web', 'solver', 'boolector.wasm');
const args = ['boolector', '--smt2', '-m', '--output-format=smt2', '--no-exit-codes', '--incremental'];

const cmdSab = makePipe();
const respSab = makePipe();
const errSab = makePipe();

const worker = new Worker(fileURLToPath(import.meta.url), {
  workerData: { cmdSab, respSab, errSab, wasmPath, args }
});

const cmdPipe = new Pipe(cmdSab);
const respPipe = new Pipe(respSab);

const enc = new TextEncoder();
const commands = [
  '(set-option :print-success true)',
  '(set-logic QF_BV)',
  '(declare-const x (_ BitVec 8))',
  '(assert (= (bvmul x #x03) #x01))',
  '(check-sat)',
  '(get-value (x))',
  '(exit)',
];

// Write all commands
for (const cmd of commands) {
  cmdPipe.writeBytes(enc.encode(cmd + '\n'));
}

// Read responses until EOF or we have enough
const dec = new TextDecoder();
let buf = '';
const expected = ['success', 'success', 'success', 'success', 'sat', '((x #b10101011))', 'success'];

while (true) {
  const chunk = respPipe.readBytes(4096, 10000);
  if (chunk.length === 0) break;
  buf += dec.decode(chunk);
  const lines = buf.split('\n').map(l => l.trim()).filter(l => l.length > 0);
  if (lines.length >= expected.length) break;
}

const lines = buf.split('\n').map(l => l.trim()).filter(l => l.length > 0);

// Assert
let pass = true;
for (let i = 0; i < expected.length; i++) {
  if (lines[i] !== expected[i]) {
    console.log(`FAIL: line ${i}: expected '${expected[i]}', got '${lines[i]}'`);
    pass = false;
  }
}

if (pass) {
  console.log('PASS');
  process.exit(0);
} else {
  console.log('FAIL: response lines:', lines);
  process.exit(1);
}

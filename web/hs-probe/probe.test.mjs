import { Worker } from 'node:worker_threads';
import { makePipe } from '../src/sabpipe.js';

const cmdSab = makePipe();
const respSab = makePipe();

const echo = new Worker(new URL('./echo-worker.mjs', import.meta.url), { workerData: { cmdSab, respSab } });
const ghc = new Worker(new URL('./ghc-worker.mjs', import.meta.url), { workerData: { cmdSab, respSab } });

const msg = await new Promise((resolve) => ghc.on('message', resolve));
await echo.terminate(); await ghc.terminate();

if (msg.ok && msg.result === 'GOT:hello-from-haskell') {
  console.log('PASS', JSON.stringify(msg.result));
  process.exit(0);
} else {
  console.log('FAIL', JSON.stringify(msg));
  process.exit(1);
}

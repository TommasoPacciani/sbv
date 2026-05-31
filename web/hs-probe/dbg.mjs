import { Worker } from 'node:worker_threads';
import { makePipe } from '../src/sabpipe.js';
const cmdSab = makePipe(), respSab = makePipe();
new Worker(new URL('./echo-worker.mjs', import.meta.url), { workerData:{cmdSab,respSab} });
const ghc = new Worker(new URL('./ghc-worker.mjs', import.meta.url), { workerData:{cmdSab,respSab} });
ghc.on('message', m => { console.log('MSG:', JSON.stringify(m)); process.exit(0); });
setTimeout(()=>{console.log('TIMEOUT (likely blocked in hGetLine)');process.exit(2);}, 8000);

import { workerData } from 'node:worker_threads';
import { Pipe } from '../src/sabpipe.js';

const cmd = new Pipe(workerData.cmdSab);    // read end
const resp = new Pipe(workerData.respSab);  // write end
for (;;) {
  const b = cmd.readBytes(4096);            // blocks on Atomics.wait
  if (b.length === 0) break;                // closed
  resp.writeBytes(b);                       // echo verbatim (incl. newline)
}

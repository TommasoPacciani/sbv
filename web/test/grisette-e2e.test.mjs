// Runs the real Grisette example (language def + verify + synthesize) end-to-end:
// Grisette -> pristine SBV native engine -> in-browser z3 (emscripten) over SAB pipes.
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const webDir = path.dirname(fileURLToPath(new URL('../solver/z3.js', import.meta.url)));
const emscriptenWorkerPath = fileURLToPath(new URL('../src/emscripten-cli-worker.js', import.meta.url));
const emscriptenSolvers = { z3: { moduleUrl: 'file://' + path.join(webDir, 'z3.js'), args: ['-smt2', '-in'] } };
const basename = (p) => p.split('/').pop();
let out = '';

const g = new Worker(new URL('./grisette-node-worker.mjs', import.meta.url));
g.on('error', (e) => { console.log('[worker error]', String(e && e.message || e)); });
const finished = new Promise((resolve) => {
  g.on('message', (m) => {
    if (m.type === 'stdout') { out += m.line + '\n'; console.log('[grisette]', m.line); }
    else if (m.type === 'stderr') console.error('[stderr]', m.line);
    else if (m.type === 'spawnSolver') {
      const emDef = emscriptenSolvers[basename(m.exe)];
      if (emDef) new Worker(emscriptenWorkerPath, {
        workerData: { moduleUrl: emDef.moduleUrl, args: emDef.args, cmdSab: m.cmdSab, respSab: m.respSab, errSab: m.errSab },
      });
    } else if (m.type === 'done') resolve('done');
    else if (m.type === 'error') { console.log('ERROR:', m.error); resolve('error'); }
  });
});

const why = await Promise.race([finished, new Promise((r) => setTimeout(() => r('timeout'), 180000))]);
await g.terminate();
const ok = /equivalent/.test(out);
console.log(ok ? `\nVERIFY OK (${why})` : `\nVERIFY FAIL (${why})`);
process.exit(ok ? 0 : 1);

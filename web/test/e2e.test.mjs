// End-to-end: runs the exact browser code path headless. A broker spawns the SBV
// worker (pristine SBV native engine, command mode) and, on its solver-spawn
// requests, a solver worker bound to the same SAB pipes running boolector.wasm.
// Asserts SBV produced correct results through the in-browser solver "process".
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const wasmPath = fileURLToPath(new URL('../solver/boolector.wasm', import.meta.url));
const webDir = path.dirname(fileURLToPath(new URL('../solver/boolector.wasm', import.meta.url)));
const emscriptenWorkerPath = fileURLToPath(new URL('../src/emscripten-cli-worker.js', import.meta.url));
const emscriptenSolvers = {
  z3: { moduleUrl: 'file://' + path.join(webDir, 'z3.js'), args: ['-smt2', '-in'] },
};
const basename = (p) => p.split('/').pop();
let out = '';

const sbv = new Worker(new URL('./sbv-node-worker.mjs', import.meta.url));
const finished = new Promise((resolve) => {
  sbv.on('message', (m) => {
    if (m.type === 'stdout') { out += m.line + '\n'; console.log('[sbv]', m.line); }
    else if (m.type === 'spawnSolver') {
      const name = basename(m.exe);
      const emDef = emscriptenSolvers[name];
      if (emDef) {
        new Worker(emscriptenWorkerPath, {
          workerData: { moduleUrl: emDef.moduleUrl, args: emDef.args, cmdSab: m.cmdSab, respSab: m.respSab, errSab: m.errSab },
        });
      } else {
        const args = [name, ...m.args.split('\n').filter(Boolean)];
        new Worker(new URL('./solver-node-worker.mjs', import.meta.url),
          { workerData: { cmdSab: m.cmdSab, respSab: m.respSab, errSab: m.errSab, wasmPath, args } });
      }
    } else if (m.type === 'done') resolve('done');
    else if (m.type === 'error') { console.log('SBV ERROR:', m.error); resolve('error'); }
  });
});

const why = await Promise.race([finished, new Promise((r) => setTimeout(() => r('timeout'), 120000))]);
await sbv.terminate();

const ok = /Satisfiable/.test(out) && /Q\.E\.D\./.test(out);
console.log(ok && why === 'done' ? '\nPASS' : `\nFAIL (${why})`);
process.exit(ok && why === 'done' ? 0 : 1);

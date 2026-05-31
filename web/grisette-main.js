// grisette-main.js — broker for the Grisette page. Identical to main.js except
// it starts grisette-worker.js. Routes the solver "process" spawn requests:
// z3 -> emscripten-cli worker (full theories), others -> WASI solver worker.
const wasiSolvers = { boolector: new URL('./solver/boolector.wasm', import.meta.url).href };
const emscriptenSolvers = {
  z3:   { module: new URL('./solver/z3.js',   import.meta.url).href, args: ['-smt2', '-in'] },
  cvc5: { module: new URL('./solver/cvc5.js', import.meta.url).href, args: ['--lang', 'smt2', '--incremental', '-'] },
};
const basename = (p) => p.split('/').pop();
const out = document.getElementById('out');
const log = (s) => { out.textContent += s + '\n'; };

const sbv = new Worker(new URL('./src/grisette-worker.js', import.meta.url), { type: 'module' });

sbv.onmessage = (ev) => {
  const m = ev.data;
  switch (m.type) {
    case 'stdout': log(m.line); break;
    case 'stderr': console.warn('[grisette stderr]', m.line); break;
    case 'spawnSolver': {
      const name = basename(m.exe);
      const emDef = emscriptenSolvers[name];
      if (emDef) {
        const sw = new Worker(new URL('./src/emscripten-cli-worker.js', import.meta.url), { type: 'module' });
        sw.postMessage({ module: emDef.module, args: emDef.args, cmdSab: m.cmdSab, respSab: m.respSab, errSab: m.errSab });
      } else {
        const args = [name, ...m.args.split('\n').filter(Boolean)];
        const sw = new Worker(new URL('./src/solver-worker.js', import.meta.url), { type: 'module' });
        sw.postMessage({ cmdSab: m.cmdSab, respSab: m.respSab, errSab: m.errSab, wasmPath: wasiSolvers[name], args });
      }
      break;
    }
    case 'done': log('\n[done]'); break;
    case 'error': log('\nERROR: ' + m.error); break;
  }
};

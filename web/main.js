// main.js — page broker. Starts the SBV worker, relays its solver-spawn
// requests by creating a solver worker bound to the same SAB pipes, and prints
// SBV's stdout. The broker only does postMessage/Worker creation (never blocks),
// so Atomics.wait stays confined to the workers.
const exeMap = { boolector: new URL('./solver/boolector.wasm', import.meta.url).href };
const basename = (p) => p.split('/').pop();
const out = document.getElementById('out');
const log = (s) => { out.textContent += s + '\n'; };

const sbv = new Worker(new URL('./src/sbv-worker.js', import.meta.url), { type: 'module' });

sbv.onmessage = (ev) => {
  const m = ev.data;
  switch (m.type) {
    case 'stdout': log(m.line); break;
    case 'stderr': console.warn('[sbv stderr]', m.line); break;
    case 'spawnSolver': {
      const name = basename(m.exe);
      const args = [name, ...m.args.split('\n').filter(Boolean)];
      const sw = new Worker(new URL('./src/solver-worker.js', import.meta.url), { type: 'module' });
      sw.postMessage({ cmdSab: m.cmdSab, respSab: m.respSab, errSab: m.errSab, wasmPath: exeMap[name], args });
      break;
    }
    case 'done': log('\n[done]'); break;
    case 'error': log('\nERROR: ' + m.error); break;
  }
};

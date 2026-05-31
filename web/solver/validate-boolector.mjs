// Proof that the prebuilt yowasp boolector.wasm runs under a standard preview1
// WASI runtime and speaks SBV's stdin incremental SMT-LIB2 protocol
// (:print-success + check-sat + get-value). This is the exact contract the
// browser path must satisfy; node:wasi stands in for browser_wasi_shim here.
//
//   node --experimental-wasi-unstable-preview1 validate-boolector.mjs
import { WASI } from 'node:wasi';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const wasmPath = fileURLToPath(new URL('./boolector.wasm', import.meta.url));
const wasi = new WASI({
  version: 'preview1',
  args: ['boolector', '--smt2', '-i', '-m'],   // incremental SMT-LIB2 on stdin, models on
  env: {}, preopens: {},
});
const mod = await WebAssembly.compile(readFileSync(wasmPath));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
process.exitCode = wasi.start(inst);
// Feed SBV-style commands on stdin, e.g.:
//   printf '(set-option :print-success true)\n(set-logic QF_BV)\n
//   (declare-const x (_ BitVec 8))\n(assert (= (bvmul x #x03) #x01))\n
//   (check-sat)\n(get-value (x))\n(exit)\n' | node --experimental-wasi-unstable-preview1 validate-boolector.mjs
// Expected: success x4, sat, ((x #b10101011)), success

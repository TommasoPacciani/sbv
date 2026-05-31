// ---------------------------------------------------------------------------
// sbvZ3Wasm.js
//
// JavaScript glue between SBV's WebAssembly solver bridge
// (Data.SBV.SMT.WasmBridge) and the official Microsoft Z3 WebAssembly build
// distributed as the `z3-solver` npm package.
//
// The Haskell `foreign import javascript` declarations in WasmBridge read these
// symbols from `globalThis`:
//
//   sbvZ3Wasm.init()    : Promise<handle>   -- load + initialize Z3 once
//   handle.send(cmd)    : Promise<string>   -- one SMT-LIB2 command in, one
//                                              complete response string out
//   handle.release()    : void              -- release the Z3 context
//
// The key enabler is the low-level API call `Z3.eval_smtlib2_string(ctx, str)`,
// which evaluates a full SMT-LIB2 script on a context and returns the solver's
// textual output (honoring `(set-option :print-success true)`).
//
// THREADING NOTE (why we replay instead of reusing one context): in z3-solver
// `eval_smtlib2_string` is dispatched onto a Z3 *worker pthread*
// (`Mod.async_call(... 'async_Z3_eval_smtlib2_string' ...)`), whereas
// `mk_context` runs on the main thread. Reusing one long-lived context across
// many separate threaded `eval` calls corrupts Z3's per-thread allocator and
// crashes inside the parser (`cmd_context::find_cmd`, "index out of bounds").
// So instead each `send` re-evaluates the *entire accumulated command stream*
// on a brand-new context (created and destroyed within that one call) and
// returns only the newly appended output. Because the script is only ever
// extended, Z3's output grows append-only and deterministically, so the delta
// is exactly what a fresh `z3 -in` process would print after that command --
// i.e. byte-identical to native behavior. The cost is O(n) re-evaluation per
// command; fine for typical SBV sessions.
//
// Error markers: init() rejects with an Error whose text carries
// `SBV_WASM_LOAD_ERROR` (module failed to load) or `SBV_WASM_INIT_ERROR`
// (loaded but context creation failed). WasmBridge.classifyInitFailure keys off
// these markers to distinguish the loading phase (Requirement 13.1) from the
// initialization phase (Requirement 13.2).
// ---------------------------------------------------------------------------

// z3-solver's browser build is CommonJS. Depending on vite's CJS interop, `init`
// may surface as a named export or under `default`; a namespace import covers all.
import * as z3Pkg from 'z3-solver';
const initZ3 = z3Pkg.init || (z3Pkg.default && (z3Pkg.default.init || z3Pkg.default));

globalThis.sbvZ3Wasm = {
  // Load and initialize Z3 exactly once. WasmBridge.acquireSolver guarantees a
  // single in-flight call via its NotLoaded -> Loading -> Ready/Failed state
  // machine, so this need not itself be idempotent.
  async init() {
    let Z3;
    try {
      // initZ3() instantiates the z3-solver WebAssembly module; the returned
      // `Z3` object is the low-level (C-like) API.
      ({ Z3 } = await initZ3());
    } catch (e) {
      console.error('[sbvZ3Wasm] z3-solver init() failed. crossOriginIsolated =',
                    globalThis.crossOriginIsolated, '| SharedArrayBuffer =',
                    typeof SharedArrayBuffer, '| error:', e);
      throw new Error('SBV_WASM_LOAD_ERROR: ' + errText(e));
    }

    // Smoke-test that we can create and destroy a context, so init failures
    // surface here (Requirement 13.2) rather than on the first send.
    try {
      const cfg = Z3.mk_config();
      Z3.del_context(Z3.mk_context(cfg));
      Z3.del_config(cfg);
    } catch (e) {
      throw new Error('SBV_WASM_INIT_ERROR: ' + errText(e));
    }

    // Accumulated SMT-LIB2 command stream and the full output it produced last
    // time, so each send returns just the newly appended response.
    let script = [];
    let prevOut = '';

    return {
      // Submit one complete SMT-LIB2 command and return the response Z3 emits
      // for it. We append the command, re-evaluate the whole script on a fresh
      // context (avoiding cross-thread context reuse, see THREADING NOTE), and
      // return the suffix of the output beyond what the previous commands had
      // already produced.
      async send(cmd) {
        script.push(cmd);
        const full = script.join('\n');
        const cfg = Z3.mk_config();
        const ctx = Z3.mk_context(cfg);
        Z3.del_config(cfg);
        let out;
        try {
          out = await Z3.eval_smtlib2_string(ctx, full);
        } finally {
          try { Z3.del_context(ctx); } catch (_) { /* ignore */ }
        }
        const delta = out.slice(prevOut.length);
        prevOut = out;
        if (out.indexOf('(error') !== -1) {
          const numbered = full.split('\n').map((l, i) => (i + 1) + ': ' + l).join('\n');
          console.error('[sbvZ3Wasm] z3 returned an error. Cumulative script:\n' + numbered +
                        '\n[sbvZ3Wasm] full output:\n' + out);
        }
        return delta.trim();
      },

      // End the logical session: drop the accumulated script so a subsequent
      // solver run on the same handle starts clean. Idempotent and non-throwing.
      release() {
        script = [];
        prevOut = '';
      },
    };
  },
};

function errText(e) {
  return e && e.message ? e.message : String(e);
}

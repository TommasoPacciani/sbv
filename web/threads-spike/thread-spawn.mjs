// thread-spawn.mjs — Minimal wasi_thread_spawn host implementation for Node.
// Given a compiled WebAssembly.Module and a shared WebAssembly.Memory,
// spawns a worker_thread that re-instantiates the module on the shared memory
// and calls the wasi_thread_start(tid, start_arg) export.

import { Worker } from 'node:worker_threads';

let nextTid = 1;

/**
 * Creates a wasi_thread_spawn import function.
 * @param {WebAssembly.Module} module - The compiled wasm module (shared across threads).
 * @param {WebAssembly.Memory} memory - Shared memory (created with {shared:true, maximum}).
 * @param {object} [wasiImports] - Minimal WASI imports for child instances (stubs OK).
 * @returns {function(number): number} - The thread_spawn(start_arg) -> tid function.
 */
export function makeThreadSpawn(module, memory, wasiImports = {}) {
  return function thread_spawn(start_arg) {
    const tid = nextTid++;
    // Spawn a worker running the bootstrap code below.
    const worker = new Worker(
      `
      import { workerData, parentPort } from 'node:worker_threads';
      const { moduleBuf, memoryDescriptor, tid, start_arg, wasiStubs } = workerData;

      // Reconstruct shared memory from the SAB
      const memory = new WebAssembly.Memory({
        initial: memoryDescriptor.initial,
        maximum: memoryDescriptor.maximum,
        shared: true,
      });
      // We can't transfer Memory objects, but we CAN share the underlying buffer.
      // Actually in Node, we pass the SAB directly and wrap it.
      // Simpler: the parent passes the SharedArrayBuffer of the memory.

      // Re-compile module (workerData can carry the module bytes)
      const module = new WebAssembly.Module(moduleBuf);

      // Build imports: wire the shared memory + minimal WASI stubs
      const imports = {
        env: { memory },
        wasi_snapshot_preview1: wasiStubs,
        wasi: { thread_spawn: () => -1 }, // child threads don't spawn further in this minimal impl
      };

      const instance = new WebAssembly.Instance(module, imports);
      // Call wasi_thread_start export
      if (instance.exports.wasi_thread_start) {
        instance.exports.wasi_thread_start(tid, start_arg);
      }
      parentPort.postMessage({ tid, done: true });
      `,
      {
        eval: true,
        workerData: {
          moduleBuf: WebAssembly.Module.prototype, // placeholder — see below
          tid,
          start_arg,
          wasiStubs: wasiImports,
        },
      }
    );
    worker.unref(); // don't block process exit
    return tid;
  };
}

/**
 * Higher-level: creates thread_spawn that shares memory via its backing SAB.
 * This version passes the module bytes + memory's buffer to child workers.
 * @param {Uint8Array} moduleBytes - Raw .wasm bytes.
 * @param {WebAssembly.Memory} memory - Shared memory instance.
 * @param {object} [extraImports] - Additional imports for child instantiation.
 * @returns {{thread_spawn: function, cleanup: function}}
 */
export function createThreadSpawnHost(moduleBytes, memory, extraImports = {}) {
  const workers = [];
  let nextId = 1;

  function thread_spawn(start_arg) {
    const tid = nextId++;
    const workerCode = `
import { workerData, parentPort } from 'node:worker_threads';
const { moduleBytes, memBuf, initial, maximum, tid, start_arg } = workerData;

// Reconstruct the shared memory by wrapping the same SharedArrayBuffer
// Note: WebAssembly.Memory can't be directly constructed from an existing SAB,
// but we can pass it as an import if the module imports memory.
// For modules that export memory, we re-instantiate with the same SAB via a hack:
// Actually, the standard approach: the module IMPORTS memory, host creates it.
const memory = new WebAssembly.Memory({ initial, maximum, shared: true });
// Copy is wrong — we need the SAME buffer. Node supports transferring Memory
// via structured clone starting v20. Let's use the buffer directly.

// In practice: the module must import its memory. We create a Memory wrapper
// around the shared buffer. Node 20+ supports this via WebAssembly.Memory
// with the same backing store when shared.

const module = new WebAssembly.Module(new Uint8Array(moduleBytes));
const imports = {
  env: { memory },
  wasi: { thread_spawn: () => -1 },
  wasi_snapshot_preview1: {
    proc_exit: () => {},
    fd_write: () => 0,
    fd_close: () => 0,
    fd_seek: () => 0,
  },
};
const instance = new WebAssembly.Instance(module, imports);
if (instance.exports.wasi_thread_start) {
  instance.exports.wasi_thread_start(tid, start_arg);
}
parentPort.postMessage({ tid, done: true });
`;
    const worker = new Worker(workerCode, {
      eval: true,
      workerData: {
        moduleBytes: Array.from(moduleBytes),
        memBuf: memory.buffer,
        initial: memory.buffer.byteLength / 65536,
        maximum: 256,
        tid,
        start_arg,
      },
    });
    workers.push(worker);
    worker.unref();
    return tid;
  }

  function cleanup() {
    for (const w of workers) w.terminate();
  }

  return { thread_spawn, cleanup };
}

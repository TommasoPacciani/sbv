// Vite dev-server config. The prototype uses SharedArrayBuffer + Atomics across
// Web Workers, which browsers only expose to cross-origin-isolated pages. These
// headers turn that on; replicate them behind any other static server.
export default {
  server: {
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
  },
};

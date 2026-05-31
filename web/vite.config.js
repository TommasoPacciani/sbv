// Vite dev-server config. z3-solver's build uses SharedArrayBuffer (threads),
// which browsers only expose to cross-origin-isolated pages. These headers turn
// that on. They are also what you must replicate behind any other static server.
export default {
  server: {
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
  },
  // Let vite pre-bundle z3-solver (it's CommonJS) so the default import resolves.
  optimizeDeps: { include: ['z3-solver'] },
};

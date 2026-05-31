#!/usr/bin/env bash
# Fetch the prebuilt wasm32-wasi Boolector SMT solver from YoWASP (maintained by
# whitequark, FOSSi Foundation). No build, no fork: we consume their published
# wasm command as-is. Reproduces web/solver/boolector.wasm.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
pip download yowasp-boolector --no-deps -d "$TMP"
WHL="$(ls "$TMP"/*.whl | head -1)"
unzip -o -q "$WHL" -d "$TMP/x"
cp "$(find "$TMP/x" -name boolector.wasm | head -1)" "$HERE/boolector.wasm"
echo "OK: $HERE/boolector.wasm  (from $(basename "$WHL"))"

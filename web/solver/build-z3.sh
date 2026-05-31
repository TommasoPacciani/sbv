#!/usr/bin/env bash
# Reproducible build: z3 -> single-threaded emscripten WASM (ES6 module)
# Produces z3.js + z3.wasm for use as an SMT2 stdin/stdout CLI in the browser.
set -euo pipefail

EMSDK_VER="3.1.74"
Z3_TAG="z3-4.13.4"
SCRATCH="${SCRATCH:-$HOME/sbvw-build}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. emsdk (reuse if present)
if [ ! -d "$SCRATCH/emsdk" ]; then
  git clone https://github.com/emscripten-core/emsdk.git "$SCRATCH/emsdk"
fi
cd "$SCRATCH/emsdk"
./emsdk install "$EMSDK_VER"
./emsdk activate "$EMSDK_VER"
source ./emsdk_env.sh

# 2. z3 source
rm -rf "$SCRATCH/z3"
git clone --depth 1 -b "$Z3_TAG" https://github.com/Z3Prover/z3 "$SCRATCH/z3"

# 3. Patch: remove z3's default DISABLE_EXCEPTION_CATCHING (incompatible with -fwasm-exceptions)
sed -i 's/"-s DISABLE_EXCEPTION_CATCHING=0"//' "$SCRATCH/z3/CMakeLists.txt"

# 4. Configure + build (single-threaded, ES6 module, wasm exceptions, no shared lib)
emcmake cmake -B "$SCRATCH/z3/build" -S "$SCRATCH/z3" \
  -DCMAKE_BUILD_TYPE=Release \
  -DZ3_SINGLE_THREADED=ON \
  -DZ3_BUILD_LIBZ3_SHARED=OFF \
  -DZ3_BUILD_EXECUTABLE=ON \
  -DCMAKE_CXX_FLAGS="-fwasm-exceptions" \
  -DCMAKE_C_FLAGS="-fwasm-exceptions" \
  -DCMAKE_EXE_LINKER_FLAGS="-fwasm-exceptions -sMODULARIZE=1 -sEXPORT_ES6=1 -sALLOW_MEMORY_GROWTH=1 -sEXIT_RUNTIME=1 -sINVOKE_RUN=0 -sFORCE_FILESYSTEM=1 -sEXPORTED_RUNTIME_METHODS=callMain,FS -sSTACK_SIZE=8388608"

cmake --build "$SCRATCH/z3/build" -j"$(nproc)" --target shell

# 5. Verify single-threaded (no worker file)
if ls "$SCRATCH/z3/build/z3.worker"* 2>/dev/null; then
  echo "ERROR: pthread worker detected — build is NOT single-threaded" >&2
  exit 1
fi

# 6. Install
cp "$SCRATCH/z3/build/z3.js"   "$SCRIPT_DIR/z3.js"
cp "$SCRATCH/z3/build/z3.wasm" "$SCRIPT_DIR/z3.wasm"

# 7. Clean up source (keep emsdk for cvc5)
rm -rf "$SCRATCH/z3"

echo "Done: $SCRIPT_DIR/z3.js + z3.wasm ($(du -h "$SCRIPT_DIR/z3.wasm" | cut -f1))"

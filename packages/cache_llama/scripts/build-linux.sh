#!/usr/bin/env bash
# Builds libcache_llama.so (llama.cpp at the pinned submodule commit plus cl_embed and the chat engine) for Linux on the machine it
# runs on (x86_64 or aarch64; no cross-compiling), the same way for the Cache for Linux tarball and for the native-libs workflow.
#
# Usage: build-linux.sh <build-dir>
# Result: <build-dir>/libcache_llama.so, stripped, with libstdc++ and libgcc linked in so it needs nothing but libc.
# x86_64 is built with AVX2/FMA/F16C; aarch64 at the baseline Armv8-A so it runs on a Raspberry Pi 4.
# The script fails if an exported cl_embed symbol is missing. The glibc requirement is checked by the caller (run it in an
# ubuntu:22.04 container so the library needs glibc 2.35 or older).
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <build-dir>" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../src"
build="$1"
[ -f "$here/../third_party/llama.cpp/CMakeLists.txt" ] || { echo "llama.cpp submodule is not checked out (git submodule update --init packages/cache_llama/third_party/llama.cpp)" >&2; exit 1; }

avx2=""
if [ "$(uname -m)" = "x86_64" ]; then avx2="-DCACHE_LLAMA_X86_AVX2=ON"; fi
# libstdc++ and libgcc are linked in, so the installed library needs nothing but libc.
cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release $avx2 \
  -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc"
cmake --build "$build" --target cache_llama -j "$(nproc)"
strip --strip-unneeded "$build/libcache_llama.so"

ls -l "$build/libcache_llama.so"
ldd "$build/libcache_llama.so" || true
# (the output is read whole: grep -q ending a pipe early would fail the script under pipefail)
symbols=$(nm -D --defined-only "$build/libcache_llama.so")
for s in cl_embed_load cl_embed_info cl_embed cl_embed_free; do
  grep -q " T $s\$" <<< "$symbols" || { echo "libcache_llama.so has no $s" >&2; exit 1; }
done
echo "max glibc: $(objdump -T "$build/libcache_llama.so" | grep -o 'GLIBC_[0-9][0-9.]*' | sort -V | tail -n 1)"

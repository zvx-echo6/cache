#!/bin/sh
# Builds llama.cpp (with Metal) and the Cache chat engine as ONE static library for iPhone (arm64, device only):
# ios/native/libcache_llama_all.a, which cache_llama.podspec links into the app.
# Needs Xcode and CMake on a Mac. Usage: build-native.sh [build-dir]   (default: ios/native/build)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
build=${1:-$here/native/build}
out=$here/native
mkdir -p "$build" "$out"
cmake -S "$here/../src" -B "$build" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO
cmake --build "$build" --config Release --target cache_llama -j "$(sysctl -n hw.ncpu)"
# cache_llama is a static library that does not carry its dependencies: merge them all into one archive.
libs=$(find "$build" -name '*.a' ! -name 'libcache_llama_all.a')
echo "$libs"
# shellcheck disable=SC2086
libtool -static -o "$out/libcache_llama_all.a" $libs
ls -l "$out/libcache_llama_all.a"

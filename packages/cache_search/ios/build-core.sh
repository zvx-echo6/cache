#!/bin/sh
# Builds the Rust search core for iPhone (aarch64-apple-ios, device only) as a static library: ios/native/libcache_search.a, and
# unpacks Kiwix's CoreKiwix.xcframework (libzim + Xapian + ICU incl. data, static) next to it as ios/native/libCoreKiwix.a.
# cache_search.podspec links both into the app. Needs Xcode and a Rust toolchain with the aarch64-apple-ios target on a Mac.
# Usage: build-core.sh <libzim-build-dir>   (outside the repository; the xcframework download is kept there)
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <libzim-build-dir>" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
out=$here/native
mkdir -p "$out"
slice=$("$here/../native/zimx/fetch-libzim-ios.sh" "$1" | sed -n 's/^LIBZIM_DIR=//p')
[ -f "$slice/merged.a" ] || { echo "no merged.a in $slice" >&2; exit 1; }
cp "$slice/merged.a" "$out/libCoreKiwix.a"
export LIBZIM_DIR=$slice
export IPHONEOS_DEPLOYMENT_TARGET=16.0
cd "$here/../native"
# --crate-type staticlib: only the static library (the crate also declares a cdylib, which cannot be linked for iOS without libzim).
cargo rustc --release --lib --crate-type staticlib --target aarch64-apple-ios -p cache_search
cp target/aarch64-apple-ios/release/libcache_search.a "$out/libcache_search.a"
ls -l "$out"

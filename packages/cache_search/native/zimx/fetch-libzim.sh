#!/bin/sh
# Download the official prebuilt libzim for Android arm64 into the build directory, verify its md5, unpack it.
# Never writes into the repository. Usage: fetch-libzim.sh <build-dir>
# Versions, URLs and md5s are recorded in LIBZIM.md; keep the two in step.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <build-dir>" >&2; exit 2; }
ver=9.8.2-1
name="libzim_android-arm64-$ver.tar.gz"
url="https://download.openzim.org/release/libzim/$name"
md5=59a6b769847b77dc0ace69c3b9727445
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
mkdir -p "$1"
root=$(cd "$1" && pwd)
case "$root/" in "$repo"/*) echo "build dir must be outside the repository ($repo)" >&2; exit 2;; esac
base="$root/libzim"
mkdir -p "$base"
tgz="$base/$name"
dest="$base/android-arm64-$ver"
ok() { [ -f "$tgz" ] && [ "$(md5sum "$tgz" | cut -d' ' -f1)" = "$md5" ]; }
if ! ok; then
  curl -fsSL -o "$tgz" "$url"
  ok || { rm -f "$tgz"; echo "md5 mismatch for $name (want $md5)" >&2; exit 1; }
fi
if [ ! -f "$dest/lib/aarch64-linux-android/libzim.so" ]; then
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
fi
[ -f "$dest/lib/aarch64-linux-android/libzim.so" ] || { echo "libzim.so missing in $dest" >&2; exit 1; }
echo "md5 ok: $name"
echo "LIBZIM_DIR=$dest"

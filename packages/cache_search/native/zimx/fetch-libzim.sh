#!/bin/sh
# Download the official prebuilt libzim for Android (arm64 by default; x86_64 for the emulator test build) into the build directory,
# verify its md5, unpack it. Never writes into the repository. Usage: fetch-libzim.sh <build-dir> [arm64|x86_64]
# Versions, URLs and md5s are recorded in LIBZIM.md; keep the two in step.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 <build-dir> [arm64|x86_64]" >&2; exit 2; }
arch=${2:-arm64}
ver=9.8.2-1
case "$arch" in
  arm64) md5=59a6b769847b77dc0ace69c3b9727445; triple=aarch64-linux-android ;;
  x86_64) md5=deabcd642324cf4dfd9f380b76f1ae5a; triple=x86_64-linux-android ;;
  *) echo "unknown arch $arch (arm64 or x86_64)" >&2; exit 2 ;;
esac
name="libzim_android-$arch-$ver.tar.gz"
url="https://download.openzim.org/release/libzim/$name"
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
mkdir -p "$1"
root=$(cd "$1" && pwd)
case "$root/" in "$repo"/*) echo "build dir must be outside the repository ($repo)" >&2; exit 2;; esac
base="$root/libzim"
mkdir -p "$base"
tgz="$base/$name"
dest="$base/android-$arch-$ver"
ok() { [ -f "$tgz" ] && [ "$(md5sum "$tgz" | cut -d' ' -f1)" = "$md5" ]; }
if ! ok; then
  # download.openzim.org drops long transfers (2026-11-10), so resume (-C -) across up to 40 tries over HTTP/1.1.
  curl -fsSL --http1.1 -C - --retry 40 --retry-delay 5 --retry-all-errors -o "$tgz" "$url"
  ok || { rm -f "$tgz"; echo "md5 mismatch for $name (want $md5)" >&2; exit 1; }
fi
if [ ! -f "$dest/lib/$triple/libzim.so" ]; then
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
fi
[ -f "$dest/lib/$triple/libzim.so" ] || { echo "libzim.so missing in $dest" >&2; exit 1; }
echo "md5 ok: $name"
echo "LIBZIM_DIR=$dest"

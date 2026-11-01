#!/usr/bin/env bash
# Download Kiwix's official prebuilt libzim for Linux (x86_64 or aarch64, glibc build) into the build directory, verify it, unpack it.
# Never writes into the repository. Usage: fetch-libzim-linux.sh <build-dir> [x86_64|aarch64]   (default: this machine's architecture)
# Versions, URLs and sums are recorded in LIBZIM.md; keep the two in step. Prints the LIBZIM_DIR to use.
# The prebuilt needs glibc 2.34 (x86_64) or 2.29 (aarch64) and GCC 12's libstdc++ (GLIBCXX_3.4.30): Ubuntu 22.04+, Debian 12+,
# Raspberry Pi OS bookworm+. ICU (with its data) and Xapian are inside libzim.so; it needs no other library.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <build-dir> [x86_64|aarch64]" >&2; exit 2; }
arch="${2:-$(uname -m)}"
ver=9.8.2-1
case "$arch" in
  x86_64)        sha256=6dc2d70cbe0e8d584ab70b489f82429dd9a6e9d509ea96b5a0c8da0fea0d7bbe; md5=32099d4f377645ba8723e69359a4aa14 ;;
  aarch64|arm64) arch=aarch64
                 sha256=a5bb8ffbb92e93302f49fcfeb2f01545234eee08127b4daff9e504d8abe1be7d; md5=50cdc6d48c6cb95d613a39728d2248d3 ;;
  *) echo "no libzim prebuilt for $arch" >&2; exit 2 ;;
esac
name="libzim_linux-$arch-$ver.tar.gz"
url="https://download.openzim.org/release/libzim/$name"
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
mkdir -p "$1"
root=$(cd "$1" && pwd)
case "$root/" in "$repo"/*) echo "build dir must be outside the repository ($repo)" >&2; exit 2;; esac
base="$root/libzim"
mkdir -p "$base"
tgz="$base/$name"
dest="$base/linux-$arch-$ver"
ok() { [ -f "$tgz" ] && [ "$(sha256sum "$tgz" | cut -d' ' -f1)" = "$sha256" ] && [ "$(md5sum "$tgz" | cut -d' ' -f1)" = "$md5" ]; }
if ! ok; then
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$tgz" "$url"
  ok || { rm -f "$tgz"; echo "checksum mismatch for $name (want sha256 $sha256, md5 $md5)" >&2; exit 1; }
fi
if ! ls "$dest"/lib/*/libzim.so >/dev/null 2>&1; then
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
fi
ls "$dest"/lib/*/libzim.so >/dev/null 2>&1 || { echo "libzim.so missing in $dest" >&2; exit 1; }
[ -f "$dest/include/zim/archive.h" ] || { echo "include/zim/archive.h missing in $dest" >&2; exit 1; }
echo "sha256 and md5 ok: $name" >&2
echo "LIBZIM_DIR=$dest"

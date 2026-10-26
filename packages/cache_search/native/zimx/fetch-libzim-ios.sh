#!/bin/sh
# Download Kiwix's official CoreKiwix.xcframework (libkiwix + libzim with Xapian + ICU incl. its data, all static) and unpack it.
# Used for the iPhone build; only the ios-arm64 slice is used. Verifies the md5 Kiwix publishes next to the file and the sha256
# recorded here. Never writes into the repository. Usage: fetch-libzim-ios.sh <build-dir>
# Version, URL and checksums are recorded in LIBZIM.md; keep the two in step.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <build-dir>" >&2; exit 2; }
ver=14.2.1-2
name="libkiwix_xcframework-$ver.tar.gz"
url="https://download.kiwix.org/release/libkiwix/$name"
md5=78c0398d14228d11d2caf2c888314d04
sha256=14820648788dddc3df8a89ff0820af60d7efc1cfda6c83602989455263ee1561
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
mkdir -p "$1"
root=$(cd "$1" && pwd)
case "$root/" in "$repo"/*) echo "build dir must be outside the repository ($repo)" >&2; exit 2;; esac
base="$root/libzim"
mkdir -p "$base"
tgz="$base/$name"
dest="$base/ios-arm64-$ver"
hash256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
hash5() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
ok() { [ -f "$tgz" ] && [ "$(hash5 "$tgz")" = "$md5" ] && [ "$(hash256 "$tgz")" = "$sha256" ]; }
if ! ok; then
  curl -fsSL -o "$tgz" "$url"
  ok || { rm -f "$tgz"; echo "checksum mismatch for $name (want md5 $md5, sha256 $sha256)" >&2; exit 1; }
fi
slice="$dest/lib/CoreKiwix.xcframework/ios-arm64"
if [ ! -f "$slice/merged.a" ]; then
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
fi
[ -f "$slice/merged.a" ] && [ -f "$slice/Headers/zim/archive.h" ] || { echo "ios-arm64 slice missing in $dest" >&2; exit 1; }
echo "checksums ok: $name"
echo "LIBZIM_DIR=$slice"

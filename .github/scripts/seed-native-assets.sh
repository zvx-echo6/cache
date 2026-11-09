#!/usr/bin/env bash
# Puts PDFium (pdfium_dart 0.2.5's hook) and SQLite (sqlite3 3.5.2's hook) where those packages' build hooks keep their downloads,
# .dart_tool/hooks_runner/shared/<package>/build/, from files .github/actions/pinned-downloads fetched (sha256 checked), so the
# hooks find them and do not download from GitHub releases. Both hooks reuse a file that is already there (sqlite3's checks its
# own sha256 first, then downloads again on a mismatch). For the host (linux-x64 or macos-arm64) it also sets PDFIUM_PATH for
# app/test/support/pdfium_for_tests.dart.
# Usage: seed-native-assets.sh <downloads-dir> <app-dir> <target>...   target: linux-x64 android-arm64 android-arm android-x64
#        macos-arm64 ios-arm64 ios_sim-arm64 (PDFium for iOS comes from pdfium_flutter's xcframework instead, so iOS targets seed SQLite only).
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <downloads-dir> <app-dir> <target>..." >&2; exit 2; }
dl=$(cd "$1" && pwd); app=$(cd "$2" && pwd); shift 2
pins="$(cd "$(dirname "$0")/.." && pwd)/pinned-downloads.txt"
shared="$app/.dart_tool/hooks_runner/shared"
for t in "$@"; do
  os=${t%-*}; arch=${t##*-}
  case "$os" in
    linux|android) ext=so; plat=$t; lib=libpdfium.so ;;
    macos) ext=dylib; plat=mac-$arch; lib=libpdfium.dylib ;;
    ios|ios_sim) ext=dylib; plat= ;;
    *) echo "unknown target $t" >&2; exit 2 ;;
  esac
  if [ -n "$plat" ]; then
    out="$shared/pdfium_dart/build/chromium_7811/$plat"
    mkdir -p "$out"
    tar -xzf "$dl/pdfium-chromium-7811-$plat.tgz" -C "$out" --strip-components=1 "lib/$lib"
    echo "PDFium $t -> $out/$lib"
    case "$t" in linux-x64|macos-arm64) [ -n "${GITHUB_ENV:-}" ] && echo "PDFIUM_PATH=$out/$lib" >> "$GITHUB_ENV" ;; esac
  fi
  name="sqlite3-3.5.2-libsqlite3.$arch.$os.$ext"
  want=$(awk -v n="$name" '$1 == n { print $2 }' "$pins")
  [ -n "$want" ] || { echo "no pin for $name" >&2; exit 2; }
  out="$shared/sqlite3/build/download-${want:0:8}"
  mkdir -p "$out"
  cp "$dl/$name" "$out/libsqlite3.$ext"
  echo "SQLite $t -> $out/libsqlite3.$ext"
done

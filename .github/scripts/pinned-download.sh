#!/usr/bin/env bash
# Pinned downloads from .github/pinned-downloads.txt (name, sha256, URL per line), for .github/actions/pinned-downloads.
#   pinned-download.sh key <name>...          prints a cache key for these pins (it changes when any of them changes)
#   pinned-download.sh fetch <dir> <name>...  makes <dir>/<name> for each: a copy already there (restored from the Actions cache)
#                                             is kept when its sha256 matches; otherwise it is downloaded (3 tries, 10 s then
#                                             30 s apart) and checked. Fails if a file does not match its pin.
set -euo pipefail
manifest="$(cd "$(dirname "$0")/.." && pwd)/pinned-downloads.txt"
sha() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1; }
line() {
  local l
  l=$(awk -v n="$1" '$1 == n { print; found = 1 } END { exit !found }' "$manifest") || { echo "no pin named $1 in $manifest" >&2; exit 2; }
  echo "$l"
}
cmd=${1:-}; shift || true
case "$cmd" in
  key)
    [ $# -ge 1 ] || { echo "usage: $0 key <name>..." >&2; exit 2; }
    lines=""
    for n in "$@"; do l=$(line "$n"); lines+="$l"$'\n'; done
    printf '%s' "$lines" | sort | { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi; } | cut -c1-16
    ;;
  fetch)
    [ $# -ge 2 ] || { echo "usage: $0 fetch <dir> <name>..." >&2; exit 2; }
    dir=$1; shift
    mkdir -p "$dir"
    for n in "$@"; do
      l=$(line "$n")
      read -r _ want url <<< "$l"
      f="$dir/$n"
      if [ -f "$f" ] && [ "$(sha "$f")" = "$want" ]; then echo "$n: from the cache, sha256 ok"; continue; fi
      [ -f "$f" ] && echo "$n: the cached copy does not match its sha256; downloading again"
      rm -f "$f"
      ok=
      for try in 1 2 3; do
        if curl -fsSL --connect-timeout 30 --max-time 600 -o "$f.part" "$url"; then ok=1; break; fi
        rm -f "$f.part"
        [ "$try" -lt 3 ] && { echo "$n: download $try of 3 failed; retrying"; sleep $(( try == 1 ? 10 : 30 )); }
      done
      [ -n "$ok" ] || { echo "::error::$n: download failed 3 times ($url)"; exit 1; }
      got=$(sha "$f.part")
      [ "$got" = "$want" ] || { rm -f "$f.part"; echo "::error::$n: sha256 $got, pinned $want ($url)"; exit 1; }
      mv "$f.part" "$f"
      echo "$n: downloaded, sha256 ok"
    done
    ;;
  *) echo "usage: $0 key|fetch ..." >&2; exit 2 ;;
esac

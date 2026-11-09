#!/usr/bin/env bash
# Download the openZIM testing suite (a pinned release, verified by sha256) and copy its small ZIM that has a built-in Xapian full-text
# index and title index (withns/small.zim, 79 KB) to <out-dir>/small.zim. For the cfg(zimx) tests on Linux (CS_TEST_SMALL_ZIM).
# Usage: fetch-test-zim.sh <out-dir>   Prints the file's path as CS_TEST_SMALL_ZIM=<path>.
# With ZIM_SUITE_TGZ set to a copy of the release tarball (CI: .github/actions/pinned-downloads), that copy is used instead of a
# download; its sha256 is checked the same way.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <out-dir>" >&2; exit 2; }
ver=0.10.0
sha256=348821681a8f10eac8b7ca01dd48645d5b9a9c7d5b723edb0503d7d7f1042a96
url="https://github.com/openzim/zim-testing-suite/releases/download/$ver/zim-testing-suite-$ver.tar.gz"
mkdir -p "$1"
out=$(cd "$1" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -n "${ZIM_SUITE_TGZ:-}" ]; then
  cp "$ZIM_SUITE_TGZ" "$tmp/suite.tgz"
else
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$tmp/suite.tgz" "$url"
fi
echo "$sha256  $tmp/suite.tgz" | sha256sum -c - >&2
tar -xzf "$tmp/suite.tgz" -C "$tmp" "zim-testing-suite-$ver/withns/small.zim"
cp "$tmp/zim-testing-suite-$ver/withns/small.zim" "$out/small.zim"
echo "CS_TEST_SMALL_ZIM=$out/small.zim"

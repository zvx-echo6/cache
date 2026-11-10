#!/usr/bin/env bash
# Run INSIDE a bare debian:bookworm container (what Raspberry Pi OS Bookworm is built on), by the `os-check` job of
# .github/workflows/server-release.yml. It installs nothing (no apt): it unpacks the release package, checks that the program and its
# libraries load on this system's glibc, then runs the library builder (cache-build, a separate artifact of the same commit) on a
# generated text PDF and a generated scanned PDF, and requires the scanned one to come out searchable through the Tesseract that
# is built in, reading the trained data that the package ships in lib/tessdata.
#   os-check.sh <work dir holding the package tarball, cache-build and where summary.md is written>
set -euo pipefail
W=${1:?work dir}
TEXT_PAGES=${TEXT_PAGES:-40}
SCAN_PAGES=${SCAN_PAGES:-10}
now() { date +%s.%N; }
# seconds between two now() values
since() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

. /etc/os-release
echo "system: $PRETTY_NAME, $(uname -m), $(ldd --version | head -n 1)"
mkdir -p /pkg && tar -xzf "$W"/cache-*-linux-*.tar.gz -C /pkg
test -x /pkg/cache || { echo "no /pkg/cache in the package"; exit 1; }
test -s /pkg/lib/tessdata/eng.traineddata || { echo "the package has no lib/tessdata/eng.traineddata"; exit 1; }
echo "package version: $(cat /pkg/VERSION)"
/pkg/cache --version
# every binary of the package must find all its libraries here
for f in /pkg/cache /pkg/lib/libcache_search.so /pkg/lib/libcache_llama.so /pkg/lib/libvalhalla_shim.so; do
  if env -u LD_LIBRARY_PATH ldd "$f" | grep 'not found'; then echo "$f has a missing library on this system"; exit 1; fi
done
echo "libraries: all found"

CB=/tmp/cache-build
cp "$W/cache-build" "$CB" && chmod 755 "$CB"
"$CB" selftest-pdfs /tmp/pdf-text --pages "$TEXT_PAGES"
"$CB" selftest-pdfs /tmp/pdf-scan --pages "$SCAN_PAGES"
export CACHE_TESSDATA_DIR=/pkg/lib/tessdata

# 1. a text PDF: no OCR needed, and the throughput of reading, laying out and chunking (the embedder is a stand-in, so no embedding time)
mkdir -p /tmp/packs-text /tmp/packs-scan /tmp/packs-noocr
t0=$(now)
"$CB" pdf /tmp/pdf-text/text.pdf --out /tmp/packs-text --fake-embedder
t1=$(now)
text_s=$(since "$t0" "$t1")

# 2. the scanned PDF without OCR is not searchable (the proof the next step is Tesseract's work)
if "$CB" pdf /tmp/pdf-scan/scan.pdf --out /tmp/packs-noocr --fake-embedder; then
  echo "the scanned PDF built without OCR: it should have no text"; exit 1
fi

# 3. with OCR it is searchable: the pack's text has the words that were drawn into the pictures
t0=$(now)
"$CB" pdf /tmp/pdf-scan/scan.pdf --out /tmp/packs-scan --fake-embedder --ocr
t1=$(now)
scan_s=$(since "$t0" "$t1")
pack=$(find /tmp/packs-scan -type f | head -n 1)
test -n "$pack" || { echo "no pack was written for the scanned PDF"; exit 1; }
gzip -dc "$pack" > /tmp/scan-pack.txt
for w in irrigation reservoir mosquitoes bread mountain; do
  grep -qi "$w" /tmp/scan-pack.txt || { echo "the OCR text lacks '$w'"; exit 1; }
done
grep -o '"ocr":{[^}]*}' /tmp/scan-pack.txt | head -n 1
grep -q '"engine":"tesseract"' /tmp/scan-pack.txt || { echo "the pack does not record tesseract"; exit 1; }
echo "the scanned PDF is searchable through Tesseract"

{
  echo "### Package check on $PRETTY_NAME ($(uname -m)), $(nproc) cores, $(grep -m1 -E 'model name|Model' /proc/cpuinfo || true)"
  echo "$RUNNER_LABEL"
  echo
  echo "- package $(cat /pkg/VERSION): program and libraries load on glibc $(ldd --version | head -n 1 | grep -o '[0-9.]*$')"
  echo "- text PDF, $TEXT_PAGES pages: ${text_s}s, $(awk -v n="$TEXT_PAGES" -v s="$text_s" 'BEGIN { printf "%.0f", n * 60 / s }') pages per minute (read, laid out, chunked; stand-in embedder)"
  echo "- scanned PDF, $SCAN_PAGES pages: ${scan_s}s, $(awk -v n="$SCAN_PAGES" -v s="$scan_s" 'BEGIN { printf "%.2f", s / n }') s per page, $(awk -v n="$SCAN_PAGES" -v s="$scan_s" 'BEGIN { printf "%.1f", n * 60 / s }') pages per minute (300 dpi, English fast model, includes reading the PDF, no embedding)"
} | tee "$W/summary.md"

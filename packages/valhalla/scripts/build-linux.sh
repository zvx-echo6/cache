#!/bin/bash
# Build Valhalla 3.7.0 + valhalla_shim for Linux (x86_64 or aarch64, native build on the matching host), as a shared library
# that needs only glibc. The same recipe as build-android.sh / build-windows.bat: the pinned Valhalla commit, the pinned vcpkg commit
# and manifest (vcpkg.json), the same CMake project and switches. Differences are listed in BUILD.md ("Linux").
# Usage: build-linux.sh <work-dir> <output-dir>
#   Needs: git, cmake >= 3.21, ninja, python3, curl, zip, unzip, tar, pkg-config, ccache (optional), and GCC 13 or newer
#   (Valhalla 3.7.0 uses <format>); set CC/CXX to it (defaults: gcc-13 / g++-13).
# Output: <output-dir>/{lib/libvalhalla_shim.so, include/valhalla_shim.h, LICENSE-NOTICE.txt, BUILD-INFO.txt}
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 <work-dir> <output-dir>" >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { echo "requires a Linux host" >&2; exit 1; }
case $(uname -m) in
  x86_64) arch=x86_64; triplet=x64-linux-rel ;;
  aarch64) arch=aarch64; triplet=arm64-linux-rel ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$1" "$2"
work=$(cd "$1" && pwd)
out=$(cd "$2" && pwd)
export CC=${CC:-gcc-13} CXX=${CXX:-g++-13}
valhalla_rev=72f459fc5661fb906ad424be5378c4e32d9a5b3b   # tag 3.7.0 (also pinned in fetch-source.sh, which checks it out)
vcpkg_rev=0e39c10736341cc8135b560438229bbda3d3219a
checkout() {
  local url=$1 dir=$2 rev=$3
  if [[ ! -d "$dir/.git" ]]; then git clone --no-checkout "$url" "$dir"; fi
  git -C "$dir" fetch origin "$rev"
  git -C "$dir" checkout --detach "$rev"
  [[ $(git -C "$dir" rev-parse HEAD) == "$rev" ]]
}
bash "$here/scripts/fetch-source.sh" "$work/src"   # pinned Valhalla source + leapseconds (no-op when the workflow already ran it)
[[ $(git -C "$work/src" rev-parse HEAD) == "$valhalla_rev" ]]
checkout https://github.com/microsoft/vcpkg.git "$work/vcpkg" "$vcpkg_rev"
export VCPKG_ROOT="$work/vcpkg"
export VCPKG_DOWNLOADS="$work/downloads"
export VCPKG_DEFAULT_BINARY_CACHE="$work/vcpkg-archives"
export VCPKG_FORCE_SYSTEM_BINARIES=1   # use the system cmake/ninja (vcpkg has no aarch64 Linux tool downloads)
export VCPKG_MAX_CONCURRENCY=$(nproc)
mkdir -p "$VCPKG_DOWNLOADS" "$VCPKG_DEFAULT_BINARY_CACHE"
[[ -x "$VCPKG_ROOT/vcpkg" ]] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
launcher=()
if command -v ccache >/dev/null; then launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache); fi
cmake -S "$here" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release "${launcher[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DVALHALLA_SRC="$work/src" \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_TARGET_TRIPLET="$triplet" -DVCPKG_HOST_TRIPLET="$triplet" \
  -DVCPKG_OVERLAY_TRIPLETS="$here/triplets" -DVCPKG_INSTALL_OPTIONS=--x-abi-tools-use-exact-versions \
  -DVCPKG_INSTALLED_DIR="$work/installed"
cmake --build "$work/build" --parallel "$(nproc)"

mkdir -p "$out/lib" "$out/include"
strip --strip-unneeded -o "$out/lib/libvalhalla_shim.so" "$work/build/libvalhalla_shim.so"
cp "$here/shim/valhalla_shim.h" "$out/include/"
nm -D --defined-only "$out/lib/libvalhalla_shim.so" > "$work/valhalla-symbols.txt"
for symbol in version init route matrix locate trace_attributes string_free destroy last_error last_error_code; do
  grep -Eq " T valhalla_shim_${symbol}$" "$work/valhalla-symbols.txt" || { echo "missing shim export: $symbol" >&2; exit 1; }
done
# Exported symbols: only valhalla_shim_* (everything from Valhalla, its dependencies, libstdc++ and libgcc stays hidden).
extra=$(awk '$2 ~ /^[TDBRVWu]$/ && $3 !~ /^valhalla_shim_/ {print $3}' "$work/valhalla-symbols.txt" | grep -Ev '^(_init|_fini|_edata|__bss_start|_end)$' || true)
[[ -z "$extra" ]] || { echo "unexpected exported symbols:" >&2; echo "$extra" | head -20 >&2; exit 1; }

# Only glibc: no libstdc++/libgcc/libz/libprotobuf dependency, and nothing newer than glibc 2.35.
needed=$(readelf -d "$out/lib/libvalhalla_shim.so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | LC_ALL=C sort | tr '\n' ' ')
echo "NEEDED: $needed"
for lib in $needed; do
  case $lib in libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|ld-linux-*.so.*) ;; *) echo "unexpected dependency: $lib" >&2; exit 1 ;; esac
done
maxglibc=$(objdump -T "$out/lib/libvalhalla_shim.so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
echo "max GLIBC: $maxglibc"
[[ $(printf '%s\n2.35\n' "$maxglibc" | sort -V | tail -1) == 2.35 ]] || { echo "needs glibc $maxglibc (> 2.35)" >&2; exit 1; }
if objdump -T "$out/lib/libvalhalla_shim.so" | grep -q 'GLIBCXX_\|CXXABI_\|GCC_'; then echo "libstdc++/libgcc symbols are not static" >&2; exit 1; fi

# Licence notice: Valhalla's LICENSE.md and the licence file vcpkg installs for each dependency.
{
  echo "valhalla_shim (Cache) bundles Valhalla 3.7.0 (MIT) and statically linked libraries. Licences follow."
  echo "OSM-derived routing tiles carry the ODbL (attribution is the application's job)."
  echo "libstdc++ and libgcc are linked statically under the GCC Runtime Library Exception (GPL-3.0 with exception)."
  echo
  echo "===== Valhalla 3.7.0 (MIT) ====="
  cat "$work/src/COPYING" 2>/dev/null || cat "$work/src/LICENSE.md"
  for c in "$work"/installed/"$triplet"/share/*/copyright; do
    [[ -f "$c" ]] || continue
    echo; echo "===== vcpkg port $(basename "$(dirname "$c")") ====="
    cat "$c"
  done
  echo
  echo "===== Valhalla vendored sources: rapidjson (MIT), date by Howard Hinnant (MIT), IANA tz data (public domain), unordered_dense (MIT), protozero (BSD-2-Clause) ====="
} > "$out/LICENSE-NOTICE.txt"

{
  echo "valhalla_shim for Linux $arch"
  echo "Valhalla=3.7.0 commit $valhalla_rev"
  echo "vcpkg=$vcpkg_rev triplet=$triplet (static, release, -fPIC)"
  echo "CMake flags: Release; ENABLE_TOOLS/DATA_TOOLS/SERVICES/HTTP/PYTHON_BINDINGS/NODE_BINDINGS/TESTS/BENCHMARKS/GEOTIFF/LZ4/CCACHE=OFF; BUILD_SHARED_LIBS=OFF; hidden visibility"
  echo "link: -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL -Wl,--gc-sections"
  echo "compiler: $("$CXX" --version | head -1)"
  echo "cmake: $(cmake --version | head -1)"
  echo "build host glibc: $(ldd --version | head -1)"
  echo "max GLIBC needed: $maxglibc"
  echo "NEEDED: $needed"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source commit: ${GITHUB_SHA:-unknown}"
  sha256sum "$out/lib/libvalhalla_shim.so"
} > "$out/BUILD-INFO.txt"
cat "$out/BUILD-INFO.txt"

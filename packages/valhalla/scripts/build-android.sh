#!/bin/bash
# Cross-build Valhalla 3.7.0 + valhalla_shim for Android arm64-v8a (API 24) on a Linux host (the GitHub Actions runner).
# The same build as build-android.bat (the desktop's), with the Linux host triplet. All downloads and build products stay in $1.
# Output: $2/libvalhalla_shim.so (stripped, the copy the app ships) and $2/valhalla-build.txt.
# Usage: build-android.sh <work-dir> <output-dir>    NDK: ANDROID_NDK_HOME (r28, 28.2.13676358, the one Flutter's build uses).
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 <work-dir> <output-dir>" >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { echo "requires a Linux host" >&2; exit 1; }
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
[[ -f "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" ]] || { echo "NDK not found: $ANDROID_NDK_HOME" >&2; exit 1; }
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$1" "$2"
work=$(cd "$1" && pwd)
out=$(cd "$2" && pwd)
valhalla_rev=72f459fc5661fb906ad424be5378c4e32d9a5b3b
vcpkg_rev=0e39c10736341cc8135b560438229bbda3d3219a
checkout() {
  local url=$1 dir=$2 rev=$3
  if [[ ! -d "$dir/.git" ]]; then git clone --no-checkout "$url" "$dir"; fi
  git -C "$dir" fetch origin "$rev"
  git -C "$dir" checkout --detach "$rev"
  [[ $(git -C "$dir" rev-parse HEAD) == "$rev" ]]
}
checkout https://github.com/valhalla/valhalla.git "$work/src" "$valhalla_rev"
git -C "$work/src" submodule update --init --recursive
checkout https://github.com/microsoft/vcpkg.git "$work/vcpkg" "$vcpkg_rev"
export VCPKG_ROOT="$work/vcpkg"
export VCPKG_DOWNLOADS="$work/downloads"
mkdir -p "$VCPKG_DOWNLOADS"
[[ -x "$VCPKG_ROOT/vcpkg" ]] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
cp "$here/tz/leapseconds" "$work/src/third_party/tz/leapseconds"
touch "$work/src/third_party/tz/leapseconds"
cmake -S "$here" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DVALHALLA_SRC="$work/src" \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DVCPKG_TARGET_TRIPLET=arm64-android-rel -DVCPKG_HOST_TRIPLET=x64-linux \
  -DVCPKG_OVERLAY_TRIPLETS="$here/triplets" -DVCPKG_INSTALL_OPTIONS=--x-abi-tools-use-exact-versions \
  -DVCPKG_INSTALLED_DIR="$work/installed" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static
cmake --build "$work/build" --parallel "$(nproc)"
bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
"$bin/llvm-strip" -o "$out/libvalhalla_shim.so" "$work/build/libvalhalla_shim.so"
"$bin/llvm-nm" -D --defined-only "$out/libvalhalla_shim.so" > "$work/valhalla-symbols.txt"
for symbol in version init route matrix locate trace_attributes string_free destroy last_error last_error_code; do
  grep -Eq " T valhalla_shim_${symbol}$" "$work/valhalla-symbols.txt" || { echo "missing shim export: $symbol" >&2; exit 1; }
done
# Only the system libraries the desktop build needs (static libc++).
needed=$("$bin/llvm-readelf" -d "$out/libvalhalla_shim.so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | LC_ALL=C sort | tr '\n' ' ')
echo "NEEDED: $needed"
for lib in $needed; do
  case $lib in liblog.so|libm.so|libdl.so|libc.so) ;; *) echo "unexpected dependency: $lib" >&2; exit 1 ;; esac
done
{
  echo "Valhalla=$valhalla_rev"
  echo "vcpkg=$vcpkg_rev"
  echo "target=aarch64-linux-android api=24 stl=c++_static"
  echo "ndk=$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties")"
  sha256sum "$out/libvalhalla_shim.so"
} > "$out/valhalla-build.txt"
cat "$out/valhalla-build.txt"

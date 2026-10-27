#!/bin/bash
# Device-only static routing build. All downloads/build products stay in $1.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 <work-dir> <output-dir>" >&2; exit 2; }
[[ $(uname -s) == Darwin ]] || { echo "requires macOS/Xcode" >&2; exit 1; }
# Apple clang interprets this ambient variable even for macOS host tools.
# iOS stays pinned via the target triplet and explicit CMake/compiler flags below.
unset IPHONEOS_DEPLOYMENT_TARGET
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
"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
cp "$here/tz/leapseconds" "$work/src/third_party/tz/leapseconds"
touch "$work/src/third_party/tz/leapseconds"
case $(uname -m) in
  arm64) host=arm64-osx ;;
  x86_64) host=x64-osx ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac
cmake -S "$here" -B "$work/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DVALHALLA_SRC="$work/src" \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_TARGET_TRIPLET=arm64-ios-rel -DVCPKG_HOST_TRIPLET="$host" \
  -DVCPKG_OVERLAY_TRIPLETS="$here/triplets" \
  -DVCPKG_INSTALLED_DIR="$work/installed" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.3 \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCACHE_VALHALLA_STATIC=ON -DCACHE_VALHALLA_BUILD_TEST=ON \
  -DENABLE_STATIC_LIBRARY_MODULES=OFF
# Linking the C harness resolves the shim's complete dependency closure.
cmake --build "$work/build" --target valhalla_shim_test --parallel 3
archives=("$work/build/libvalhalla_shim.a" "$work/build/valhalla/src/libvalhalla.a")
while IFS= read -r archive; do
  # Full protobuf and protoc are build tools; routing uses protobuf-lite only.
  case $(basename "$archive") in libprotobuf.a|libprotoc.a) continue ;; esac
  archives+=("$archive")
done < <(find "$work/installed/arm64-ios-rel/lib" -maxdepth 1 -name '*.a' -type f | LC_ALL=C sort)
xcrun libtool -static -o "$out/libcache_valhalla.a" "${archives[@]}"
[[ $(xcrun lipo -archs "$out/libcache_valhalla.a") == arm64 ]]
xcrun nm -gU "$out/libcache_valhalla.a" > "$out/valhalla-symbols.txt"
for symbol in version init route matrix locate trace_attributes string_free destroy last_error last_error_code; do
  grep -Eq " [T] _valhalla_shim_${symbol}$" "$out/valhalla-symbols.txt" || {
    echo "missing shim definition: $symbol" >&2; exit 1;
  }
done
# Relink against the actual merged archive, not just CMake's individual libraries.
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=16.3 -I"$here/shim" "$here/test/shim_test.c" \
  "$out/libcache_valhalla.a" -lc++ -lz -framework CoreFoundation -o "$work/bundle-link-check"
{
  echo "Valhalla=$valhalla_rev"
  echo "vcpkg=$vcpkg_rev"
  echo "target=arm64-apple-ios deployment=16.3"
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  shasum -a 256 "$out/libcache_valhalla.a"
} > "$out/valhalla-build.txt"

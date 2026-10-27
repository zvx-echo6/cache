#!/bin/bash
# Cheap, offline Mac gate; never downloads or builds native dependencies.
set -euo pipefail
fail() { echo "iOS preflight ERROR: $*" >&2; exit 1; }
trap 'echo "iOS preflight ERROR: line $LINENO failed; stop before dependency build/archive." >&2' ERR
if [[ ${1:-} == --help ]]; then
  echo "usage: bash packages/valhalla/scripts/preflight-ios.sh [expected-full-40-character-SHA]"
  exit 0
fi
[[ $# -le 1 ]] || fail 'expected at most one full source SHA'
if [[ $# == 1 ]]; then
  [[ $1 =~ ^[0-9a-fA-F]{40}$ ]] || fail 'expected a full 40-character commit SHA; shortened hex SHAs are unsafe for checkout. Resolve branch refs in the workflow before invoking this gate.'
fi
[[ $(uname -s) == Darwin ]] || fail 'requires macOS with existing Xcode tools; run on Mac CI, not Windows/Linux'
for tool in git python3 xcrun xcodebuild cmake ninja cargo rustc swift mktemp env; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing existing tool: $tool (no installation attempted)"
done
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
cd "$root"
head=$(git rev-parse --verify HEAD)
if [[ $# == 1 ]]; then
  [[ $(printf '%s' "$1" | tr 'A-F' 'a-f') == "$head" ]] || fail "checkout $head differs from expected $1"
fi
# Inspect machine configuration only; do not execute or source build scripts.
python3 - "$root" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def fail(message):
    sys.exit('iOS preflight ERROR: ' + message)
def read(name):
    p = root / name
    if not p.is_file(): fail('missing configuration: ' + name)
    return p.read_text()
def matches(name, pattern, expected):
    values = re.findall(pattern, read(name), re.M)
    if not values or any(v != expected for v in values):
        fail(f'{name}: expected every matched value to be {expected}; found {values}')
build = 'packages/valhalla/scripts/build-ios.sh'
matches(build, r'^valhalla_rev=([0-9a-f]+)$', '72f459fc5661fb906ad424be5378c4e32d9a5b3b')
baseline = '0e39c10736341cc8135b560438229bbda3d3219a'
matches(build, r'^vcpkg_rev=([0-9a-f]+)$', baseline)
manifest = json.loads(read('packages/valhalla/vcpkg.json'))
if manifest.get('builtin-baseline') != baseline or manifest.get('version-string') != '3.7.0':
    fail('Valhalla manifest version/baseline disagrees with pinned build source')
minimum = '16.3'
matches('.github/workflows/ios-testflight.yml', r"^\s+IPHONEOS_DEPLOYMENT_TARGET:\s*['\"]?([0-9.]+)", minimum)
cmake_wrapper = read('packages/valhalla/CMakeLists.txt')
if 'TARGET_DIRECTORY valhalla-baldr' not in cmake_wrapper or 'COMPILE_DEFINITIONS "INSTALL=."' not in cmake_wrapper:
    fail('iOS embedded timezone path must be scoped to tz_alt.cpp in valhalla-baldr')
matches('app/ios/Podfile', r"^platform\s+:ios,\s*'([^']+)'", minimum)
matches('app/ios/Podfile', r"build_settings\['IPHONEOS_DEPLOYMENT_TARGET'\]\s*=\s*'([^']+)'", minimum)
matches('app/ios/Runner.xcodeproj/project.pbxproj', r'IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)', minimum)
for package in ('cache_llama', 'cache_search'):
    matches(f'packages/{package}/ios/{package}.podspec', r"s\.platform\s*=\s*:ios,\s*'([^']+)'", minimum)
for name in (build, 'packages/cache_llama/ios/build-native.sh'):
    matches(name, r'-DCMAKE_OSX_DEPLOYMENT_TARGET=([0-9.]+)', minimum)
matches(build, r'-miphoneos-version-min=([0-9.]+)', minimum)
matches('packages/cache_search/ios/build-core.sh', r'^export IPHONEOS_DEPLOYMENT_TARGET=([0-9.]+)', minimum)
matches('packages/valhalla/triplets/arm64-ios-rel.cmake', r'set\(VCPKG_OSX_DEPLOYMENT_TARGET\s+"?([0-9.]+)', minimum)
# Catch the historical merged-archive omission before any compilation.
search_spec = read('packages/cache_search/ios/cache_search.podspec')
frameworks = re.findall(r'^\s*s\.frameworks\s*=([^\n]+)', search_spec, re.M)
if not frameworks or not all(re.search(r"['\"]CoreFoundation['\"]", row) for row in frameworks):
    fail('cache_search.podspec must explicitly link CoreFoundation')
recipe = re.sub(r'\\\n', ' ', read(build))
commands = [line for line in recipe.splitlines()
            if line.lstrip().startswith('xcrun ') and '-o "$work/bundle-link-check"' in line]
if len(commands) != 1 or not re.search(r'-framework\s+CoreFoundation(?:\s|$)', commands[0]):
    fail('standalone merged-archive link must explicitly pass -framework CoreFoundation')
print('PASS: search podspec and standalone merged-archive link include CoreFoundation')
print('PASS: source pins, vcpkg baseline and all configured minimums agree (iOS 16.3)')
PY
xcodebuild -version
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
macsdk=$(xcrun --sdk macosx --show-sdk-path)
[[ -d $sdk && -d $macsdk ]] || fail 'Xcode device or host SDK missing'
for sdkname in macosx iphoneos; do
  for tool in clang clang++ lipo; do
    xcrun --sdk "$sdkname" --find "$tool" >/dev/null || fail "missing $sdkname $tool"
  done
done
# Always use the OS scratch area, outside the source checkout; clean on any exit.
work=$(mktemp -d /private/tmp/cache-ios-preflight.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$work/host.c" <<'C'
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#error Host tools must not target iPhone
#endif
int main(void) { return TARGET_OS_IPHONE != 0; }
C
# Explicit host SDK and removal of inherited target flags keep pkgconf-like
# host executables runnable even when the workflow exports an iPhone minimum.
env -u IPHONEOS_DEPLOYMENT_TARGET -u SDKROOT -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
  xcrun --sdk macosx clang -isysroot "$macsdk" "$work/host.c" -o "$work/host"
"$work/host" || fail 'Mac host probe could not run or TARGET_OS_IPHONE was nonzero'
echo 'PASS: host compile and execution with iOS environment unset (TARGET_OS_IPHONE=0)'
cat > "$work/device.cpp" <<'CPP'
#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <chrono>
#include <format>
#if !TARGET_OS_IPHONE || TARGET_OS_SIMULATOR || !defined(__arm64__)
#error Expected arm64 iPhone device target
#endif
int main() {
    auto text = std::format("{} {:%F}", 1.25, std::chrono::system_clock::now());
    auto value = CFStringCreateWithCString(kCFAllocatorDefault, text.c_str(), kCFStringEncodingUTF8);
    if (!value) return 1;
    CFRelease(value);
    return 0;
}
CPP
env -u IPHONEOS_DEPLOYMENT_TARGET -u SDKROOT -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
  xcrun --sdk iphoneos clang++ -std=c++20 -arch arm64 -isysroot "$sdk" \
  -miphoneos-version-min=16.3 -Werror=unguarded-availability -Werror=unguarded-availability-new \
  "$work/device.cpp" -framework CoreFoundation -o "$work/device"
archs=$(xcrun lipo -archs "$work/device")
[[ $archs == arm64 ]] || fail "device probe architecture is '$archs', expected only arm64"
echo 'PASS: iOS 16.3 arm64 std::format/chrono + CoreFoundation compile/link (device binary NOT executed)'
echo "PASS: preflight source $head; dependency builds, fixture tests, archive/signing and device parity remain separate gates"

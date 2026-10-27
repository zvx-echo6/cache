#!/bin/bash
# Use the same release contract for the archive and the actual exported IPA.
set -euo pipefail
fail() { echo "iOS app check ERROR: $*" >&2; exit 1; }
[[ $# == 1 && -d $1 ]] || fail 'usage: check-app.sh /path/to/Runner.app'
: "${TEAM_ID:?TEAM_ID is required}"
: "${BUNDLE_ID:?BUNDLE_ID is required}"
app=$1
bin=$app/Runner
[[ -f $bin ]] || fail 'Runner executable is missing'
[[ $(xcrun lipo -archs "$bin") == arm64 ]] || fail 'expected only arm64 device architecture'
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist"; }
[[ $(plist MinimumOSVersion) == 16.3 ]] || fail 'minimum iOS version must be 16.3'
[[ $(plist CFBundleIdentifier) == "$BUNDLE_ID" ]] || fail 'bundle identifier mismatch'
[[ $(plist CFBundleShortVersionString) == 1.0.0 ]] || fail 'app version mismatch'
if [[ -n ${EXPECTED_BUILD_NUMBER:-} ]]; then
  [[ $(plist CFBundleVersion) == "$EXPECTED_BUILD_NUMBER" ]] || fail 'build number mismatch'
fi
work=$(mktemp -d /private/tmp/cache-check-app.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
xcrun nm -gU "$bin" > "$work/symbols.txt"
for symbol in _cs_open _cs_version _cl_load _cl_next _valhalla_shim_init _valhalla_shim_route _cache_free_bytes_on_disk; do
  grep -Eq " ${symbol}$" "$work/symbols.txt" || fail "missing native symbol: $symbol"
done
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null
for entitlement in com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing com.apple.developer.usernotifications.time-sensitive; do
  [[ $(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$work/entitlements.plist") == true ]] || fail "missing entitlement: $entitlement"
done
[[ $(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$work/entitlements.plist") == "$TEAM_ID.$BUNDLE_ID" ]] || fail 'signed application identity mismatch'
echo 'PASS: signed app architecture, minimum OS, version/build, native symbols, identity and all required entitlements'

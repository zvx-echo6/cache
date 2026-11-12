#!/bin/bash
# CarPlay spike, step 1: what this runner has (Xcode, Simulator, screen, input permissions), the helper tool, and a booted
# iPhone simulator. Everything it learns goes to spike-out/facts.log.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$RUNNER_TEMP/spike-out"
mkdir -p "$OUT/ui"
FACTS="$OUT/facts.log"
date -u +%s > "$OUT/.job-start"
note() { echo "$*" | tee -a "$FACTS"; }
show() { note ""; note "\$ $*"; "$@" 2>&1 | head -n "${LINES_MAX:-80}" | sed 's/^/    /' | tee -a "$FACTS"; }

note "== runner"
show sw_vers
show xcodebuild -version
show xcode-select -p
show system_profiler SPDisplaysDataType
SIMAPP="$(xcode-select -p)/Applications/Simulator.app"
note ""
note "== Simulator app: $SIMAPP"
show /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$SIMAPP/Contents/Info.plist"
note ""
note "\$ strings Simulator | grep -i carplay / external display / extra options"
strings -a "$SIMAPP/Contents/MacOS/Simulator" 2>/dev/null | grep -i -E 'carplay|externaldisplay|external display|extraoptions' | sort -u | head -n 150 | sed 's/^/    /' | tee -a "$FACTS"
note ""
note "\$ files in Simulator.app named like CarPlay or external display"
find "$SIMAPP/Contents" -iname '*carplay*' -o -iname '*external*' 2>/dev/null | head -n 40 | sed 's/^/    /' | tee -a "$FACTS"
note ""
note "\$ strings in those files (labels of the options panel, if it is a nib)"
find "$SIMAPP/Contents" \( -iname '*carplay*' -o -iname '*external*' \) -type f 2>/dev/null | head -n 12 | while read -r f; do
  note "    -- $f"
  strings -a "$f" 2>/dev/null | grep -v -E '^.{0,2}$' | head -n 60 | sed 's/^/       /' | tee -a "$FACTS"
done
LINES_MAX=70 show xcrun simctl io
show xcrun simctl list runtimes

note ""
note "== helper tool"
if xcrun --sdk macosx swiftc -O "$HERE/spiketool.swift" -o "$RUNNER_TEMP/spiketool" 2>&1 | tee -a "$FACTS"; then
  show "$RUNNER_TEMP/spiketool" screen
  show "$RUNNER_TEMP/spiketool" trusted
else
  note "the helper tool did not compile; clicks fall back to System Events"
fi
show python3 --version

note ""
note "== simulator"
# One iPhone simulator per iOS runtime to try, oldest first: round 2 found that the newest runtime's CarPlay template host
# (iOS 26.5) crashes on every map template, so the map is looked for on the older ones.
WANT="${SPIKE_RUNTIMES:-iOS-26-2 iOS-26-4 iOS-26-5}"
: > "$OUT/devices.txt"
for rt in $WANT; do
  line=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)["devices"]
for k in d:
    if k.endswith(want):
        phones = [dev for dev in d[k] if dev["name"].startswith("iPhone")]
        phones.sort(key=lambda dev: (dev["name"] != "iPhone 17 Pro", dev["name"]))
        if phones:
            print(want + "|" + phones[0]["udid"] + "|" + phones[0]["name"])
' "$rt")
  if [ -z "$line" ] && [ "$(xcrun simctl list runtimes | grep -c "SimRuntime.$rt")" != 0 ]; then
    made=$(xcrun simctl create "Spike $rt" "iPhone 17 Pro" "com.apple.CoreSimulator.SimRuntime.$rt" 2>&1)
    note "no iPhone simulator for $rt: created one: $made"
    case "$made" in *-*-*-*-*) line="$rt|$made|Spike $rt" ;; esac
  fi
  [ -n "$line" ] && echo "$line" >> "$OUT/devices.txt"
done
note "devices to try (runtime|udid|name):"
sed 's/^/    /' "$OUT/devices.txt" | tee -a "$FACTS"
first=$(head -n 1 "$OUT/devices.txt")
[ -n "$first" ] || { xcrun simctl list devices available | tee -a "$FACTS"; note "no iPhone simulator"; exit 1; }
udid=$(echo "$first" | cut -d'|' -f2)
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-0-untouched.txt" 2>&1 || true
# A process of the simulator that crashes puts a "quit unexpectedly" window on the Mac screen, over the CarPlay window: off.
show defaults write com.apple.CrashReporter DialogType none
show xcrun simctl boot "$udid"
note "(the simulator finishes booting while the app builds)"
exit 0

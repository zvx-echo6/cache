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
picked=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["devices"]
ios = sorted((k for k in d if "iOS" in k), key=lambda k: [int(x) for x in k.rsplit("iOS-", 1)[1].split("-")])
for k in reversed(ios):
    for dev in d[k]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"] + "|" + dev["name"] + "|" + k.rsplit(".", 1)[-1]); sys.exit()
')
[ -n "$picked" ] || { xcrun simctl list devices available | tee -a "$FACTS"; note "no iPhone simulator"; exit 1; }
udid="${picked%%|*}"
rest="${picked#*|}"
note "device: $rest ($udid)"
echo "SPIKE_UDID=$udid" >> "$GITHUB_ENV"
echo "SPIKE_DEVICE=${rest%%|*}" >> "$GITHUB_ENV"
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-0-untouched.txt" 2>&1 || true
# A process of the simulator that crashes puts a "quit unexpectedly" window on the Mac screen, over the CarPlay window: off.
show defaults write com.apple.CrashReporter DialogType none
show xcrun simctl boot "$udid"
note "(the simulator finishes booting while the app builds)"
exit 0

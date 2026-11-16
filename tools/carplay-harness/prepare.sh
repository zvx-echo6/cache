#!/bin/bash
# CarPlay harness, step 1: the helper tool, the Mac's crash windows off, and the iPhone simulator the harness is pinned to.
#
# The simulator is the iOS 26.2 one on purpose. The CarPlay template host of the iOS 26.4 and 26.5 simulators crashes on every
# map template ('-[CPSTemplateInstance vehicleSupportsDestinationSharing]: unrecognized selector', in its own viewDidLoad), so
# on those nothing of a navigation app can be seen. When a newer simulator is fixed, change HARNESS_RUNTIME.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$RUNNER_TEMP/harness-out"
RUNTIME="${HARNESS_RUNTIME:-iOS-26-2}"
mkdir -p "$OUT"
FACTS="$OUT/facts.log"
note() { echo "$*" | tee -a "$FACTS"; }
show() { note ""; note "\$ $*"; "$@" 2>&1 | head -n 40 | sed 's/^/    /' | tee -a "$FACTS"; }

show sw_vers
show xcodebuild -version
show xcrun simctl list runtimes
if xcrun --sdk macosx swiftc -O "$HERE/screentool.swift" -o "$RUNNER_TEMP/screentool" 2>&1 | tee -a "$FACTS"; then
  show "$RUNNER_TEMP/screentool" screen
else
  note "the helper tool did not compile; clicks fall back to System Events"
fi

line=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)["devices"]
for k in d:
    if k.endswith(want):
        phones = [dev for dev in d[k] if dev["name"].startswith("iPhone")]
        phones.sort(key=lambda dev: (dev["name"] != "iPhone 17 Pro", dev["name"]))
        if phones:
            print(phones[0]["udid"] + "|" + phones[0]["name"])
' "$RUNTIME")
if [ -z "$line" ] && [ "$(xcrun simctl list runtimes | grep -c "SimRuntime.$RUNTIME")" != 0 ]; then
  made=$(xcrun simctl create "Harness $RUNTIME" "iPhone 17 Pro" "com.apple.CoreSimulator.SimRuntime.$RUNTIME" 2>&1)
  note "no iPhone simulator for $RUNTIME: created one: $made"
  case "$made" in *-*-*-*-*) line="$made|Harness $RUNTIME" ;; esac
fi
if [ -z "$line" ]; then
  echo "::error::The CarPlay harness needs the $RUNTIME simulator runtime, and this runner image does not have it."
  exit 1
fi
note "simulator: ${line#*|}, $RUNTIME (${line%%|*})"
echo "HARNESS_UDID=${line%%|*}" >> "$GITHUB_ENV"
echo "HARNESS_DEVICE=${line#*|}" >> "$GITHUB_ENV"
# A process of the simulator that crashes puts a "quit unexpectedly" window on the Mac screen, over the CarPlay window: off.
show defaults write com.apple.CrashReporter DialogType none
show xcrun simctl boot "${line%%|*}"
exit 0

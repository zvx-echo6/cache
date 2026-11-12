#!/bin/bash
# CarPlay spike, step 3: opens the Simulator's CarPlay display from a script, starts the scratch app from the car side only,
# and takes the pictures. Every command and what it printed goes to spike-out/steps.log; lines that start with RESULT are the
# answers. Nothing here stops at the first failure: each part reports and the next one runs.
#
#   A  the CarPlay display as the Simulator opens it by default (800 x 480 at 2x): can it be opened and photographed; does
#      the app show there without and with the CarPlay entitlement; a cold start from the car side; the phone joining after
#   B  the four test sizes, with the Simulator's CarPlayExtraOptions switched on
#   C  the CarPlay scene declared in code instead of the Info.plist manifest
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$RUNNER_TEMP/spike-out"
APPS="$RUNNER_TEMP/spike-apps"
TOOL="$RUNNER_TEMP/spiketool"
UDID="${SPIKE_UDID:?no simulator was chosen}"
DEVICE="${SPIKE_DEVICE:-iPhone}"
SIMAPP="$(xcode-select -p)/Applications/Simulator.app"
mkdir -p "$OUT/shots" "$OUT/host" "$OUT/ui" "$OUT/applog"
LOG="$OUT/steps.log"
T0=$SECONDS
WAYS="1 2 3"
ICON_X=0
ICON_Y=0

say() { printf '[%4ds] %s\n' "$((SECONDS - T0))" "$*" | tee -a "$LOG"; }

run() {  # runs a command, logging it and what it printed
  say "\$ $*"
  "$@" > "$OUT/.last" 2>&1
  local rc=$?
  head -n "${RUN_LINES:-40}" "$OUT/.last" | sed 's/^/        /' | tee -a "$LOG"
  [ "$rc" = 0 ] || say "  (exit $rc)"
  return $rc
}

limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # limit <seconds> <command...>: no script may hang the job

osa() { limit 90 osascript "$HERE/$1.applescript" "${@:2}" 2>&1; }

sim_windows() { osa sim_windows; }

front() {  # the Simulator in front of everything, without sending it an Apple event
  open -a "$SIMAPP" > /dev/null 2>&1
  limit 30 osascript -e 'tell application "System Events" to tell process "Simulator" to set frontmost to true' > /dev/null 2>&1
}

carplay_window() {  # "x y w h" of the CarPlay window in screen points, or nothing
  local lines hit
  lines=$(sim_windows)
  hit=$(printf '%s\n' "$lines" | awk -F'|' 'tolower($1) ~ /carplay/ && $4 > 0 {print $2, $3, $4, $5; exit}')
  if [ -z "$hit" ]; then
    hit=$(printf '%s\n' "$lines" | awk -F'|' -v dev="$DEVICE" 'NF >= 5 && $4 > 0 && index($1, dev) == 0 {print $2, $3, $4, $5; exit}')
  fi
  if [ -z "$hit" ] && [ -x "$TOOL" ]; then
    hit=$("$TOOL" windows 2>/dev/null | awk '/\[Simulator\]/ && $4 == 0 && tolower($0) ~ /carplay/ {print $5, $6, $7, $8; exit}')
  fi
  printf '%s' "$hit"
}

pic_size() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}'; }

shot_ext() {  # the CarPlay display, straight from the simulator
  local f="$OUT/shots/$1.png"
  rm -f "$f"
  run xcrun simctl io "$UDID" screenshot --type=png --display=external "$f"
  if [ -s "$f" ]; then say "  picture shots/$1.png: $(pic_size "$f") pixels"; return 0; fi
  say "  no picture for $1"
  return 1
}

shot_phone() {  # the phone's own screen
  local f="$OUT/shots/$1.png"
  rm -f "$f"
  run xcrun simctl io "$UDID" screenshot --type=png --display=internal "$f"
  [ -s "$f" ] && say "  picture shots/$1.png: $(pic_size "$f") pixels"
}

shot_host() {  # the whole Mac screen, kept small
  local png="$OUT/host/$1.png"
  if screencapture -x "$png" 2>> "$LOG" && [ -s "$png" ]; then
    sips -s format jpeg -s formatOptions 60 "$png" --out "$OUT/host/$1.jpg" > /dev/null 2>&1 && rm -f "$png"
    say "  Mac screen: host/$1.jpg"
  else
    say "  screencapture gave nothing for $1"
  fi
}

container() { xcrun simctl get_app_container "$UDID" "$BID" data 2> /dev/null; }

applog() {
  local c
  c=$(container)
  [ -n "$c" ] && echo "$c/Documents/spike-log.txt"
}

keep_applog() {  # moves the app's own log into the artifact, and into the steps log
  local f
  f=$(applog)
  [ -n "$f" ] && [ -f "$f" ] || { say "app log ($1): none"; return 0; }
  cat "$f" >> "$OUT/applog/$1.txt"
  rm -f "$f"
  say "app log ($1):"
  tail -n 90 "$OUT/applog/$1.txt" | sed 's/^/        /' | tee -a "$LOG"
}

wait_log() {  # wait_log <text> <seconds>: 0 as soon as the app's log has the text
  local f end=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$end" ]; do
    f=$(applog)
    if [ -n "$f" ] && [ -f "$f" ] && grep -q -- "$1" "$f"; then return 0; fi
    sleep 1
  done
  return 1
}

set_mode() {  # the app reads this file once a second (AppDelegate.swift, pollMode)
  local c
  c=$(container)
  [ -n "$c" ] || { say "mode '$1': no app container"; return 1; }
  mkdir -p "$c/Documents"
  printf '%s' "$1" > "$c/Documents/spike-mode.txt"
  say "mode: '$1'"
}

click_at() {  # click_at <x> <y> <way>: 1 the Swift tool (CGEvent), 2 System Events, 3 CGEvent from osascript
  local x="$1" y="$2"
  case "$3" in
    1)
      if [ -x "$TOOL" ]; then run "$TOOL" click "$x" "$y"; else run limit 30 osascript -e "tell application \"System Events\" to click at {${x%.*}, ${y%.*}}"; fi
      ;;
    2) run limit 30 osascript -e "tell application \"System Events\" to click at {${x%.*}, ${y%.*}}" ;;
    *) run limit 30 osascript -l JavaScript "$HERE/click.js" "$x" "$y" ;;
  esac
}

find_icon_on_host() {  # the app's icon inside the CarPlay window, on a picture of the Mac screen; sets ICON_X ICON_Y (points)
  local label="$1" win found
  win=$(carplay_window)
  [ -n "$win" ] || { say "  no CarPlay window among: $(sim_windows | tr '\n' ';')"; return 1; }
  screencapture -x "$OUT/host/$label.png" 2>> "$LOG"
  [ -s "$OUT/host/$label.png" ] || { say "  screencapture gave nothing"; return 1; }
  # shellcheck disable=SC2086
  found=$(python3 -I "$HERE/find_icon.py" host "$OUT/host/$label.png" "$SCREEN_W" $win 2>&1 | tail -n 1)
  say "  icon on the Mac screen, inside the CarPlay window ($win): $found"
  sips -s format jpeg -s formatOptions 60 "$OUT/host/$label.png" --out "$OUT/host/$label.jpg" > /dev/null 2>&1 && rm -f "$OUT/host/$label.png"
  case "$found" in
    found*)
      # shellcheck disable=SC2086
      set -- $found
      ICON_X="$2"
      ICON_Y="$3"
      return 0
      ;;
  esac
  return 1
}

find_icon_by_geometry() {  # the same from the CarPlay display's own picture, placed into the window by proportion
  local label="$1" win found place
  win=$(carplay_window)
  [ -n "$win" ] || return 1
  shot_ext "$label-ext" > /dev/null 2>&1
  found=$(python3 -I "$HERE/find_icon.py" ext "$OUT/shots/$label-ext.png" 2>&1 | tail -n 1)
  say "  icon in the CarPlay display's own picture: $found"
  case "$found" in found*) ;; *) return 1 ;; esac
  # shellcheck disable=SC2086
  set -- $found $win
  place=$(python3 -I -c '
import sys
px, py = float(sys.argv[1]), float(sys.argv[2])
W, H = [float(v) for v in sys.argv[3].split("=")[1].split("x")]
wx, wy, ww, wh = [float(v) for v in sys.argv[4:8]]
ch = ww * H / W
top = wh - ch
if top < 0 or top > 80:
    top = 28.0
    ch = wh - top
print("%.1f %.1f" % (wx + px / W * ww, wy + top + py / H * ch))
' "$2" "$3" "$6" "$8" "$9" "${10}" "${11}" 2>> "$LOG")
  [ -n "$place" ] || return 1
  ICON_X="${place% *}"
  ICON_Y="${place#* }"
  say "  placed in the window at $ICON_X,$ICON_Y"
  return 0
}

toggle_home() {  # the bottom-left corner of the CarPlay screen switches between the dashboard and the app grid
  local win x y
  win=$(carplay_window)
  [ -n "$win" ] || return 1
  # shellcheck disable=SC2086
  set -- $win
  if [ "${3%.*}" -ge "${4%.*}" ]; then
    x=$((${1%.*} + ${3%.*} * 5 / 100))
    y=$((${2%.*} + ${4%.*} * 91 / 100))
  else
    x=$((${1%.*} + ${3%.*} * 8 / 100))
    y=$((${2%.*} + ${4%.*} * 96 / 100))
  fi
  say "  clicking the corner of the CarPlay window ($x,$y), in case it is not showing the app grid"
  click_at "$x" "$y" "${WAYS%% *}"
}

icon_in_carplay() {  # icon_in_carplay <picture name>: 0 when the icon is on the CarPlay display's own picture
  local found
  shot_ext "$1" || return 2
  found=$(python3 -I "$HERE/find_icon.py" ext "$OUT/shots/$1.png" 2>&1 | tail -n 1)
  say "  icon in shots/$1.png: $found"
  case "$found" in found*) return 0 ;; esac
  return 1
}

car_launch() {  # car_launch <label>: clicks the app's icon on the CarPlay screen; 0 when its CarPlay scene connected
  local label="$1" way
  front
  say "  $(osa sim_raise CarPlay)"
  sleep 1
  for way in $WAYS; do
    if find_icon_on_host "$label-click$way" || find_icon_by_geometry "$label-click$way"; then
      click_at "$ICON_X" "$ICON_Y" "$way"
      if wait_log 'carplay didConnect' 25; then
        say "the app's CarPlay scene connected ($label, click way $way)"
        WAYS="$way 1 2 3"
        return 0
      fi
      say "no CarPlay scene 25 s after the click ($label, way $way)"
      shot_ext "$label-after-click$way"
    else
      say "the icon was not found ($label, try $way)"
      toggle_home
      sleep 4
    fi
  done
  shot_host "$label-launch-failed"
  return 1
}

after_car_start() {  # waits for Dart and the map, then the pictures every size gets
  local label="$1"
  if wait_log 'dart hello' 45; then say "Dart said hello over the channel"; else say "no hello from Dart in 45 s"; fi
  if wait_log 'finished rendering map, fully rendered' 20; then say "the map reported a full render"; else say "no full-render line in 20 s"; fi
  sleep 3
  shot_ext "$label-map"
  set_mode "overlay guide"
  sleep 6
  shot_ext "$label-overlay-guide"
}

open_simulator() {
  run xcrun simctl bootstatus "$UDID" -b
  run open -a "$SIMAPP" --args -CurrentDeviceUDID "$UDID"
  local i w
  for i in $(seq 1 40); do
    w=$(sim_windows)
    case "$w" in *"|"*) break ;; esac
    sleep 2
  done
  sleep 6
  say "Simulator windows: $(sim_windows | tr '\n' ';')"
}

make_variant() {  # make_variant <name> <PlistBuddy command>: a copy of the entitled app with its Info.plist changed
  local dir="$APPS/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$APPS/ent/Runner.app" "$dir/"
  run /usr/libexec/PlistBuddy -c "$2" "$dir/Runner.app/Info.plist"
  run codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$dir/Runner.app"
}

# ---------------------------------------------------------------------------------------------------------------------------
say "== facts"
BID=""
for v in ent noent; do
  if [ -d "$APPS/$v/Runner.app" ]; then
    BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/$v/Runner.app/Info.plist")
    break
  fi
done
say "built apps: $(ls "$APPS" 2> /dev/null | tr '\n' ' ') bundle id: ${BID:-none}"
SCREEN_W=""
[ -x "$TOOL" ] && SCREEN_W=$("$TOOL" screen 2> /dev/null | awk '{print $3}')
[ -n "$SCREEN_W" ] || SCREEN_W=$(system_profiler SPDisplaysDataType 2> /dev/null | awk '/UI Looks like/{print $4; f=1; exit} /Resolution/{r=$2} END{if(!f) print r}')
[ -n "$SCREEN_W" ] || SCREEN_W=1920
say "Mac screen width in points: $SCREEN_W"
[ -x "$TOOL" ] && run "$TOOL" trusted
say "-- may a script drive other apps here? (System Events, the way the menu is clicked)"
run limit 60 osascript -e 'tell application "System Events" to get name of every process whose background only is false'

# ---------------------------------------------------------------------------------------------------------------------------
say "== A. the CarPlay display as the Simulator opens it by default"
open_simulator
osa sim_menus > "$OUT/ui/menus-A.txt" 2>&1
say "the Simulator's menus are in ui/menus-A.txt ($(grep -c . "$OUT/ui/menus-A.txt") lines); around External Displays:"
grep -B1 -A8 'External Display' "$OUT/ui/menus-A.txt" | sed 's/^/        /' | tee -a "$LOG"
shot_host A1-simulator-open
xcrun simctl io "$UDID" enumerate > "$OUT/ui/io-enumerate-0-before.txt" 2>&1
say "simctl io enumerate before: $(grep -c . "$OUT/ui/io-enumerate-0-before.txt") lines (ui/io-enumerate-0-before.txt)"
say "-- a picture of the external display before the CarPlay display is opened (expected to fail)"
shot_ext A0-before-carplay-is-opened

say "-- opening it: I/O > External Displays > CarPlay"
front
if ! run limit 60 osascript -e 'tell application "System Events" to tell process "Simulator" to click menu item "CarPlay" of menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1'; then
  say "  by searching the menus instead: $(osa sim_external CarPlay)"
fi
sleep 10
say "Simulator windows: $(sim_windows | tr '\n' ';')"
[ -x "$TOOL" ] && RUN_LINES=30 run "$TOOL" windows
osa sim_dump > "$OUT/ui/dump-A-carplay-open.txt" 2>&1
osa sim_menus > "$OUT/ui/menus-A-carplay-open.txt" 2>&1
grep -A8 'External Display' "$OUT/ui/menus-A-carplay-open.txt" | sed 's/^/        /' | tee -a "$LOG"
shot_host A2-carplay-open
if shot_ext A-carplay-home-default; then
  say "RESULT display: the CarPlay display opened from a script and simctl photographed it: $(pic_size "$OUT/shots/A-carplay-home-default.png") pixels"
else
  say "RESULT display: no picture of the CarPlay display by simctl after the menu click"
fi
xcrun simctl io "$UDID" enumerate > "$OUT/ui/io-enumerate-1-carplay.txt" 2>&1
say "simctl io enumerate now: $(grep -c . "$OUT/ui/io-enumerate-1-carplay.txt") lines; what changed:"
diff "$OUT/ui/io-enumerate-0-before.txt" "$OUT/ui/io-enumerate-1-carplay.txt" | head -n 40 | sed 's/^/        /' | tee -a "$LOG"
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-1-carplay-open.txt" 2>&1
say "what the Simulator wrote to its defaults when the CarPlay display opened:"
diff "$OUT/ui/defaults-0-untouched.txt" "$OUT/ui/defaults-1-carplay-open.txt" | head -n 60 | sed 's/^/        /' | tee -a "$LOG"

if [ -d "$APPS/noent/Runner.app" ]; then
  say "-- the app built WITHOUT the CarPlay entitlement (no provisioning profile either)"
  run xcrun simctl install "$UDID" "$APPS/noent/Runner.app"
  sleep 10
  if icon_in_carplay A-home-app-without-entitlement; then
    say "RESULT entitlement: WITHOUT the entitlement the app's icon IS on the CarPlay screen"
  else
    say "RESULT entitlement: WITHOUT the entitlement the app's icon is NOT on the CarPlay screen shown"
  fi
  run xcrun simctl uninstall "$UDID" "$BID"
  sleep 4
fi

A_OK=0
if [ -d "$APPS/ent/Runner.app" ]; then
  say "-- the app built WITH the CarPlay navigation entitlement, still no provisioning profile"
  run xcrun simctl install "$UDID" "$APPS/ent/Runner.app"
  sleep 10
  if icon_in_carplay A-home-app-with-entitlement; then
    say "RESULT entitlement: WITH the entitlement and no provisioning profile the app's icon IS on the CarPlay screen"
  else
    say "RESULT entitlement: WITH the entitlement the app's icon is NOT on the CarPlay screen shown"
  fi
  shot_phone A-phone-before-any-start
  say "-- cold start from the car side: the app has never run; its icon is clicked on the CarPlay screen"
  if car_launch A-default; then
    A_OK=1
    after_car_start default
    shot_phone default-phone-while-only-the-car-scene-runs
    shot_host A3-app-on-carplay
    set_mode "overlay"
    sleep 5
    shot_ext default-overlay
    set_mode "guide"
    sleep 5
    shot_ext default-guide
    set_mode "demo"
    sleep 14
    shot_ext default-demo-style
    set_mode ""
    sleep 4
    phone_lines=$(grep -c 'phone scene' "$(applog)" 2> /dev/null)
    say "RESULT car-first: ${phone_lines:-0} phone-scene lines in the app's log before the phone app was opened; scenes at Dart's hello: $(grep 'dart hello' "$(applog)" 2> /dev/null | head -n 1 | sed 's/.*scenes=//')"
    say "-- now the phone window joins the engine the car started"
    run xcrun simctl launch "$UDID" "$BID"
    sleep 10
    shot_phone default-phone-joined-the-engine
    shot_ext default-map-after-phone-joined
    keep_applog A-default
  else
    say "RESULT car-first: the app's CarPlay scene did not connect at the default size"
    keep_applog A-default-failed
    osa sim_dump > "$OUT/ui/dump-A-launch-failed.txt" 2>&1
    say "-- trying a copy with UIApplicationSupportsMultipleScenes set to true"
    make_variant multi 'Set :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes true'
    run xcrun simctl install "$UDID" "$APPS/multi/Runner.app"
    sleep 8
    if car_launch A-multi; then
      A_OK=1
      say "RESULT multiple-scenes: the CarPlay scene connected only with UIApplicationSupportsMultipleScenes true"
      after_car_start default-multi
      keep_applog A-multi
    else
      say "RESULT multiple-scenes: no CarPlay scene with it set to true either"
      keep_applog A-multi-failed
    fi
  fi
fi

# ---------------------------------------------------------------------------------------------------------------------------
say "== B. the four test sizes, CarPlayExtraOptions on"
[ -n "$BID" ] && run xcrun simctl terminate "$UDID" "$BID"
say "-- quitting the Simulator app so the setting is read at its next start"
limit 30 osascript -e 'tell application "System Events" to tell process "Simulator" to click menu item "Quit Simulator" of menu 1 of menu bar item "Simulator" of menu bar 1' >> "$LOG" 2>&1
sleep 6
pgrep -x Simulator > /dev/null && { say "  still running: killall"; killall Simulator; sleep 4; }
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-2-after-quit.txt" 2>&1
say "the Simulator's defaults, changes since before the first start:"
diff "$OUT/ui/defaults-0-untouched.txt" "$OUT/ui/defaults-2-after-quit.txt" | head -n 80 | sed 's/^/        /' | tee -a "$LOG"
run defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES
open_simulator
say "(the line above shows whether the CarPlay display came back by itself after the restart)"
osa sim_menus > "$OUT/ui/menus-B.txt" 2>&1
grep -A8 'External Display' "$OUT/ui/menus-B.txt" | sed 's/^/        /' | tee -a "$LOG"
osa sim_dump > "$OUT/ui/dump-B-after-restart.txt" 2>&1
shot_host B0-after-restart

for spec in "748 456 2" "800 480 2" "1920 720 3" "900 1200 3"; do
  # shellcheck disable=SC2086
  set -- $spec
  W=$1
  H=$2
  S=$3
  label="${W}x${H}-${S}x"
  say "-- size $W x $H pixels at ${S}x"
  [ -n "$BID" ] && xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  front
  if [ -n "$(carplay_window)" ]; then
    say "  closing the CarPlay display: $(osa sim_external Disabled)"
    sleep 5
  fi
  say "  asking for the CarPlay display: $(osa sim_external CarPlay)"
  sleep 5
  osa sim_dump > "$OUT/ui/dump-B-$label-1-asked.txt" 2>&1
  shot_host "B-$label-1-asked"
  say "  the options panel:"
  osa sim_options "$W" "$H" "$S" | sed 's/^/        /' | tee -a "$LOG"
  sleep 10
  osa sim_dump > "$OUT/ui/dump-B-$label-2-after.txt" 2>&1
  shot_host "B-$label-2-after"
  say "  Simulator windows: $(sim_windows | tr '\n' ';')"
  if shot_ext "$label-home"; then
    got=$(pic_size "$OUT/shots/$label-home.png")
    if [ "$got" = "${W}x${H}" ]; then
      say "RESULT size $label: the CarPlay display's picture is $got pixels, as asked"
    else
      say "RESULT size $label: asked for ${W}x${H}, the CarPlay display's picture is $got pixels"
    fi
  else
    say "RESULT size $label: no picture of the CarPlay display"
  fi
  if [ -d "$APPS/ent/Runner.app" ] && [ "$A_OK" = 1 ]; then
    if car_launch "$label"; then
      after_car_start "$label"
      if [ "$label" = "748x456-2x" ] || [ "$label" = "1920x720-3x" ]; then
        set_mode "overlay"
        sleep 5
        shot_ext "$label-overlay"
        set_mode "guide"
        sleep 5
        shot_ext "$label-guide"
      fi
      set_mode ""
      sleep 2
      say "RESULT start $label: cold start from the car side worked"
    else
      say "RESULT start $label: the app's CarPlay scene did not connect"
    fi
    keep_applog "B-$label"
  fi
done

# ---------------------------------------------------------------------------------------------------------------------------
if [ "$A_OK" = 1 ] && [ -d "$APPS/ent/Runner.app" ]; then
  say "== C. the CarPlay scene declared in code: a copy of the app with no CarPlay entry in its Info.plist manifest"
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  make_variant dynamic 'Delete :UIApplicationSceneManifest:UISceneConfigurations:CPTemplateApplicationSceneSessionRoleApplication'
  run /usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest' "$APPS/dynamic/Runner.app/Info.plist"
  run xcrun simctl install "$UDID" "$APPS/dynamic/Runner.app"
  sleep 10
  if icon_in_carplay C-home-scene-in-code; then
    say "RESULT scene-in-code: the icon is on the CarPlay screen with no CarPlay scene in the manifest"
  else
    say "RESULT scene-in-code: the icon is NOT on the CarPlay screen shown"
  fi
  if car_launch C-scene-in-code; then
    wait_log 'dart hello' 45
    sleep 4
    shot_ext C-scene-in-code-map
    if grep -q 'made in code' "$(applog)" 2> /dev/null; then
      say "RESULT scene-in-code: the CarPlay scene connected from a configuration made in application(_:configurationForConnecting:options:)"
    else
      say "RESULT scene-in-code: the CarPlay scene connected, but the log has no 'made in code' line"
    fi
  else
    say "RESULT scene-in-code: the CarPlay scene did not connect"
  fi
  keep_applog C-scene-in-code
fi

# ---------------------------------------------------------------------------------------------------------------------------
say "== end"
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-3-end.txt" 2>&1
say "the Simulator's defaults, changes since the restart with extra options:"
diff "$OUT/ui/defaults-2-after-quit.txt" "$OUT/ui/defaults-3-end.txt" | head -n 80 | sed 's/^/        /' | tee -a "$LOG"
shot_host Z-end
xcrun simctl spawn "$UDID" log show --last 20m --style compact --predicate 'processImagePath ENDSWITH "Runner" AND eventMessage CONTAINS "SPIKE"' 2> /dev/null | tail -n 400 > "$OUT/applog/unified-log-spike-lines.txt"
xcrun simctl spawn "$UDID" log show --last 20m --style compact --predicate 'processImagePath ENDSWITH "Runner" AND (messageType == error OR messageType == fault)' 2> /dev/null | tail -n 200 > "$OUT/applog/unified-log-errors.txt"
cp "$HOME"/Library/Logs/DiagnosticReports/Runner* "$OUT/applog/" 2> /dev/null && say "crash reports of the app were found and copied to applog/"
say "pictures:"
ls -l "$OUT/shots" | sed 's/^/        /' | tee -a "$LOG"
grep 'RESULT' "$LOG" | sed 's/^\[[ 0-9]*s\] //' > "$OUT/results.txt"
say "capture took $((SECONDS - T0)) s"
rm -f "$OUT/.last"
exit 0

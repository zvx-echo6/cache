#!/bin/bash
# CarPlay spike, step 3: opens the Simulator's CarPlay display from a script, starts the scratch app from the car side only,
# and takes the pictures. Every command and what it printed goes to spike-out/steps.log; lines that start with RESULT are the
# answers. Nothing here stops at the first failure: each part reports and the next one runs.
#
# What rounds 1 and 2 established, and this round builds on:
#   - the Simulator keeps the CarPlay display's settings in its defaults: CarPlayConfig (width, height, scale, input kinds) and,
#     per device, SimulatorExternalDisplay = 2714 for "CarPlay". Written before the Simulator app starts, they bring the CarPlay
#     display up at that size with no click; the size must be there before the simulator boots, or the CarPlay screen keeps the
#     layout of the first size it saw.
#   - `xcrun simctl io <device> screenshot --display=external` photographs it.
#   - a click made with CGEvent on the Simulator's CarPlay window is a touch on the CarPlay screen.
#   - the app appears there with the CarPlay entitlement in a simulator build and no provisioning profile, not without it.
#   - started from the car side alone, the app's CarPlay scene connects and Dart runs; a list template shows.
#   - on the iOS 26.5 simulator every map template crashes the simulator's CarPlayTemplateUIHost
#     ('-[CPSTemplateInstance vehicleSupportsDestinationSharing]: unrecognized selector', in its map template's viewDidLoad).
#
#   - (round 3) the iOS 26.2 simulator's template host shows the map template; 26.4 crashes like 26.5.
#
#   R  the first installed iOS runtime whose template host survives a map template (oldest first; 26.2 in round 3)
#   A  on that runtime, 800 x 480 at 2x: the map, the bar buttons with Dart's value, taps on template buttons, guidance,
#      the drawn pieces in the base view, the search template, the phone joining the engine the car started
#   B  the other three test sizes, each from a fresh boot of the simulator
#   C  the CarPlay scene declared in code instead of the Info.plist manifest
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$RUNNER_TEMP/spike-out"
APPS="$RUNNER_TEMP/spike-apps"
TOOL="$RUNNER_TEMP/spiketool"
UDID=""
DEVICE="iPhone"
RUNTIME=""
SIMAPP="$(xcode-select -p)/Applications/Simulator.app"
mkdir -p "$OUT/shots" "$OUT/host" "$OUT/ui" "$OUT/applog"
LOG="$OUT/steps.log"
T0=$SECONDS
WAYS="1 2 3"
ICON_X=0
ICON_Y=0
HOST_FOUND=""
ANCHOR=""
OPENED_HOW=""
CAR_W=800
CAR_H=480
CAR_S=2

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
  HOST_FOUND=""
  case "$found" in
    found*)
      # shellcheck disable=SC2086
      set -- $found
      # The dock at the side shows a small icon of the last app (about 800 pixels of it here); the grid's icon is about 3300.
      if [ "${4#count=}" -lt 1800 ]; then
        say "  that is the small icon in the dock, not the app grid"
        return 1
      fi
      HOST_FOUND="$found"
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
  # The grid's icon is 60 points wide, the dock's 29.
  if [ "$(echo "$5" | cut -d, -f3)" -lt $((45 * CAR_S)) ]; then
    say "  that is the small icon in the dock, not the app grid"
    return 1
  fi
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

go_home() {  # the dock's last button (bottom left in both layouts, 26 points in from each edge) shows the app grid
  if [ -n "$ANCHOR" ]; then
    tap_carplay $((26 * CAR_S)) $((CAR_H - 26 * CAR_S))
    sleep 3
    return 0
  fi
  local win x y
  win=$(carplay_window)
  [ -n "$win" ] || return 1
  # shellcheck disable=SC2086
  set -- $win
  # without an anchor: by the window, whose screen starts about 27 points in and ends about 25 points above its bottom edge
  x=$((${1%.*} + 27 + 26 * ${3%.*} / (CAR_W / CAR_S + 54)))
  y=$((${2%.*} + ${4%.*} - 25 - 26 * ${3%.*} / (CAR_W / CAR_S + 54)))
  say "  clicking the dock's last button by the window's place ($x,$y)"
  click_at "$x" "$y" "${WAYS%% *}" > /dev/null
  sleep 3
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
      if [ -n "$HOST_FOUND" ] && xcrun simctl io "$UDID" screenshot --type=png --display=external "$OUT/.anchor.png" > /dev/null 2>&1; then
        anchor "$OUT/.anchor.png" "$HOST_FOUND"
      fi
      click_at "$ICON_X" "$ICON_Y" "$way"
      if wait_log 'carplay didConnect' 20; then
        say "the app's CarPlay scene connected ($label, click way $way)"
        WAYS="$way 1 2 3"
        return 0
      fi
      say "no CarPlay scene 20 s after the click ($label, way $way)"
      shot_ext "$label-after-click$way"
    else
      say "the app grid's icon was not found ($label, try $way): the dock's last button, then again"
      go_home
    fi
  done
  shot_host "$label-launch-failed"
  return 1
}

set_start() {  # what the app's CarPlay scene shows when it connects (AppDelegate.swift, start words)
  local c
  c=$(container)
  [ -n "$c" ] || { say "start words '$1': no app container"; return 1; }
  mkdir -p "$c/Documents"
  printf '%s' "$1" > "$c/Documents/spike-start.txt"
}

drop_applog() {
  local f
  f=$(applog)
  [ -n "$f" ] && rm -f "$f"
}

disconnects() {  # how many times the app's CarPlay scene was disconnected, by its log
  local f n
  f=$(applog)
  n=$(grep -c 'carplay didDisconnect' "$f" 2> /dev/null)
  echo "${n:-0}"
}

quit_simulator() {
  limit 30 osascript -e 'tell application "System Events" to tell process "Simulator" to click menu item "Quit Simulator" of menu 1 of menu bar item "Simulator" of menu bar 1' > /dev/null 2>&1
  local i
  for i in 1 2 3 4 5 6 7 8; do
    pgrep -x Simulator > /dev/null || break
    sleep 1
  done
  pgrep -x Simulator > /dev/null && { say "  the Simulator app is still running: killall"; killall Simulator; sleep 3; }
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1
}

write_carplay_config() {  # write_carplay_config <width> <height> <scale>: what the "TV Out Extended Setup" window would save
  run defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES
  run defaults write com.apple.iphonesimulator CarPlayConfig "<dict><key>width</key><integer>$1</integer><key>height</key><integer>$2</integer><key>scale</key><integer>$3</integer><key>hasTouchScreen</key><true/><key>hasTouchScreenLofi</key><false/><key>hasBackButton</key><false/><key>hasHomeButton</key><false/><key>hasWheel</key><false/><key>hasWheelBump</key><false/><key>stark</key><true/><key>protocols</key><array/></dict>"
}

open_carplay() {  # boots the simulator, starts the Simulator app and waits for the CarPlay window; says how it came up
  local end shown=0 menu=0 w
  OPENED_HOW="from the saved defaults alone, with no click"
  RUN_LINES=4 run xcrun simctl bootstatus "$UDID" -b
  run open -a "$SIMAPP" --args -CurrentDeviceUDID "$UDID"
  end=$((SECONDS + 200))
  while [ "$SECONDS" -lt "$end" ]; do
    w=$(sim_windows)
    case "$w" in
      *CarPlay*)
        sleep 6
        say "the CarPlay window is up, $OPENED_HOW. Simulator windows: $(sim_windows | tr '\n' ';')"
        return 0
        ;;
      *"TV Out Extended Setup"*)
        say "  the options window is showing: clicking Run"
        limit 30 osascript -e 'tell application "System Events" to tell process "Simulator" to click button "Run" of window "TV Out Extended Setup"' >> "$LOG" 2>&1
        OPENED_HOW="after Run in the options window"
        sleep 4
        continue
        ;;
      *"|"*)
        [ "$shown" = 0 ] && shown=$SECONDS
        if [ "$menu" = 0 ] && [ $((SECONDS - shown)) -ge 45 ]; then
          menu=1
          front
          say "  no CarPlay window 45 s after the device window: the menu instead: $(osa sim_external CarPlay)"
          OPENED_HOW="after the menu click (the defaults alone did not open it)"
        fi
        ;;
    esac
    sleep 3
  done
  say "no CarPlay window. Simulator windows: $(sim_windows | tr '\n' ';')"
  return 1
}

fill_options_window() {  # the fallback for a size the defaults did not give: the window's own boxes, then Run
  say "  filling the options window: $(osa sim_options "$1" "$2" "$3" | tr '\n' ';')"
}

host_crash_reports() {  # what the Mac recorded about the simulator's crashed template host: the reason and where
  local dir="$HOME/Library/Logs/DiagnosticReports" f
  sleep 5
  mkdir -p "$OUT/crashes"
  for f in "$dir"/CarPlayTemplateUIHost*.ips "$dir"/Runner*.ips; do
    [ -f "$f" ] && cp "$f" "$OUT/crashes/$RUNTIME-$(basename "$f")" 2> /dev/null
  done
  say "crash reports on the Mac: $(ls "$dir" 2> /dev/null | grep -c .) files, $(ls "$dir" 2> /dev/null | grep -c CarPlayTemplateUIHost) of the template host"
  say "the template host's reason, from the simulator's log:"
  xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'process == "CarPlayTemplateUIHost" AND eventMessage CONTAINS[c] "terminating app"' 2> /dev/null | grep -i -A9 'terminating app' | tail -n 11 | cut -c1-400 | sed 's/^/        /' | tee -a "$LOG"
  f=$(ls -t "$dir"/CarPlayTemplateUIHost*.ips 2> /dev/null | head -n 1)
  if [ -n "$f" ]; then
    say "the newest report, $(basename "$f"):"
    python3 -I "$HERE/crash_summary.py" "$f" 2>&1 | head -n 16 | sed 's/^/        /' | tee -a "$LOG"
  fi
}

anchor() {  # remembers where the CarPlay screen sits on the Mac screen, from the icon seen in both pictures
  local ext host
  ext=$(python3 -I "$HERE/find_icon.py" ext "$1" 2>&1 | tail -n 1)
  host="$2"
  case "$ext$host" in *none*|*Error*) return 1 ;; esac
  # found <x> <y> count=.. box=x,y,w,h image=.. scale=..
  ANCHOR=$(python3 -I -c '
import sys
e, h = sys.argv[1].split(), sys.argv[2].split()
ew = float(e[4].split("=")[1].split(",")[2]); hw = float(h[4].split("=")[1].split(",")[2]) / float(h[6].split("=")[1])
print("%s %s %s %s %.5f" % (e[1], e[2], h[1], h[2], hw / ew))
' "$ext" "$host" 2>> "$LOG")
  [ -n "$ANCHOR" ] && say "  the CarPlay screen on the Mac screen: its pixel ($ANCHOR)"
}

tap_carplay() {  # tap_carplay <x> <y> in CarPlay pixels: a click at that place of the CarPlay window
  local at
  [ -n "$ANCHOR" ] || { say "  no anchor: cannot tap"; return 1; }
  # shellcheck disable=SC2086
  at=$(python3 -I -c '
import sys
ex, ey, hx, hy, k, x, y = [float(v) for v in sys.argv[1:8]]
print("%.1f %.1f" % (hx + (x - ex) * k, hy + (y - ey) * k))
' $ANCHOR "$1" "$2")
  # shellcheck disable=SC2086
  click_at $at "${WAYS%% *}" > /dev/null
  say "  tapped the CarPlay screen at pixel $1,$2 (Mac screen $at)"
}

try_variant() {  # try_variant <name> <start words>: 0 when the CarPlay scene was still connected 10 s after it connected
  local name="$1" words="$2"
  say "-- variant $name: start words '$words'"
  end_app
  drop_applog
  set_start "$words"
  set_mode ""
  if ! car_launch "V-$name"; then
    say "RESULT variant $name [$words]: the app's CarPlay scene did not connect"
    keep_applog "V-$name"
    return 1
  fi
  sleep 10
  shot_ext "variant-$name"
  if [ "$(disconnects)" -gt 0 ]; then
    say "RESULT variant $name [$words]: the CarPlay scene was DISCONNECTED within 10 s ($(disconnects) times): the template host did not survive it"
    keep_applog "V-$name"
    return 1
  fi
  say "RESULT variant $name [$words]: the CarPlay scene STAYED connected for 10 s"
  say "app log so far (V-$name; the app stays on the screen and its log goes on):"
  sed 's/^/        /' "$(applog)" | tee -a "$LOG"
  return 0
}

end_app() {  # ends the app's process; when it is on the CarPlay screen, the app grid first, so its icon can be clicked again
  if [ -n "$ANCHOR" ] && [ -n "$(xcrun simctl spawn "$UDID" launchctl list 2> /dev/null | grep "UIKitApplication:$BID")" ]; then
    go_home
  fi
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  sleep 2
}

start_best() {  # a cold start from the car side with the content that survives
  end_app
  drop_applog
  set_start "$BEST"
  set_mode ""
  car_launch "$1" || return 1
  if wait_log 'dart hello' 45; then say "Dart said hello over the channel"; else say "no hello from Dart in 45 s"; fi
  if wait_log 'car map drew frame 1' 15; then say "the map drew its first frame"; else say "no first-frame line from the map in 15 s"; fi
  sleep 4
  return 0
}

make_variant() {  # make_variant <name> <PlistBuddy command>: a copy of the entitled app with its Info.plist changed
  local dir="$APPS/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$APPS/ent/Runner.app" "$dir/"
  run /usr/libexec/PlistBuddy -c "$2" "$dir/Runner.app/Info.plist"
  run codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$dir/Runner.app"
}


size_check() {  # size_check <label> <W> <H>: photographs the CarPlay home screen and compares the picture's size; 0 when it matches
  local label="$1" got
  if ! shot_ext "$label-home"; then
    say "RESULT size $label: no picture of the CarPlay display"
    return 1
  fi
  got=$(pic_size "$OUT/shots/$label-home.png")
  if [ "$got" = "$2x$3" ]; then
    say "RESULT size $label: the CarPlay display's picture is $got pixels, as asked ($OPENED_HOW)"
    return 0
  fi
  say "RESULT size $label: asked for $2x$3, the CarPlay display's picture is $got pixels ($OPENED_HOW)"
  return 1
}

use_device() {  # use_device <runtime>: switches to that runtime's simulator (the one before is shut down); 1 when there is none
  local line
  line=$(grep "^$1|" "$OUT/devices.txt" | head -n 1)
  [ -n "$line" ] || return 1
  [ -n "$UDID" ] && quit_simulator
  RUNTIME="$1"
  UDID=$(echo "$line" | cut -d'|' -f2)
  DEVICE=$(echo "$line" | cut -d'|' -f3)
  ANCHOR=""
  say "simulator: $DEVICE, $RUNTIME ($UDID)"
  return 0
}

bring_up() {  # bring_up <W> <H> <S>: the defaults, a boot, the Simulator app, the CarPlay window, the app installed
  local try lit
  CAR_W=$1
  CAR_H=$2
  CAR_S=$3
  for try in 1 2; do
    quit_simulator
    ANCHOR=""
    write_carplay_config "$1" "$2" "$3"
    run defaults write com.apple.iphonesimulator DevicePreferences -dict "$UDID" '<dict><key>SimulatorExternalDisplay</key><integer>2714</integer></dict>'
    open_carplay || return 1
    # Round 3 had one boot whose CarPlay display stayed black: looked for, waited for, and booted again once.
    for lit in 1 2 3 4; do
      xcrun simctl io "$UDID" screenshot --type=png --display=external "$OUT/.lit.png" > /dev/null 2>&1
      case "$(python3 -I "$HERE/find_icon.py" lit "$OUT/.lit.png" 2> /dev/null)" in
        "lit 0.0"|"") say "  the CarPlay display is black (look $lit)"; sleep 8 ;;
        *) lit=ok; break ;;
      esac
    done
    [ "$lit" = ok ] && break
    say "RESULT black: the CarPlay display stayed black after boot $try at $1x$2"
    shot_host "black-$1x$2-boot$try"
  done
  [ "$lit" = ok ] || return 1
  if [ -n "$BID" ] && [ -z "$(container)" ]; then
    run xcrun simctl install "$UDID" "$APPS/ent/Runner.app"
    sleep 8
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------------------
say "== facts"
BID=""
if [ -d "$APPS/ent/Runner.app" ]; then
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/ent/Runner.app/Info.plist")
fi
say "built app: ${BID:-none}"
SCREEN_W=""
[ -x "$TOOL" ] && SCREEN_W=$("$TOOL" screen 2> /dev/null | awk '{print $3}')
[ -n "$SCREEN_W" ] || SCREEN_W=1024
say "Mac screen width in points: $SCREEN_W; simulators: $(tr '\n' ';' < "$OUT/devices.txt")"
BEST=""
GUIDE=""
A_OK=0
TRIED=""

# ---------------------------------------------------------------------------------------------------------------------------
say "== R. which runtime's template host survives a map template (800 x 480 at 2x)"
for rt in $(cut -d'|' -f1 "$OUT/devices.txt"); do
  [ "$rt" = "iOS-26-5" ] && [ -n "$TRIED" ] && continue  # round 2 answered it; tried again only when it is the only one
  use_device "$rt" || continue
  TRIED="$TRIED $rt"
  if ! bring_up 800 480 2; then
    say "RESULT runtime $rt: the CarPlay display did not come up"
    shot_host "R-$rt-no-carplay"
    continue
  fi
  say "RESULT open $rt: the CarPlay display came up $OPENED_HOW"
  size_check "$rt-800x480-2x" 800 480
  [ -n "$BID" ] || break
  if try_variant "$rt-map" ""; then
    say "RESULT runtime $rt: the map template is showing; the template host survives it"
    A_OK=1
    break
  fi
  say "RESULT runtime $rt: the map template crashed the template host"
  host_crash_reports
done

if [ "$A_OK" = 0 ] && [ -n "$BID" ] && [ -n "$UDID" ]; then
  say "no runtime shows the map template: the list template instead, for the sizes"
  BEST="list nomaplibre"
fi

pictures() {  # pictures <label>: what every size gets once the app is on the CarPlay screen
  local label="$1"
  shot_ext "$label-map"
  say "RESULT start $label: cold start from the car side; $(grep 'carplay didConnect' "$(applog)" 2> /dev/null | head -n 1 | sed 's/.*didConnect //; s/ contentStyle.*//'); $(grep 'layout bounds' "$(applog)" 2> /dev/null | tail -n 1 | sed 's/.*layout //')"
  if [ -n "$GUIDE" ]; then
    set_mode "$GUIDE"
    sleep 6
    shot_ext "$label-guide"
    set_mode "overlay $GUIDE"
    sleep 6
    shot_ext "$label-overlay-guide"
  fi
  set_mode "overlay"
  sleep 5
  shot_ext "$label-overlay"
  set_mode ""
  sleep 2
  say "RESULT start $label: $(disconnects) disconnects; map frames: $(grep -c 'car map drew frame' "$(applog)" 2> /dev/null) lines, $(grep -c 'fully rendered' "$(applog)" 2> /dev/null) full renders"
}

# ---------------------------------------------------------------------------------------------------------------------------
if [ "$A_OK" = 1 ]; then
  say "== A. $RUNTIME, 800 x 480 at 2x: the map, Dart's value, taps, guidance, drawn pieces, search, the phone joining"
  # The app is on the CarPlay screen from its cold start in R; its log still holds that start.
  if wait_log 'dart hello' 30; then
    wait_log 'fully rendered' 15 || say "no full-render line from the map yet"
    shot_ext 800x480-2x-map
    shot_phone 800x480-2x-phone-while-only-the-car-scene-runs
    shot_host A2-app-on-carplay
    say "RESULT car-first: scenes when Dart said hello: $(grep 'dart hello' "$(applog)" 2> /dev/null | head -n 1 | sed 's/.*scenes=//'); phone-scene lines in the log: $(grep -c 'phone scene' "$(applog)" 2> /dev/null)"
    say "RESULT map: $(grep -c 'car map drew frame' "$(applog)" 2> /dev/null) frame lines; $(grep 'layout bounds' "$(applog)" 2> /dev/null | tail -n 1 | sed 's/.*layout //')"
    # taps on template buttons: the trailing bar button (it carries Dart's value) and the first map button
    tap_carplay 688 45
    sleep 2
    tap_carplay 756 172
    sleep 2
    say "RESULT tap: the app logged: $(grep -E 'bar button pressed|map button pressed' "$(applog)" 2> /dev/null | sed 's/.*SPIKE //' | tr '\n' ';')"
    # guidance: which pictures on a maneuver the template host survives
    for g in guide-noimage guide-drawn guide; do
      before=$(disconnects)
      set_mode "$g"
      sleep 6
      if [ "$(disconnects)" -gt "$before" ]; then
        say "RESULT guidance $g: the CarPlay scene was disconnected after guidance started"
        set_mode ""
        keep_applog "A-$g"
        start_best "A-after-$g" || break
      else
        say "RESULT guidance $g: guidance is showing and the scene stayed connected"
        GUIDE="$g"
        shot_ext "800x480-2x-$g"
        set_mode ""
        sleep 3
      fi
    done
    set_mode "overlay"
    sleep 5
    shot_ext 800x480-2x-overlay
    if [ -n "$GUIDE" ]; then
      set_mode "overlay $GUIDE"
      sleep 6
      shot_ext 800x480-2x-overlay-guide
    fi
    set_mode "demo"
    sleep 14
    shot_ext 800x480-2x-demo-style
    set_mode ""
    sleep 3
    before=$(disconnects)
    set_mode "search"
    sleep 6
    shot_ext 800x480-2x-search-empty-box
    say "RESULT search: $(grep -c 'search asked for results' "$(applog)" 2> /dev/null) calls for results with the box untouched: $(grep 'search asked for results' "$(applog)" 2> /dev/null | head -n 2 | sed 's/.*SPIKE //' | tr '\n' ';'); disconnects since: $(($(disconnects) - before))"
    set_mode ""
    sleep 4
    say "-- the phone window joins the engine the car started"
    run xcrun simctl launch "$UDID" "$BID"
    sleep 10
    shot_phone 800x480-2x-phone-joined-the-engine
    shot_ext 800x480-2x-map-after-phone-joined
    if grep -q 'engine joined by phone' "$(applog)" 2> /dev/null; then
      say "RESULT phone-joins: the phone window attached to the engine the car side had started, in the same process: $(grep -E 'engine joined by phone|phone scene connected' "$(applog)" | sed 's/.*SPIKE //' | tr '\n' ';')"
    else
      say "RESULT phone-joins: no 'engine joined by phone' line"
    fi
  else
    say "RESULT car-first: no hello from Dart at 800 x 480"
  fi
  keep_applog A-800x480
fi

# ---------------------------------------------------------------------------------------------------------------------------
if [ -n "$UDID" ]; then
  say "== B. the other test sizes on $RUNTIME, each from a fresh boot with the size already in the defaults"
  for spec in "748 456 2" "1920 720 3" "900 1200 3"; do
    # shellcheck disable=SC2086
    set -- $spec
    W=$1
    H=$2
    S=$3
    label="${W}x${H}-${S}x"
    say "-- size $W x $H pixels at ${S}x"
    if ! bring_up "$W" "$H" "$S"; then
      say "RESULT size $label: the CarPlay display did not come up"
      shot_host "B-$label-no-carplay"
      continue
    fi
    size_check "$label" "$W" "$H"
    [ -n "$BID" ] || continue
    if start_best "B-$label"; then
      pictures "$label"
    else
      say "RESULT start $label: the app's CarPlay scene did not connect"
    fi
    shot_host "B-$label"
    keep_applog "B-$label"
  done
fi

# ---------------------------------------------------------------------------------------------------------------------------
if [ "$A_OK" = 1 ] && [ -n "$BID" ]; then
  say "== C. the CarPlay scene declared in code: a copy of the app with no CarPlay entry in its Info.plist manifest"
  end_app
  make_variant dynamic 'Delete :UIApplicationSceneManifest:UISceneConfigurations:CPTemplateApplicationSceneSessionRoleApplication'
  run /usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest' "$APPS/dynamic/Runner.app/Info.plist"
  run xcrun simctl install "$UDID" "$APPS/dynamic/Runner.app"
  sleep 8
  drop_applog
  set_start ""
  set_mode ""
  if car_launch C-scene-in-code; then
    wait_log 'dart hello' 45
    sleep 6
    shot_ext scene-in-code-map
    if grep -q 'made in code' "$(applog)" 2> /dev/null && [ "$(disconnects)" = 0 ]; then
      say "RESULT scene-in-code: with no CarPlay scene in the manifest the scene connected from a configuration made in application(_:configurationForConnecting:options:), and the map template is showing"
    else
      say "RESULT scene-in-code: connected, but 'made in code' lines: $(grep -c 'made in code' "$(applog)" 2> /dev/null), disconnects: $(disconnects)"
    fi
  else
    say "RESULT scene-in-code: the CarPlay scene did not connect"
  fi
  keep_applog C-scene-in-code
fi

# ---------------------------------------------------------------------------------------------------------------------------
say "== end"
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-3-end.txt" 2>&1
shot_host Z-end
xcrun simctl spawn "$UDID" log show --last 6m --style compact --predicate 'processImagePath ENDSWITH "Runner" AND (messageType == error OR messageType == fault)' 2> /dev/null | tail -n 150 > "$OUT/applog/unified-log-errors.txt"
say "pictures:"
ls -l "$OUT/shots" | sed 's/^/        /' | tee -a "$LOG"
grep 'RESULT' "$LOG" | sed 's/^\[[ 0-9]*s\] //' > "$OUT/results.txt"
say "capture took $((SECONDS - T0)) s"
rm -f "$OUT/.last" "$OUT/.anchor.png" "$OUT/.lit.png"
exit 0

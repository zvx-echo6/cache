#!/bin/bash
# CarPlay harness, step 3: for each size asked for, the Simulator's CarPlay display at that size (from a fresh boot), the
# harness app started from the car side by a click on its icon, and pictures of the CarPlay display: the screen as it comes
# up, then the map in its three phases (looking at the map, choosing a route, guiding) in the car's dark setting and in the
# light one, and the panning state. Then the phone's window is opened once, to see it join. Every command and what it printed goes to harness-out/steps.log; results.txt has one line
# per answer, starting with OK or FAILED.
#
#   HARNESS_SIZES   the screens to draw, "WIDTHxHEIGHT@SCALE" in pixels, space separated
#   HARNESS_UDID    the simulator (prepare.sh)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$RUNNER_TEMP/harness-out"
APPS="$RUNNER_TEMP/harness-apps"
TOOL="$RUNNER_TEMP/screentool"
UDID="${HARNESS_UDID:?no simulator was chosen}"
DEVICE="${HARNESS_DEVICE:-iPhone}"
SIZES="${HARNESS_SIZES:-748x456@2 800x480@2 1920x720@3 900x1200@3}"
SIMAPP="$(xcode-select -p)/Applications/Simulator.app"
mkdir -p "$OUT/shots" "$OUT/host" "$OUT/logs"
LOG="$OUT/steps.log"
RESULTS="$OUT/results.txt"
: > "$RESULTS"
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
STREAM_PID=""
STREAM=""

say() { printf '[%4ds] %s\n' "$((SECONDS - T0))" "$*" | tee -a "$LOG"; }
result() { say "RESULT $*"; echo "$*" >> "$RESULTS"; }

run() {  # runs a command, logging it and what it printed
  say "\$ $*"
  "$@" > "$OUT/.last" 2>&1
  local rc=$?
  head -n "${RUN_LINES:-40}" "$OUT/.last" | sed 's/^/        /' | tee -a "$LOG"
  [ "$rc" = 0 ] || say "  (exit $rc)"
  return $rc
}

limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # limit <seconds> <command...>: no script may hang the job

osa() { limit 60 osascript "$HERE/$1.applescript" "${@:2}" 2>&1; }

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
      if wait_log 'car scene connected' 25; then
        say "the app's CarPlay scene connected ($label, click way $way)"
        WAYS="$way 1 2 3"
        return 0
      fi
      say "no 'car scene connected' line 25 s after the click ($label, way $way)"
      shot_ext "$label-after-click$way"
    else
      say "the app grid's icon was not found ($label, try $way): the dock's last button, then again"
      go_home
    fi
  done
  shot_host "$label-launch-failed"
  return 1
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

start_stream() {  # the app's own log lines (the car scene's, the engine's), into a file, for as long as this boot lasts
  STREAM="$OUT/logs/app-$1.txt"
  : > "$STREAM"
  xcrun simctl spawn "$UDID" log stream --level info --style compact \
    --predicate 'subsystem == "co.cache.car" OR (processImagePath ENDSWITH "Runner" AND (eventMessage CONTAINS "Flutter engine" OR eventMessage CONTAINS "phone scene" OR eventMessage CONTAINS "harness steps"))' \
    >> "$STREAM" 2>&1 &
  STREAM_PID=$!
  sleep 3
}

stop_stream() {
  [ -n "$STREAM_PID" ] && kill "$STREAM_PID" > /dev/null 2>&1
  STREAM_PID=""
}

wait_log() {  # wait_log <text> <seconds>: 0 as soon as the app's log has the text
  local end=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$end" ]; do
    grep -q -- "$1" "$STREAM" 2> /dev/null && return 0
    sleep 1
  done
  return 1
}

log_count() {  # log_count <text>: how many of the app's log lines have the text
  local n
  n=$(grep -c -- "$1" "$STREAM" 2> /dev/null)
  echo "${n:-0}"
}

wait_more() {  # wait_more <text> <count before> <seconds>: 0 as soon as the app's log has more lines with the text than before
  local end=$((SECONDS + $3))
  while [ "$SECONDS" -lt "$end" ]; do
    [ "$(log_count "$1")" -gt "$2" ] && return 0
    sleep 1
  done
  return 1
}

notify() {  # notify <next|day|night>: asks the harness's own plugin in the app (steps_plugin), by a Darwin notification
  run xcrun simctl spawn "$UDID" notifyutil -p "org.example.carharness.$1"
}

MAP_MISSING=""
MAP_NOTES=""

map_step() {  # map_step <next|day|night> <log text to wait for> <picture name or ""> : one step of the map pictures
  local before
  before=$(log_count "$2")
  notify "$1"
  if ! wait_more "$2" "$before" 20; then
    MAP_MISSING="$MAP_MISSING [$1: no new line '$2']"
  fi
  sleep 3
  [ -n "$3" ] && shot_ext "$3"
  return 0
}

map_pictures() {  # map_pictures <label>: the map in the three phases, in the car's own dark setting and in the light one
  local label="$1" before x y found=""
  MAP_MISSING=""
  MAP_NOTES=""
  # The Simulator's car is in its dark setting. The app's style has to be the one drawn before the first picture.
  wait_log 'car map: style loaded, dark' 40 || MAP_MISSING="$MAP_MISSING [no 'style loaded, dark' line]"
  sleep 3
  shot_ext "$label-map-dark-browsing"
  # The light pictures: the harness tells the car scene that the car switched to day, through the call CarPlay makes. The map
  # redraws light; Apple's own bar and buttons stay in the Simulator car's dark look, which is not how a real car in its day
  # setting shows them. Hence the name of these pictures.
  map_step day 'car map: style loaded, light' "$label-map-light-told-by-harness-browsing"
  map_step next 'car link: trip previewing' "$label-map-light-told-by-harness-previewing"
  map_step next 'car link: trip guiding' "$label-map-light-told-by-harness-guiding"
  map_step night 'car map: style loaded, dark' "$label-map-dark-guiding"
  map_step next 'car link: trip browsing' ""
  map_step next 'car link: trip previewing' "$label-map-dark-previewing"
  # The panning state. The Pan button is the first of the map buttons, which stand in a column 22 points in from the trailing
  # edge: taps go down that column from under the bar until the app says panning began.
  if [ -z "$ANCHOR" ]; then
    MAP_MISSING="$MAP_MISSING [the CarPlay screen's place on the Mac screen is not known: no tap for the Pan button]"
    return 0
  fi
  before=$(log_count 'car map: panning began')
  x=$((CAR_W - 22 * CAR_S))
  y=$((58 * CAR_S))
  while [ "$y" -lt $((CAR_H - 6 * CAR_S)) ]; do
    tap_carplay "$x" "$y"
    if wait_more 'car map: panning began' "$before" 2; then found="$x,$y"; break; fi
    y=$((y + 14 * CAR_S))
  done
  if [ -n "$found" ]; then
    sleep 3
    shot_ext "$label-map-panning"
    MAP_NOTES="the Pan button answered a tap at pixel $found"
    # Done, the one text button of the bar while panning, at the bar's trailing end.
    before=$(log_count 'car map: panning ended')
    tap_carplay $((CAR_W - 34 * CAR_S)) $((22 * CAR_S))
    if wait_more 'car map: panning ended' "$before" 3; then
      sleep 2
      shot_ext "$label-map-after-done"
      MAP_NOTES="$MAP_NOTES; Done ended panning"
    else
      MAP_NOTES="$MAP_NOTES; Done did not answer a tap at pixel $((CAR_W - 34 * CAR_S)),$((22 * CAR_S)) (its place is to be read off the picture)"
    fi
  else
    shot_ext "$label-map-no-pan-button"
    MAP_MISSING="$MAP_MISSING [no tap down the map buttons' column began panning]"
  fi
}

bring_up() {  # bring_up <W> <H> <S> <label>: the defaults, a boot, the Simulator app, the CarPlay window, the app installed
  local try lit
  CAR_W=$1
  CAR_H=$2
  CAR_S=$3
  for try in 1 2; do
    stop_stream
    quit_simulator
    ANCHOR=""
    write_carplay_config "$1" "$2" "$3"
    run defaults write com.apple.iphonesimulator DevicePreferences -dict "$UDID" '<dict><key>SimulatorExternalDisplay</key><integer>2714</integer></dict>'
    open_carplay || return 1
    # A boot whose CarPlay display stays black happens now and then: looked for, waited for, and booted again once.
    for lit in 1 2 3 4; do
      xcrun simctl io "$UDID" screenshot --type=png --display=external "$OUT/.lit.png" > /dev/null 2>&1
      case "$(python3 -I "$HERE/find_icon.py" lit "$OUT/.lit.png" 2> /dev/null)" in
        "lit 0.0"|"") say "  the CarPlay display is black (look $lit)"; sleep 8 ;;
        *) lit=ok; break ;;
      esac
    done
    [ "$lit" = ok ] && break
    say "the CarPlay display stayed black after boot $try at $1x$2"
    shot_host "black-$4-boot$try"
  done
  [ "$lit" = ok ] || return 1
  start_stream "$4"
  if [ -z "$(xcrun simctl get_app_container "$UDID" "$BID" data 2> /dev/null)" ]; then
    run xcrun simctl install "$UDID" "$APPS/car/Runner.app"
    sleep 8
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------------------
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/car/Runner.app/Info.plist" 2> /dev/null)
if [ -z "$BID" ]; then
  result "FAILED build: there is no harness app to show"
  exit 0
fi
SCREEN_W=""
[ -x "$TOOL" ] && SCREEN_W=$("$TOOL" screen 2> /dev/null | awk '{print $3}')
[ -n "$SCREEN_W" ] || SCREEN_W=1024
say "harness app $BID; simulator $DEVICE ($UDID); Mac screen $SCREEN_W points wide; sizes: $SIZES"
PHONE_DONE=0

for size in $SIZES; do
  W=${size%%x*}
  rest=${size#*x}
  H=${rest%%@*}
  S=${rest#*@}
  label="${W}x${H}-${S}x"
  case "$W$H$S" in *[!0-9]*|"") result "FAILED $size: not WIDTHxHEIGHT@SCALE"; continue ;; esac
  say "== $W x $H pixels at ${S}x"
  if ! bring_up "$W" "$H" "$S" "$label"; then
    result "FAILED $label: the CarPlay display did not come up"
    shot_host "$label-no-carplay"
    continue
  fi
  shot_ext "$label-home"
  got=$(pic_size "$OUT/shots/$label-home.png")
  [ "$got" = "${W}x${H}" ] || say "asked for ${W}x${H}, the CarPlay display's picture is $got"
  if car_launch "$label"; then
    sleep 4
    shot_ext "$label-car"
    line=$(grep 'car scene connected' "$STREAM" | tail -n 1 | sed 's/.*car scene connected/car scene connected/')
    # The car link: the app was opened from the car side alone, so the engine was started for the car scene; the stand-in
    # Dart side then says hello from the root widget's start-up (no view exists) and pushes its first recorded trip.
    if wait_log 'car link: trip browsing' 45; then
      # Opened from the car side alone: the engine's start line comes after the car scene's, in the same process.
      car_line=$(grep -n 'car scene connected' "$STREAM" | head -n 1 | cut -d: -f1)
      engine_line=$(grep -n 'The Flutter engine was started' "$STREAM" | head -n 1 | cut -d: -f1)
      if [ -n "$car_line" ] && [ -n "$engine_line" ] && [ "$engine_line" -gt "$car_line" ]; then
        started="the engine was started for the car scene"
      else
        started="the engine was already running when the car scene connected"
      fi
      link="$started; Dart said hello and its first trip reached the car link"
    else
      link=""
    fi
    if grep -q 'car scene disconnected' "$STREAM"; then
      result "FAILED $label: the car scene connected and was disconnected again ($line)"
      host_crash=1
    elif [ -z "$link" ]; then
      result "FAILED $label: the car scene is up ($line), but no trip reached the car link: Dart ready lines $(log_count 'car link: Dart is ready')"
    else
      result "OK $label: shots/$label-car.png, the display's picture is $got pixels; $line; $link"
      # The map: the three phases in the car's dark setting and in the light one, then the panning state.
      map_pictures "$label"
      area=$(grep 'car map: the bars and buttons take' "$STREAM" | tail -n 1 | sed 's/.*car map: //')
      if grep -q 'car scene disconnected' "$STREAM"; then
        result "FAILED $label map: the car scene was disconnected while the map was pictured"
        host_crash=1
      elif [ -n "$MAP_MISSING" ]; then
        result "FAILED $label map:$MAP_MISSING; $MAP_NOTES"
      else
        result "OK $label map: shots/$label-map-dark-{browsing,previewing,guiding}.png in the car's own dark setting; shots/$label-map-light-told-by-harness-{browsing,previewing,guiding}.png after the harness told the car scene the car switched to day (Apple's bar and buttons keep the Simulator car's dark look there); shots/$label-map-panning.png; $MAP_NOTES; $area"
      fi
    fi
  else
    # No log line is not proof of no screen: the picture decides when the icon grid is gone.
    shot_ext "$label-car"
    result "FAILED $label: no 'car scene connected' line after the clicks; see shots/$label-car.png"
  fi
  shot_host "$label"
  if [ "$PHONE_DONE" = 0 ]; then
    PHONE_DONE=1
    say "-- the phone's window, opened while the car scene runs"
    shot_phone "$label-phone-before"
    run xcrun simctl launch "$UDID" "$BID"
    sleep 10
    shot_phone "$label-phone-window"
    shot_ext "$label-car-after-phone"
    engines=$(grep -c 'The Flutter engine was started' "$STREAM")
    if [ "$engines" = 1 ] && ! grep -q 'car scene disconnected' "$STREAM"; then
      result "OK phone: the phone's window opened beside the car scene on the engine the car scene had started; one engine start in all (shots/$label-phone-window.png)"
    else
      result "FAILED phone: engine-start lines $engines (1 expected), car scene disconnected: $(grep -c 'car scene disconnected' "$STREAM")"
    fi
  fi
  say "the app's log lines at this size:"
  sed 's/^/        /' "$STREAM" | cut -c1-260 | tail -n 70 | tee -a "$LOG"
done

# ---------------------------------------------------------------------------------------------------------------------------
# The update case, on the phone alone. Builds before the shared engine named the storyboard in the phone's scene, and iOS may
# keep a scene session's configuration across an update. Two questions: does the app come up, with one engine, when its scene
# does bring the storyboard's window (a copy of the harness app with the storyboard key put back answers that for certain);
# and does iOS in fact bring it after that copy is replaced by the real build.
if [ -n "$STREAM" ] && [ -d "$APPS/car/Runner.app" ]; then
  say "== the update case: a scene that brings the storyboard's window"
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  run xcrun simctl uninstall "$UDID" "$BID"
  rm -rf "$APPS/old"
  mkdir -p "$APPS/old"
  cp -R "$APPS/car/Runner.app" "$APPS/old/"
  run /usr/libexec/PlistBuddy -c 'Add :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneStoryboardFile string Main' "$APPS/old/Runner.app/Info.plist"
  run codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$APPS/old/Runner.app"
  ls "$APPS/old/Runner.app/Base.lproj" 2>&1 | sed 's/^/        /' | tee -a "$LOG"
  : > "$STREAM"
  run xcrun simctl install "$UDID" "$APPS/old/Runner.app"
  sleep 5
  run xcrun simctl launch "$UDID" "$BID"
  sleep 10
  shot_phone update-1-scene-with-the-storyboard
  came=$(grep -c "came with the storyboard" "$STREAM")
  engines=$(grep -c 'The Flutter engine was started' "$STREAM")
  if [ "$came" = 1 ] && [ "$engines" = 1 ]; then
    result "OK update-1: a scene that brings the storyboard's window gets the shared engine's view controller in it; one engine started (shots/update-1-scene-with-the-storyboard.png)"
  else
    result "FAILED update-1: storyboard-window lines $came (1 expected), engine-start lines $engines (1 expected)"
  fi
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  sleep 2
  : > "$STREAM"
  run xcrun simctl install "$UDID" "$APPS/car/Runner.app"
  sleep 5
  run xcrun simctl launch "$UDID" "$BID"
  sleep 10
  shot_phone update-2-after-the-update
  came=$(grep -c "came with the storyboard" "$STREAM")
  engines=$(grep -c 'The Flutter engine was started' "$STREAM")
  if [ "$engines" = 1 ]; then
    result "OK update-2: after the update the app came up with one engine; iOS brought the old storyboard window: $([ "$came" = 0 ] && echo no || echo yes) (shots/update-2-after-the-update.png)"
  else
    result "FAILED update-2: engine-start lines $engines (1 expected) after the update; storyboard-window lines $came"
  fi
  say "the app's log lines in the update case:"
  sed 's/^/        /' "$STREAM" | cut -c1-260 | tail -n 20 | tee -a "$LOG"
fi

stop_stream
if [ "${host_crash:-0}" = 1 ]; then
  dir="$HOME/Library/Logs/DiagnosticReports"
  f=$(ls -t "$dir"/CarPlayTemplateUIHost*.ips 2> /dev/null | head -n 1)
  [ -n "$f" ] && { say "the simulator's template host crashed, $(basename "$f"):"; python3 -I "$HERE/crash_summary.py" "$f" 2>&1 | head -n 20 | sed 's/^/        /' | tee -a "$LOG"; }
fi
shot_host end
say "pictures:"
ls -l "$OUT/shots" | sed 's/^/        /' | tee -a "$LOG"
say "capture took $((SECONDS - T0)) s"
rm -f "$OUT/.last" "$OUT/.anchor.png" "$OUT/.lit.png"
exit 0

#!/bin/bash
# CarPlay harness, step 3: for each size asked for, the Simulator's CarPlay display at that size (from a fresh boot), the
# harness app started from the car side by a click on its icon, and pictures of the CarPlay display: the screen as it comes
# up, then the map in its three phases (looking at the map, choosing a route, guiding) in the car's dark setting and in the
# light one, the panning state and the map's buttons at work, the two lists (Saved places, Search) with the stand-in's
# recorded places, the routes to a place chosen there, and turn by turn along the stand-in's recorded drive. Then the phone's
# window is opened once, to see it join. Every command and what it printed goes to harness-out/steps.log; results.txt has one line
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
: > "$OUT/.began"
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

phone_window() {  # "x y w h" of the phone's own window in screen points, or nothing
  local hit=""
  if [ -x "$TOOL" ]; then
    hit=$("$TOOL" windows 2> /dev/null | awk '/\[Simulator\]/ && $4 == 0 && $7 > 100 && tolower($0) ~ /ios/ && tolower($0) !~ /carplay/ {print $5, $6, $7, $8; exit}')
  fi
  if [ -z "$hit" ]; then
    hit=$(sim_windows | awk -F'|' 'tolower($1) ~ /ios/ && tolower($1) !~ /carplay/ && $4 > 0 {print $2, $3, $4, $5; exit}')
  fi
  printf '%s' "$hit"
}

question_on_phone() {  # the Open button of the question iOS asks on the phone, in a small copy of the phone's picture: "found <x> <y> ... image=<w>x<h> ..." or "none ..."
  rm -f "$OUT/.phone.png" "$OUT/.phone-small.png"
  xcrun simctl io "$UDID" screenshot --type=png --display=internal "$OUT/.phone.png" > /dev/null 2>&1
  sips -Z 1024 "$OUT/.phone.png" --out "$OUT/.phone-small.png" > /dev/null 2>&1
  python3 -I "$HERE/find_icon.py" blue "$OUT/.phone-small.png" 2>> "$LOG" | tail -n 1
}

# A link opened from outside the app (simctl openurl here; a link in a message or a browser on a real phone) makes iOS ask on
# the phone "Open in "Cache"?" the first time after an install. The answer is a press on its Open, which only a click in the
# phone's window on the Mac screen can give: the window is brought to the front by a click on its title (which shows above
# the CarPlay window's), and the button is found on a picture of the Mac screen by its blue, or else by where the phone's
# screen sits in its window (measured on this Simulator's window: 18 of 299 points in from the left, 263 of 299 wide, its
# bottom 12.5 of 681 points above the window's).
answer_open() {  # answer_open <link lines in the log before> <picture name>: 0 when the link reached Dart
  local before="$1" name="$2" try found="" win host at places place
  for try in 1 2 3 4 5 6; do
    sleep 2
    [ "$(log_count 'harness steps: link')" -gt "$before" ] && { say "  the link reached Dart with no question asked"; return 0; }
    found=$(question_on_phone)
    case "$found" in found*) break ;; esac
  done
  case "$found" in
    found*) ;;
    *) say "  the phone shows no question and Dart has no link: $found"; return 1 ;;
  esac
  say "  iOS asks on the phone whether to open the link; its Open button in the phone's picture: $found"
  shot_phone "$name-question"
  win=$(phone_window)
  [ -n "$win" ] || { say "  the phone's window was not found on the Mac screen"; return 1; }
  # shellcheck disable=SC2086
  set -- $win
  click_at "$(($1 + $3 / 2))" "$(($2 + 14))" "${WAYS%% *}" > /dev/null
  say "  the phone's window ($win) brought to the front by a click on its title"
  sleep 2
  # (screencapture does not write to a file whose name begins with a dot.)
  host=""
  rm -f "$OUT/host/$name-question.png"
  screencapture -x "$OUT/host/$name-question.png" 2>> "$LOG"
  if [ -s "$OUT/host/$name-question.png" ]; then
    # shellcheck disable=SC2086
    host=$(python3 -I "$HERE/find_icon.py" blue "$OUT/host/$name-question.png" "$SCREEN_W" $win 2>> "$LOG" | tail -n 1)
    sips -s format jpeg -s formatOptions 60 "$OUT/host/$name-question.png" --out "$OUT/host/$name-question.jpg" > /dev/null 2>&1 \
      && rm -f "$OUT/host/$name-question.png"
  fi
  say "  the Open button on the Mac screen, inside the phone's window: $host"
  places=""
  case "$host" in
    found*)
      # shellcheck disable=SC2086
      set -- $host
      places="$2,$3"
      ;;
  esac
  # shellcheck disable=SC2086
  at=$(python3 -I -c '
import sys
f = sys.argv[1].split()
size = [v for v in f if v.startswith("image=")][0][6:].split("x")
fx, fy = float(f[1]) / float(size[0]), float(f[2]) / float(size[1])
wx, wy, ww, wh = [float(v) for v in sys.argv[2:6]]
sw = ww * 263.0 / 299.0
sh = sw * float(size[1]) / float(size[0])
print("%.1f,%.1f" % (wx + ww * 18.0 / 299.0 + fx * sw, wy + wh - wh * 12.5 / 681.0 - sh + fy * sh))
' "$found" $win 2>> "$LOG")
  places="$places $at"
  for place in $places; do
    click_at "${place%,*}" "${place#*,}" "${WAYS%% *}" > /dev/null
    say "  clicked Open at Mac screen $place"
    if wait_more 'harness steps: link' "$before" 20; then
      say "  the link reached Dart after the press on Open"
      return 0
    fi
    case "$(question_on_phone)" in
      found*) ;;
      *) say "  the question has gone, but Dart has no link"; return 1 ;;
    esac
  done
  say "  the question is still on the phone after the clicks"
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

app_crashes() {  # the app's own crash reports made since this job began, one file a line (a simulator's are the Mac's)
  find "$HOME/Library/Logs/DiagnosticReports" -name 'Runner*.ips' -newer "$OUT/.began" 2> /dev/null
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
  local end began shown=0 menu=0 w
  OPENED_HOW="from the saved defaults alone, with no click"
  RUN_LINES=4 run xcrun simctl bootstatus "$UDID" -b
  run open -a "$SIMAPP" --args -CurrentDeviceUDID "$UDID"
  began=$SECONDS
  end=$((SECONDS + 200))
  while [ "$SECONDS" -lt "$end" ]; do
    w=$(sim_windows)
    # Now and then the Simulator stops answering questions about its windows (seen with a CarPlay display that stayed black).
    # The Mac's own window list still has the Simulator's two windows then (the phone and the CarPlay display): that is
    # enough to go on, and the black display is found by the look that follows and booted again.
    if [ -z "$w" ] && [ $((SECONDS - began)) -ge 45 ] && [ -x "$TOOL" ] \
        && [ "$("$TOOL" windows 2> /dev/null | awk '/\[Simulator\]/ && $4 == 0 && $7 > 100 {n++} END{print n + 0}')" -ge 2 ]; then
      say "the CarPlay window is in the Mac's window list, but the Simulator does not answer about its windows ($OPENED_HOW)"
      return 0
    fi
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
  xcrun simctl spawn "$UDID" log stream --level debug --style compact \
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
BUTTONS=""
BUTTONS_MISSING=""

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

map_pictures() {  # map_pictures <label>: the map in the three phases, dark and light; then the panning state and the buttons
  local label="$1" before x y found="" free ft fl fb fr ax ay moved="" rx ry
  MAP_MISSING=""
  MAP_NOTES=""
  BUTTONS=""
  BUTTONS_MISSING=""
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
  if [ -z "$found" ]; then
    shot_ext "$label-map-no-pan-button"
    MAP_MISSING="$MAP_MISSING [no tap down the map buttons' column began panning]"
    return 0
  fi
  sleep 3
  shot_ext "$label-map-panning"
  MAP_NOTES="the Pan button answered a tap at pixel $found"

  # The buttons at work. First one of CarPlay's panning arrows, the one at the top of the free area: taps go down the middle
  # of the free area from its top until the app says the camera stopped following the position.
  free=$(grep 'car map: the bars and buttons take' "$STREAM" | tail -n 1 | sed -E 's/.*take top ([0-9]+) left ([0-9]+) bottom ([0-9]+) right ([0-9]+) of.*/\1 \2 \3 \4/')
  read -r ft fl fb fr <<< "$free"
  FREE_LEFT=${fl:-0}
  case "$ft$fl$fb$fr" in
    *[!0-9]*|"") BUTTONS_MISSING="$BUTTONS_MISSING [the free area was not said in the log: no tap for a panning arrow]"; return 0 ;;
  esac
  ax=$(( (fl * CAR_S + CAR_W - fr * CAR_S) / 2 ))
  ay=$(( (ft + 8) * CAR_S ))
  before=$(log_count 'car map: following the position: false')
  while [ "$ay" -le $(( (ft + 62) * CAR_S )) ]; do
    tap_carplay "$ax" "$ay"
    if wait_more 'car map: following the position: false' "$before" 2; then moved="$ax,$ay"; break; fi
    ay=$((ay + 10 * CAR_S))
  done
  if [ -n "$moved" ]; then
    sleep 2
    shot_ext "$label-map-panned"
    BUTTONS="a panning arrow moved the map (tap at pixel $moved)"
  else
    BUTTONS_MISSING="$BUTTONS_MISSING [no panning arrow answered taps down the middle of the free area]"
  fi
  # Done, the one text button of the bar while panning, at the bar's trailing end.
  before=$(log_count 'car map: panning ended')
  tap_carplay $((CAR_W - 34 * CAR_S)) $((22 * CAR_S))
  if wait_more 'car map: panning ended' "$before" 3; then
    sleep 2
    shot_ext "$label-map-after-done"
    BUTTONS="$BUTTONS; Done ended panning"
  else
    BUTTONS_MISSING="$BUTTONS_MISSING [Done did not answer a tap at pixel $((CAR_W - 34 * CAR_S)),$((22 * CAR_S))]"
    return 0
  fi
  [ -n "$moved" ] || return 0
  # Recenter, which joined the column because the map was moved. The column grows upwards, so Recenter stands where the Pan
  # button stood: 20 points under the tap that found Pan is its middle, give or take a few points.
  rx=${found%,*}
  ry=$(( ${found#*,} + 20 * CAR_S ))
  before=$(log_count 'car map: following the position: true')
  tap_carplay "$rx" "$ry"
  if wait_more 'car map: following the position: true' "$before" 3; then
    sleep 2
    shot_ext "$label-map-recentered"
    BUTTONS="$BUTTONS; Recenter put the camera back and left the column"
  else
    shot_ext "$label-map-no-recenter"
    BUTTONS_MISSING="$BUTTONS_MISSING [Recenter did not answer a tap at pixel $rx,$ry]"
    return 0
  fi
  # Zoom in, one place further down the column. The app has no log line for it: the picture shows it.
  tap_carplay "$rx" $((ry + 44 * CAR_S))
  sleep 2
  shot_ext "$label-map-zoomed-in"
}

LISTS=""
LISTS_MISSING=""
FREE_LEFT=0

tap_until() {  # tap_until <log text> <seconds a try> <x> <y> [<x> <y>...]: taps each place in turn until the app's log has a new line with the text; prints the place that did it
  local text="$1" each="$2" before
  shift 2
  before=$(log_count "$text")
  while [ $# -ge 2 ]; do
    tap_carplay "$1" "$2" > /dev/null
    if wait_more "$text" "$before" "$each"; then echo "$1,$2"; return 0; fi
    shift 2
  done
  return 1
}

list_pictures() {  # list_pictures <label>: Saved places and Search, opened by their buttons, with the stand-in's recorded places
  local label="$1" at key before
  local right=$((CAR_W - 27 * CAR_S)) top=$((28 * CAR_S))
  LISTS=""
  LISTS_MISSING=""
  # Saved places: the bar's trailing button on the map.
  before=$(log_count 'car lists: saved places shown, 3 rows')
  if ! at=$(tap_until 'car lists: saved places opened' 3 "$right" "$top"); then
    shot_ext "$label-lists-no-saved-button"
    LISTS_MISSING=" [Saved places did not open by a tap at pixel $right,$top]"
    return 0
  fi
  if wait_more 'car lists: saved places shown, 3 rows' "$before" 12; then
    sleep 2
    shot_ext "$label-saved"
    LISTS="Saved places opened by its button and listed the three recorded places"
  else
    shot_ext "$label-saved"
    LISTS_MISSING="$LISTS_MISSING [the saved places list did not say it shows 3 rows]"
  fi
  # The phone has no saved places: the list's own words for that.
  before=$(log_count 'car lists: saved places shown, 0 rows')
  notify nosaved
  if wait_more 'car lists: saved places shown, 0 rows' "$before" 12; then
    sleep 2
    shot_ext "$label-saved-none"
    LISTS="$LISTS; with none saved it says so"
  else
    LISTS_MISSING="$LISTS_MISSING [the list did not empty when the saved places went]"
  fi
  before=$(log_count 'car lists: saved places shown, 3 rows')
  notify saved
  wait_more 'car lists: saved places shown, 3 rows' "$before" 12 || LISTS_MISSING="$LISTS_MISSING [the list did not fill again when the saved places came back]"
  # Search, from the list's own button (the bar's trailing end again, give or take).
  before=$(log_count 'car lists: search shown, 3 saved places under the empty box')
  if ! at=$(tap_until 'car lists: search opened' 3 "$right" "$top" $((right - 14 * CAR_S)) "$top" $((right + 8 * CAR_S)) "$top"); then
    shot_ext "$label-lists-no-search-button"
    LISTS_MISSING="$LISTS_MISSING [Search did not open from the list by taps near pixel $right,$top]"
    return 0
  fi
  if wait_more 'car lists: search shown, 3 saved places under the empty box' "$before" 10; then
    sleep 2
    shot_ext "$label-search-empty"
    LISTS="$LISTS; Search opened from the list (tap at pixel $at) with the saved places under its empty box"
  else
    shot_ext "$label-search-empty"
    LISTS_MISSING="$LISTS_MISSING [Search did not say it shows the 3 saved places under its empty box]"
  fi
  # One key of CarPlay's keyboard, any letter: a few places over the keyboard are tried until the app says one character
  # was typed. The stand-in finds the recorded places for one character and nothing for more.
  before=$(log_count 'car lists: search shown, 3 places')
  if ! key=$(tap_until 'car lists: search asked, 1 characters' 2 \
      $((CAR_W * 50 / 100)) $((CAR_H * 65 / 100)) $((CAR_W * 44 / 100)) $((CAR_H * 65 / 100)) $((CAR_W * 56 / 100)) $((CAR_H * 53 / 100)) \
      $((CAR_W * 50 / 100)) $((CAR_H * 79 / 100)) $((CAR_W * 38 / 100)) $((CAR_H * 60 / 100)) $((CAR_W * 62 / 100)) $((CAR_H * 72 / 100))); then
    shot_ext "$label-search-no-key"
    LISTS_MISSING="$LISTS_MISSING [no key of the keyboard answered the taps]"
    return 0
  fi
  if wait_more 'car lists: search shown, 3 places' "$before" 8; then
    sleep 1
    shot_ext "$label-search-found"
    LISTS="$LISTS; a typed letter (tap at pixel $key) found the three recorded places"
  else
    shot_ext "$label-search-found"
    LISTS_MISSING="$LISTS_MISSING [Search did not say it shows the 3 places found]"
  fi
  before=$(log_count 'car lists: search shown, no places found')
  tap_carplay "${key%,*}" "${key#*,}"
  if wait_more 'car lists: search shown, no places found' "$before" 8; then
    sleep 1
    shot_ext "$label-search-none"
    LISTS="$LISTS; a second letter found nothing and it says so"
  else
    shot_ext "$label-search-none"
    LISTS_MISSING="$LISTS_MISSING [Search did not say that nothing was found]"
  fi
  # Out again: CarPlay's close button of the search screen, then the list's Back. On a wide screen the search screen does not
  # reach the trailing edge, so its close button stands further in: three places are tried, from the edge inwards.
  if at=$(tap_until 'car lists: search closed' 4 "$right" $((24 * CAR_S)) $((CAR_W - 47 * CAR_S)) $((26 * CAR_S)) $((CAR_W - 67 * CAR_S)) $((26 * CAR_S))); then
    sleep 2
    shot_ext "$label-after-search"
    LISTS="$LISTS; the close button (tap at pixel $at) left Search"
  else
    shot_ext "$label-search-not-closed"
    LISTS_MISSING="$LISTS_MISSING [Search did not close by a tap on its close button]"
    return 0
  fi
  if at=$(tap_until 'car lists: saved places closed' 3 $(( (FREE_LEFT + 18) * CAR_S )) $((22 * CAR_S)) $(( (FREE_LEFT + 32) * CAR_S )) $((22 * CAR_S)) $(( (FREE_LEFT + 46) * CAR_S )) $((22 * CAR_S)) $(( (FREE_LEFT + 24) * CAR_S )) $((30 * CAR_S))); then
    sleep 2
    shot_ext "$label-after-lists"
    LISTS="$LISTS; Back (tap at pixel $at) left the list for the map"
  else
    shot_ext "$label-saved-not-closed"
    LISTS_MISSING="$LISTS_MISSING [the list's Back did not answer taps at the bar's leading end]"
  fi
}

ROUTES=""
ROUTES_MISSING=""

free_area() {  # the free area the app said last, in points: "top left bottom right"
  grep 'car map: the bars and buttons take' "$STREAM" | tail -n 1 | sed -E 's/.*take top ([0-9]+) left ([0-9]+) bottom ([0-9]+) right ([0-9]+) of.*/\1 \2 \3 \4/'
}

to_browsing() {  # the stand-in Dart side back on its first trip (looking at the map), whatever it showed last
  local phase before
  phase=$(grep 'car link: trip ' "$STREAM" | tail -n 1 | sed -E 's/.*car link: trip ([a-z]+),.*/\1/')
  while [ "$phase" = previewing ] || [ "$phase" = guiding ]; do
    before=$(log_count 'car link: trip ')
    notify next
    wait_more 'car link: trip ' "$before" 10 || return 1
    phase=$(grep 'car link: trip ' "$STREAM" | tail -n 1 | sed -E 's/.*car link: trip ([a-z]+),.*/\1/')
  done
  sleep 1
}

open_place() {  # open_place <row 1..3>: Saved places by its button, then a tap on that row; 0 when the app says a place was chosen
  local row="$1" before x y
  before=$(log_count 'car lists: saved places shown, 3 rows')
  tap_until 'car lists: saved places opened' 3 $((CAR_W - 27 * CAR_S)) $((28 * CAR_S)) > /dev/null || return 1
  wait_more 'car lists: saved places shown, 3 rows' "$before" 12 || return 1
  sleep 1
  x=$(( (FREE_LEFT + 110) * CAR_S ))
  y=$(( (75 + (row - 1) * 48) * CAR_S ))
  tap_until 'car lists: a place was chosen' 3 "$x" "$y" "$x" $((y - 9 * CAR_S)) "$x" $((y + 9 * CAR_S)) > /dev/null
}

PANEL_BOX=""

panel_button() {  # the filled button in the part of the screen the route panel took from the map: "found <x> <y> ..." or "none ..."
  xcrun simctl io "$UDID" screenshot --type=png --display=external "$OUT/.routes.png" > /dev/null 2>&1
  # shellcheck disable=SC2086
  python3 -I "$HERE/find_icon.py" button "$OUT/.routes.png" $PANEL_BOX 2>> "$LOG" | tail -n 1
}

route_pictures() {  # route_pictures <label>: the routes to a place chosen in Saved places; Back, a route that cannot be found, Start
  local label="$1" before guiding started lines at old new ot ol ob or nt nl nb nr spot sx sy y
  ROUTES=""
  ROUTES_MISSING=""
  to_browsing || { ROUTES_MISSING=" [the stand-in did not go back to its first trip]"; return 0; }
  old=$(free_area)
  read -r ot ol ob or <<< "$old"
  case "$ot$ol$ob$or" in *[!0-9]*|"") ROUTES_MISSING=" [the free area was not said in the log]"; return 0 ;; esac

  # The first saved place: its routes come up in CarPlay's own panel on the map. Then the bar's Back.
  before=$(log_count 'car routes: preview shown, 2 routes')
  if ! open_place 1; then
    shot_ext "$label-routes-no-place"
    ROUTES_MISSING=" [a row of Saved places did not answer the tap]"
    return 0
  fi
  if wait_more 'car routes: preview shown, 2 routes' "$before" 12; then
    sleep 3
    shot_ext "$label-routes"
    ROUTES="the first saved place's two routes came up in CarPlay's route panel"
  else
    shot_ext "$label-routes"
    ROUTES_MISSING="$ROUTES_MISSING [the app did not say the route panel is shown with 2 routes]"
    return 0
  fi
  before=$(log_count 'car link: trip browsing')
  if at=$(tap_until 'car routes: preview left' 3 $(( (ol + 18) * CAR_S )) $((22 * CAR_S)) $(( (ol + 32) * CAR_S )) $((22 * CAR_S)) $(( (ol + 24) * CAR_S )) $((30 * CAR_S))); then
    wait_more 'car link: trip browsing' "$before" 8 || ROUTES_MISSING="$ROUTES_MISSING [the phone was not told that the routes were left]"
    sleep 2
    shot_ext "$label-routes-left"
    ROUTES="$ROUTES; the bar's Back (tap at pixel $at) left them and the phone forgot the routes"
  else
    shot_ext "$label-routes-not-left"
    ROUTES_MISSING="$ROUTES_MISSING [the bar's Back did not answer taps at its leading end]"
    return 0
  fi

  # The third saved place stands for one no route can be found to yet: the phone's words in an alert, and its one button.
  before=$(log_count 'car routes: an alert says')
  if ! open_place 3; then
    shot_ext "$label-routes-no-third-place"
    ROUTES_MISSING="$ROUTES_MISSING [the third row of Saved places did not answer the tap]"
    return 0
  fi
  if wait_more 'car routes: an alert says' "$before" 12; then
    sleep 2
    shot_ext "$label-routes-error"
    ROUTES="$ROUTES; a route that cannot be found is said in an alert"
  else
    shot_ext "$label-routes-error"
    ROUTES_MISSING="$ROUTES_MISSING [no alert for the route that cannot be found]"
    return 0
  fi
  spot=$(( (ol * CAR_S + CAR_W - or * CAR_S) / 2 ))
  if at=$(tap_until 'car routes: preview left' 2 "$spot" $((CAR_H * 62 / 100)) "$spot" $((CAR_H * 70 / 100)) "$spot" $((CAR_H * 78 / 100)) "$spot" $((CAR_H * 54 / 100)) "$spot" $((CAR_H * 86 / 100)) $((CAR_W / 2)) $((CAR_H * 70 / 100))); then
    sleep 2
    shot_ext "$label-routes-error-left"
    ROUTES="$ROUTES; its button (tap at pixel $at) left"
  else
    shot_ext "$label-routes-error-not-left"
    ROUTES_MISSING="$ROUTES_MISSING [the alert's button did not answer taps under its words]"
    return 0
  fi

  # The first saved place again, and Start. The start button is looked for as the one filled patch of strong colour in the
  # part of the screen the panel took from the map; failing that, by taps up the middle of that part.
  to_browsing
  before=$(log_count 'car routes: preview shown, 2 routes')
  if ! open_place 1 || ! wait_more 'car routes: preview shown, 2 routes' "$before" 12; then
    shot_ext "$label-routes-no-second-preview"
    ROUTES_MISSING="$ROUTES_MISSING [the route panel did not come up the second time]"
    return 0
  fi
  sleep 3
  new=$(free_area)
  read -r nt nl nb nr <<< "$new"
  case "$nt$nl$nb$nr" in *[!0-9]*|"") nt=$ot; nl=$ol; nb=$ob; nr=$or ;; esac
  PANEL_BOX="$((ol * CAR_S)) $((ot * CAR_S)) $((CAR_W - or * CAR_S)) $((CAR_H - ob * CAR_S)) $((nl * CAR_S)) $((nt * CAR_S)) $((CAR_W - nr * CAR_S)) $((CAR_H - nb * CAR_S))"
  guiding=$(log_count 'car link: trip guiding')
  started=$(log_count 'car routes: Start pressed')
  shot_ext "$label-routes-again"
  spot=$(panel_button)
  say "  the free area before the panel: $old; with it: $new; a filled button in what it took: $spot"
  case "$spot" in
    found*) ;;
    *)
      ROUTES_MISSING="$ROUTES_MISSING [the panel's start button was not seen as a filled button]"
      return 0
      ;;
  esac
  # shellcheck disable=SC2086
  set -- $spot
  sx=${2%.*}
  sy=${3%.*}
  # More Routes, CarPlay's own button over Start: the list of the routes. Then the second route, by taps down the middle of
  # the panel until the app says it was chosen; the phone then draws that route as the chosen one.
  tap_carplay "$sx" $((sy - 41 * CAR_S))
  sleep 3
  shot_ext "$label-routes-more"
  before=$(log_count 'car routes: route 2 chosen')
  lines=$(log_count 'car link: route line')
  at=""
  y=$(( (ot + 24) * CAR_S ))
  while [ "$y" -lt $(( CAR_H - (ob + 10) * CAR_S )) ]; do
    tap_carplay "$sx" "$y"
    if wait_more 'car routes: route 2 chosen' "$before" 2; then at="$sx,$y"; break; fi
    if [ "$(log_count 'car routes: Start pressed')" -gt "$started" ]; then break; fi
    y=$((y + 16 * CAR_S))
  done
  if [ -z "$at" ]; then
    shot_ext "$label-routes-no-other-route"
    ROUTES_MISSING="$ROUTES_MISSING [the second route was not chosen by taps down the panel after More Routes]"
    return 0
  fi
  wait_more 'car link: route line' "$lines" 8 || ROUTES_MISSING="$ROUTES_MISSING [the phone did not draw the other route]"
  sleep 3
  shot_ext "$label-routes-other"
  ROUTES="$ROUTES; More Routes listed them and the second (tap at pixel $at) was chosen and drawn"

  # Start, wherever the panel has it now.
  spot=$(panel_button)
  at=""
  case "$spot" in
    found*)
      # shellcheck disable=SC2086
      set -- $spot
      tap_carplay "${2%.*}" "${3%.*}"
      wait_more 'car routes: Start pressed' "$started" 3 && at="${2%.*},${3%.*}"
      ;;
  esac
  if [ -z "$at" ]; then
    # Up the middle of what the panel took.
    y=$(( CAR_H - (ob + 14) * CAR_S ))
    while [ "$y" -gt $(( (ot + 20) * CAR_S )) ]; do
      tap_carplay "$sx" "$y"
      if wait_more 'car routes: Start pressed' "$started" 2; then at="$sx,$y"; break; fi
      y=$((y - 18 * CAR_S))
    done
  fi
  if [ -z "$at" ]; then
    shot_ext "$label-routes-no-start"
    ROUTES_MISSING="$ROUTES_MISSING [Start was not found: neither as a filled button nor by taps up the panel]"
    return 0
  fi
  wait_more 'car link: trip guiding' "$guiding" 8 || ROUTES_MISSING="$ROUTES_MISSING [guidance did not begin after Start]"
  sleep 3
  shot_ext "$label-routes-started"
  ROUTES="$ROUTES; Start (tap at pixel $at) began the phone's guidance; the free area with the panel: top $nt left $nl bottom $nb right $nr"
}

GUIDE=""
GUIDE_MISSING=""

guide_step() {  # guide_step <notification> <log text to wait for, or ""> <picture>: one step, and a picture after it
  local before=0
  [ -n "$2" ] && before=$(log_count "$2")
  notify "$1"
  if [ -n "$2" ] && ! wait_more "$2" "$before" 12; then
    GUIDE_MISSING="$GUIDE_MISSING [$1: no new line '$2']"
  fi
  sleep 3
  shot_ext "$3"
}

guide_pictures() {  # guide_pictures <label>: turn by turn after Start, along the stand-in's recorded drive, and the bar's two buttons
  local label="$1" at before
  local edge=$((CAR_W - 27 * CAR_S)) bar=$((28 * CAR_S))
  GUIDE=""
  GUIDE_MISSING=""
  # CarPlay's guidance panel: the next turn, the one after, and what is left of the trip.
  wait_log 'car guidance: turn shown, 2 maneuvers' 12 || GUIDE_MISSING=" [the app did not say the turn is shown]"
  sleep 3
  shot_ext "$label-guide"
  # A moving vehicle: five positions a second apart. The marker glides between them and the camera goes with it; a picture
  # is taken as fast as they come while it does.
  before=$(log_count 'car map: the marker glides')
  notify roll
  for at in 1 2 3 4 5; do shot_ext "$label-guide-roll-$at"; done
  sleep 2
  at=$(( $(log_count 'car map: the marker glides') - before ))
  if [ "$at" -ge 3 ]; then
    GUIDE="the marker glided between $at of five positions a second apart"
  else
    GUIDE_MISSING="$GUIDE_MISSING [the marker glided between only $at of five positions a second apart]"
  fi
  # A climb ahead: CarPlay's own alert with Android's words and the road's shape. Then, once the alert has gone, the bar's
  # Overview button: the whole route north up, with the grade marker at the steepest point; and back.
  guide_step climb 'car guidance: climb alert shown' "$label-guide-climb"
  sleep 9
  if at=$(tap_until 'car map: route overview on' 3 $(( (FREE_LEFT + 22) * CAR_S )) "$bar" $(( (FREE_LEFT + 36) * CAR_S )) "$bar" $(( (FREE_LEFT + 14) * CAR_S )) "$bar"); then
    sleep 3
    shot_ext "$label-guide-overview"
    GUIDE="$GUIDE; a climb ahead was told in CarPlay's alert; Overview (tap at pixel $at) showed the whole route with the grade marker"
    tap_until 'car map: route overview off' 3 "${at%,*}" "${at#*,}" > /dev/null || GUIDE_MISSING="$GUIDE_MISSING [Overview did not go back to the position]"
    sleep 2
  else
    shot_ext "$label-guide-no-overview"
    GUIDE_MISSING="$GUIDE_MISSING [the Overview button did not answer taps at the bar's leading end]"
  fi
  # Nearer the turn (only the distance changes), then past it (the next turn, and arriving after it).
  guide_step drive "" "$label-guide-near"
  guide_step drive 'car guidance: turn shown, 2 maneuvers' "$label-guide-next"
  # The voice switch, at the bar's trailing edge: off, and on again. The phone's trip says which way it is.
  if at=$(tap_until 'car guidance: voice asked off' 3 "$edge" "$bar" $((edge - 8 * CAR_S)) "$bar"); then
    sleep 3
    shot_ext "$label-guide-voice-off"
    GUIDE="$GUIDE; the voice switch (tap at pixel $at) asked the phone for silence and shows it"
    tap_until 'car guidance: voice asked on' 3 "${at%,*}" "${at#*,}" > /dev/null || GUIDE_MISSING="$GUIDE_MISSING [the voice switch did not turn the voice on again]"
    sleep 2
  else
    shot_ext "$label-guide-no-voice-switch"
    GUIDE_MISSING="$GUIDE_MISSING [the voice switch did not answer a tap at the bar's trailing edge]"
  fi
  # The same in the light setting (told by the harness, as for the map), and dark again.
  guide_step day 'car map: style loaded, light' "$label-guide-light-told-by-harness"
  before=$(log_count 'car map: style loaded, dark')
  notify night
  wait_more 'car map: style loaded, dark' "$before" 12 || GUIDE_MISSING="$GUIDE_MISSING [night: the dark style did not come back]"
  # Off the route (the phone looks for a new one), then arrived.
  guide_step drive 'car guidance: rerouting' "$label-guide-rerouting"
  guide_step drive 'car guidance: arrived' "$label-guide-arrived"
  # End route, the bar's text button beside the voice switch.
  before=$(log_count 'car link: trip browsing')
  if at=$(tap_until 'car guidance: End route pressed' 2 $((CAR_W - 85 * CAR_S)) "$bar" $((CAR_W - 105 * CAR_S)) "$bar" $((CAR_W - 68 * CAR_S)) "$bar" $((CAR_W - 125 * CAR_S)) "$bar" $((CAR_W - 145 * CAR_S)) "$bar"); then
    wait_more 'car link: trip browsing' "$before" 8 || GUIDE_MISSING="$GUIDE_MISSING [the phone was not asked to end its guidance]"
    sleep 3
    shot_ext "$label-guide-ended"
    GUIDE="$GUIDE; End route (tap at pixel $at) ended it on the car and on the phone"
  else
    shot_ext "$label-guide-not-ended"
    GUIDE_MISSING="$GUIDE_MISSING [End route did not answer taps in the bar]"
  fi
}

bring_up() {  # bring_up <W> <H> <S> <label>: the defaults, a boot, the Simulator app, the CarPlay window, the app installed
  local try lit=""
  CAR_W=$1
  CAR_H=$2
  CAR_S=$3
  for try in 1 2 3; do
    stop_stream
    quit_simulator
    ANCHOR=""
    write_carplay_config "$1" "$2" "$3"
    run defaults write com.apple.iphonesimulator DevicePreferences -dict "$UDID" '<dict><key>SimulatorExternalDisplay</key><integer>2714</integer></dict>'
    if ! open_carplay; then
      [ "$try" = 3 ] && return 1
      # Seen once: after a boot the Simulator had its windows, but nothing answered questions about them for minutes, and the
      # simulator itself had become slow. The simulator service is started afresh, and the size gets one more boot.
      say "the CarPlay window was not found at $1x$2 (boot $try): the simulator service is started afresh, then one more boot"
      shot_host "no-window-$4-boot$try"
      killall Simulator > /dev/null 2>&1
      xcrun simctl shutdown all > /dev/null 2>&1
      killall -9 com.apple.CoreSimulator.CoreSimulatorService > /dev/null 2>&1
      killall "System Events" > /dev/null 2>&1
      sleep 10
      continue
    fi
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
  # Seen once: a boot whose Simulator did not answer about its windows also took no click, so the app's icon on the car
  # screen was never pressed and the app never started. Such a boot is given up and the size booted again, three boots at
  # most. Not when the app itself is at fault: a scene that connected, or a crash report of the app, ends the tries.
  up=0
  launched=0
  got=""
  for boot in 1 2 3; do
    up=0
    bring_up "$W" "$H" "$S" "$label" || break
    up=1
    shot_ext "$label-home"
    got=$(pic_size "$OUT/shots/$label-home.png")
    [ "$got" = "${W}x${H}" ] || say "asked for ${W}x${H}, the CarPlay display's picture is $got"
    if car_launch "$label"; then
      launched=1
      break
    fi
    crashed=$(app_crashes | head -n 1)
    if [ -n "$crashed" ]; then
      say "the app left a crash report, $(basename "$crashed"): no other boot is tried"
      python3 -I "$HERE/crash_summary.py" "$crashed" 2>&1 | head -n 20 | sed 's/^/        /' | tee -a "$LOG"
      break
    fi
    grep -E -q 'car scene|The Flutter engine' "$STREAM" 2> /dev/null && break
    [ "$boot" = 3 ] || say "the app did not start from its icon on the car screen at $label (boot $boot), and it left no line and no crash report: the size is booted again"
  done
  if [ "$up" = 0 ]; then
    result "FAILED $label: the CarPlay display did not come up"
    shot_host "$label-no-carplay"
    continue
  fi
  if [ "$launched" = 1 ]; then
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
        if [ -n "$BUTTONS_MISSING" ]; then
          result "FAILED $label buttons:$BUTTONS_MISSING; $BUTTONS"
        else
          result "OK $label buttons: $BUTTONS; shots/$label-map-{panned,after-done,recentered,zoomed-in}.png"
          # The lists behind the two bar buttons.
          list_pictures "$label"
          if grep -q 'car scene disconnected' "$STREAM"; then
            result "FAILED $label lists: the car scene was disconnected while the lists were pictured; $LISTS"
            host_crash=1
          elif [ -n "$LISTS_MISSING" ]; then
            result "FAILED $label lists:$LISTS_MISSING; $LISTS"
          else
            result "OK $label lists: $LISTS; shots/$label-{saved,saved-none,search-empty,search-found,search-none,after-search,after-lists}.png"
            # The routes to a place chosen in a list.
            route_pictures "$label"
            if grep -q 'car scene disconnected' "$STREAM"; then
              result "FAILED $label routes: the car scene was disconnected while the routes were pictured; $ROUTES"
              host_crash=1
            elif [ -n "$ROUTES_MISSING" ]; then
              result "FAILED $label routes:$ROUTES_MISSING; $ROUTES"
            else
              result "OK $label routes: $ROUTES; shots/$label-{routes,routes-left,routes-error,routes-error-left,routes-again,routes-more,routes-other,routes-started}.png"
              # Turn by turn, from the Start just pressed.
              guide_pictures "$label"
              if grep -q 'car scene disconnected' "$STREAM"; then
                result "FAILED $label guidance: the car scene was disconnected while guidance was pictured; $GUIDE"
                host_crash=1
              elif [ -n "$GUIDE_MISSING" ]; then
                result "FAILED $label guidance:$GUIDE_MISSING; $GUIDE"
              else
                result "OK $label guidance: the next turn, nearer it, the turn after, light, looking for a new route and arrived, in CarPlay's guidance panel; $GUIDE; shots/$label-guide{,-roll-1,-climb,-overview,-near,-next,-voice-off,-light-told-by-harness,-rerouting,-arrived,-ended}.png"
              fi
            fi
          fi
        fi
      fi
    fi
  else
    # No log line is not proof of no screen: the picture decides when the icon grid is gone.
    shot_ext "$label-car"
    result "FAILED $label: no 'car scene connected' line after the clicks, in $boot boot(s); the app's crash reports: $(app_crashes | wc -l | tr -d ' '); see shots/$label-car.png"
  fi
  shot_host "$label"
  if [ "$PHONE_DONE" = 0 ]; then
    PHONE_DONE=1
    say "-- the phone's window, opened by a cachelink: link while the car scene runs"
    shot_phone "$label-phone-before"
    before=$(log_count 'harness steps: link')
    run xcrun simctl openurl "$UDID" "cachelink://harness.example/opened-while-the-car-runs"
    answer_open "$before" "$label-phone"
    sleep 5
    shot_phone "$label-phone-window"
    shot_ext "$label-car-after-phone"
    engines=$(grep -c 'The Flutter engine was started' "$STREAM")
    linked=$(grep -c 'harness steps: link opened while running' "$STREAM")
    if [ "$engines" = 1 ] && [ "$linked" -ge 1 ] && ! grep -q 'car scene disconnected' "$STREAM"; then
      result "OK phone: a cachelink: link opened the phone's window beside the car scene, on the engine the car scene had started (one engine start in all), and the link reached Dart there (shots/$label-phone-window.png)"
    else
      result "FAILED phone: engine-start lines $engines (1 expected), lines saying the link reached Dart $linked (1 expected), car scene disconnected: $(grep -c 'car scene disconnected' "$STREAM")"
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
  # Opened by a cachelink: link with nothing running: the phone scene starts the engine, and Dart takes the link when it is up.
  run xcrun simctl openurl "$UDID" "cachelink://harness.example/opened-with-nothing-running"
  answer_open 0 update-2
  sleep 6
  shot_phone update-2-after-the-update
  came=$(grep -c "came with the storyboard" "$STREAM")
  engines=$(grep -c 'The Flutter engine was started' "$STREAM")
  linked=$(grep 'harness steps: link' "$STREAM" | tail -n 1 | sed 's/.*harness steps: //')
  if [ "$engines" = 1 ] && [ -n "$linked" ]; then
    result "OK update-2: after the update a cachelink: link opened the app with nothing running; one engine, and the link reached Dart ($linked); iOS brought the old storyboard window: $([ "$came" = 0 ] && echo no || echo yes) (shots/update-2-after-the-update.png)"
  else
    result "FAILED update-2: engine-start lines $engines (1 expected) after the update; the link reached Dart: ${linked:-no}; storyboard-window lines $came"
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
rm -f "$OUT/.last" "$OUT/.anchor.png" "$OUT/.lit.png" "$OUT/.began" "$OUT/.phone.png" "$OUT/.phone-small.png"
exit 0

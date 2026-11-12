#!/bin/bash
# CarPlay spike, step 3: opens the Simulator's CarPlay display from a script, starts the scratch app from the car side only,
# and takes the pictures. Every command and what it printed goes to spike-out/steps.log; lines that start with RESULT are the
# answers. Nothing here stops at the first failure: each part reports and the next one runs.
#
# What round 1 established, and this round builds on:
#   - the Simulator keeps the CarPlay display's settings in its defaults: CarPlayConfig (width, height, scale, input kinds) and,
#     per device, SimulatorExternalDisplay = 2714 for "CarPlay". So the display is asked for by writing defaults before the
#     Simulator app starts; the menu (I/O > External Displays > CarPlay) and its "TV Out Extended Setup" window are the fallback.
#   - `xcrun simctl io <device> screenshot --display=external` photographs it.
#   - a click made with CGEvent on the Simulator's CarPlay window is a touch on the CarPlay screen.
#   - the app appears there with the CarPlay entitlement in a simulator build and no provisioning profile, not without it.
#   - the app's CarPlay scene connected and Dart ran, but the simulator's CarPlayTemplateUIHost crashed about a second later.
#
#   A  800 x 480 at 2x, asked for through defaults alone; which content of the map template the template host survives
#      (start words, see AppDelegate.swift); guidance; the phone joining the engine the car started
#   B  the other three test sizes, each from a fresh boot of the simulator
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
      if wait_log 'carplay didConnect' 20; then
        say "the app's CarPlay scene connected ($label, click way $way)"
        WAYS="$way 1 2 3"
        return 0
      fi
      say "no CarPlay scene 20 s after the click ($label, way $way)"
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

host_crash_reports() {  # what the Mac recorded about crashed simulator processes (the template host, the app)
  local dir="$HOME/Library/Logs/DiagnosticReports" f
  sleep 6
  say "crash reports on the Mac ($dir):"
  ls -lt "$dir" 2> /dev/null | head -n 20 | sed 's/^/        /' | tee -a "$LOG"
  mkdir -p "$OUT/crashes"
  for f in "$dir"/CarPlayTemplateUIHost*.ips "$dir"/Runner*.ips "$dir"/CarPlay-*.ips; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/crashes/" 2> /dev/null
  done
  f=$(ls -t "$dir"/CarPlayTemplateUIHost*.ips 2> /dev/null | head -n 1)
  if [ -n "$f" ]; then
    say "the newest CarPlayTemplateUIHost report, $f:"
    python3 -I "$HERE/crash_summary.py" "$f" 2>&1 | sed 's/^/        /' | tee -a "$LOG"
  else
    say "no CarPlayTemplateUIHost crash report"
  fi
  say "the template host's own last log lines:"
  xcrun simctl spawn "$UDID" log show --last 4m --style compact --predicate 'process == "CarPlayTemplateUIHost" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] "exception" OR eventMessage CONTAINS[c] "terminating")' 2> /dev/null | tail -n 40 | cut -c1-600 | sed 's/^/        /' | tee -a "$LOG"
}

try_variant() {  # try_variant <name> <start words>: 0 when the CarPlay scene was still connected 10 s after it connected
  local name="$1" words="$2"
  say "-- variant $name: start words '$words'"
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  sleep 1
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
  keep_applog "V-$name"
  return 0
}

start_best() {  # a cold start from the car side with the content that survives
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  sleep 1
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

# ---------------------------------------------------------------------------------------------------------------------------
say "== facts"
BID=""
if [ -d "$APPS/ent/Runner.app" ]; then
  BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/ent/Runner.app/Info.plist")
fi
say "built app: ${BID:-none}"
SCREEN_W=""
[ -x "$TOOL" ] && SCREEN_W=$("$TOOL" screen 2> /dev/null | awk '{print $3}')
[ -n "$SCREEN_W" ] || SCREEN_W=$(system_profiler SPDisplaysDataType 2> /dev/null | awk '/UI Looks like/{print $4; f=1; exit} /Resolution/{r=$2} END{if(!f) print r}')
[ -n "$SCREEN_W" ] || SCREEN_W=1024
say "Mac screen width in points: $SCREEN_W"
BEST=""
GUIDE=""
A_OK=0

# ---------------------------------------------------------------------------------------------------------------------------
say "== A. 800 x 480 at 2x, asked for by writing the Simulator's defaults before it starts (no menu, no window)"
write_carplay_config 800 480 2
run defaults write com.apple.iphonesimulator DevicePreferences -dict "$UDID" '<dict><key>SimulatorExternalDisplay</key><integer>2714</integer></dict>'
RUN_LINES=30 run defaults read com.apple.iphonesimulator
if open_carplay; then
  say "RESULT open: the CarPlay display came up $OPENED_HOW"
else
  say "RESULT open: the CarPlay display did not come up"
fi
shot_host A1-carplay-open
size_check 800x480-2x 800 480

if [ -n "$BID" ]; then
  run xcrun simctl install "$UDID" "$APPS/ent/Runner.app"
  sleep 8
  if icon_in_carplay A-home-with-app; then
    say "RESULT entitlement: with the CarPlay entitlement and no provisioning profile the app's icon is on the CarPlay screen"
  fi
  # Which content does the simulator's template host survive? The richest first; when it stays, only the round-1 order is
  # tried as well, otherwise every poorer variant.
  if try_variant full ""; then
    BEST=""
    A_OK=1
    try_variant late "late" || true
  else
    try_variant late "late" && { BEST="late"; A_OK=1; }
    if [ "$A_OK" = 0 ]; then
      for spec in "drawn:drawn" "no-map-buttons:nomapbuttons" "map-only:nobar nomapbuttons" "bare:nobar nomapbuttons nomaplibre"; do
        if try_variant "${spec%%:*}" "${spec#*:}"; then
          BEST="${spec#*:}"
          A_OK=1
          break
        fi
      done
    fi
    try_variant list "list nomaplibre" || true
  fi
  host_crash_reports
  if [ "$A_OK" = 1 ]; then
    say "RESULT content: the template host survives the start words '$BEST'"
  else
    say "RESULT content: the template host survived none of the map-template variants"
  fi
fi

if [ "$A_OK" = 1 ]; then
  say "-- cold start from the car side with '$BEST', and the pictures"
  if start_best A-800x480; then
    shot_ext 800x480-2x-map
    shot_phone 800x480-2x-phone-while-only-the-car-scene-runs
    shot_host A2-app-on-carplay
    say "RESULT car-first: scenes when Dart said hello: $(grep 'dart hello' "$(applog)" 2> /dev/null | head -n 1 | sed 's/.*scenes=//'); phone-scene lines in the log: $(grep -c 'phone scene' "$(applog)" 2> /dev/null)"
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
    say "-- the phone window joins the engine the car started"
    run xcrun simctl launch "$UDID" "$BID"
    sleep 10
    shot_phone 800x480-2x-phone-joined-the-engine
    shot_ext 800x480-2x-map-after-phone-joined
    if grep -q 'engine joined by phone' "$(applog)" 2> /dev/null; then
      say "RESULT phone-joins: the phone window attached to the engine the car side had started (same process)"
    else
      say "RESULT phone-joins: no 'engine joined by phone' line"
    fi
  fi
  keep_applog A-800x480
fi

# ---------------------------------------------------------------------------------------------------------------------------
say "== B. the other test sizes, each from a fresh boot with the size already in the defaults"
for spec in "748 456 2" "1920 720 3" "900 1200 3"; do
  # shellcheck disable=SC2086
  set -- $spec
  W=$1
  H=$2
  S=$3
  label="${W}x${H}-${S}x"
  say "-- size $W x $H pixels at ${S}x"
  quit_simulator
  write_carplay_config "$W" "$H" "$S"
  if ! open_carplay; then
    say "RESULT size $label: the CarPlay display did not come up"
    shot_host "B-$label-no-carplay"
    continue
  fi
  if ! size_check "$label" "$W" "$H"; then
    say "  the defaults did not give the size: the options window instead"
    front
    say "  closing: $(osa sim_external Disabled)"
    sleep 4
    say "  asking: $(osa sim_external CarPlay)"
    sleep 4
    fill_options_window "$W" "$H" "$S"
    sleep 10
    OPENED_HOW="through the options window"
    size_check "$label" "$W" "$H"
    run defaults export com.apple.iphonesimulator -
  fi
  shot_host "B-$label"
  if [ "$A_OK" = 1 ]; then
    if start_best "B-$label"; then
      shot_ext "$label-map"
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
      say "RESULT start $label: cold start from the car side, $(disconnects) disconnects"
    else
      say "RESULT start $label: the app's CarPlay scene did not connect"
    fi
    keep_applog "B-$label"
  fi
done

# ---------------------------------------------------------------------------------------------------------------------------
say "== end"
defaults read com.apple.iphonesimulator > "$OUT/ui/defaults-3-end.txt" 2>&1
shot_host Z-end
xcrun simctl spawn "$UDID" log show --last 12m --style compact --predicate 'processImagePath ENDSWITH "Runner" AND (messageType == error OR messageType == fault)' 2> /dev/null | tail -n 200 > "$OUT/applog/unified-log-errors.txt"
say "pictures:"
ls -l "$OUT/shots" | sed 's/^/        /' | tee -a "$LOG"
grep 'RESULT' "$LOG" | sed 's/^\[[ 0-9]*s\] //' > "$OUT/results.txt"
say "capture took $((SECONDS - T0)) s"
rm -f "$OUT/.last"
exit 0

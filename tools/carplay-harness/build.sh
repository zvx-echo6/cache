#!/bin/bash
# CarPlay harness, step 2: the harness app. A scratch Flutter project is made here (the product itself cannot run in the
# Simulator: its native cores are built for the device only) and given the PRODUCT'S OWN iOS sources, unchanged:
#
#   app/ios/Runner/AppDelegate.swift       the app delegate: the engine, the plugins, the channels, the scene configuration
#   app/ios/Runner/SceneDelegate.swift     the phone's window
#   app/ios/Runner/CarPlay/*.swift         every car file
#   app/ios/Runner/Info.plist              (its CacheCarPlay key filled by CACHE_CARPLAY=YES, as a car build's)
#   app/ios/Runner/RunnerCarPlay.entitlements
#
# with the three plugins the app delegate imports, at the product's versions, and a stand-in Dart side
# (tools/carplay-harness/app) that speaks the car channel with recorded messages (tools/carplay-harness/recorded). So a Swift
# mistake in any of those files fails here in minutes, and what the pictures show is what the product's car code draws.
# First of all it runs the car link's tests (tools/carplay-harness/tests) on those recorded messages, on the Mac.
# No signing identity, no provisioning profile, no secret.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$GITHUB_WORKSPACE"
OUT="$RUNNER_TEMP/harness-out"
APPS="$RUNNER_TEMP/harness-apps"
B="$RUNNER_TEMP/carharness"
mkdir -p "$OUT" "$APPS"
began=$SECONDS
version() { awk -v p="  $1:" '$0==p{f=1;next} f&&/version:/{gsub(/"/,"",$2);print $2;exit}' "$ROOT/app/pubspec.lock"; }
{
  # The car link's rules on recorded messages, on the Mac: the product's CarTrip.swift and CarLink.swift need no Flutter.
  echo "--- car link tests on the recorded messages"
  xcrun --sdk macosx swiftc "$ROOT/app/ios/Runner/CarPlay/CarTrip.swift" "$ROOT/app/ios/Runner/CarPlay/CarLink.swift" \
    "$ROOT/app/ios/Runner/CarPlay/CarMarkerMotion.swift" "$HERE/tests/main.swift" -o "$RUNNER_TEMP/car-link-tests"
  "$RUNNER_TEMP/car-link-tests" "$HERE/recorded"
  # CocoaPods for the scratch project, as the repository's other scratch iOS build (map-bench.yml).
  flutter config --no-enable-swift-package-manager
  flutter create --org org.example --project-name carharness --platforms ios "$B" > /dev/null
  cd "$B"
  flutter pub add "maplibre_gl:$(version maplibre_gl)" "workmanager:$(version workmanager)" "flutter_local_notifications:$(version flutter_local_notifications)"
  # The harness's own plugin, never a part of the app: the job steers the stand-in Dart side and the car's day and night
  # through it (steps_plugin/ios/Classes/HarnessStepsPlugin.swift).
  flutter pub add "harness_steps:{\"path\":\"$HERE/steps_plugin\"}"
  rm -rf test
  cp "$HERE/app/lib/main.dart" lib/main.dart
  # The stand-in Dart side pushes the same recorded messages the tests read, and answers the car's style call with the
  # stand-in styles made here.
  rm -rf "$RUNNER_TEMP/harness-recorded"
  mkdir -p "$RUNNER_TEMP/harness-recorded"
  cp "$HERE"/recorded/*.json "$RUNNER_TEMP/harness-recorded/"
  python3 -I "$HERE/stand_in_style.py" "$RUNNER_TEMP/harness-recorded"
  python3 -I "$HERE/recorded_dart.py" "$RUNNER_TEMP/harness-recorded" lib/recorded.dart
  cp "$ROOT/app/ios/Runner/AppDelegate.swift" ios/Runner/AppDelegate.swift
  python3 -I "$HERE/join_swift.py" ios/Runner/SceneDelegate.swift "$ROOT/app/ios/Runner/SceneDelegate.swift" "$ROOT"/app/ios/Runner/CarPlay/*.swift
  cp "$ROOT/app/ios/Runner/Info.plist" ios/Runner/Info.plist
  cp "$ROOT/app/ios/Runner/RunnerCarPlay.entitlements" ios/Runner/RunnerCarPlay.entitlements
  python3 -I "$HERE/prepare_project.py" ios
  flutter build ios --config-only --simulator --debug
  # iOS 16.3, static frameworks and the MapLibre pod at the version the product's map plugin uses (as map-bench.yml).
  POD="pod 'MapLibre', '6.28.0'"
  sed -i '' "s/^# platform :ios.*/platform :ios, '16.3'/" ios/Podfile
  sed -i '' "s/^  use_frameworks!$/  use_frameworks! :linkage => :static/" ios/Podfile
  awk -v pod="$POD" '{print} /flutter_install_all_ios_pods/{print pod}' ios/Podfile > "$RUNNER_TEMP/Podfile" && cp "$RUNNER_TEMP/Podfile" ios/Podfile
  # The car screen on, the way a car build of the product has it: the build setting and the entitlements file.
  printf '\nCACHE_CARPLAY = YES\nCODE_SIGN_ENTITLEMENTS = Runner/RunnerCarPlay.entitlements\n' >> ios/Flutter/Debug.xcconfig
  echo "--- build ($((SECONDS - began)) s so far)"
  flutter build ios --simulator --debug
  rm -rf "$APPS/car"
  mkdir -p "$APPS/car"
  cp -R build/ios/iphonesimulator/Runner.app "$APPS/car/"
  echo "--- build done after $((SECONDS - began)) s"
} 2>&1 | tee "$OUT/build.log"

set +e
{
  app="$APPS/car/Runner.app"
  echo "--- what the built app carries"
  echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  echo "CacheCarPlay: $(/usr/libexec/PlistBuddy -c 'Print :CacheCarPlay' "$app/Info.plist")"
  echo "provisioning profile in the app: $(ls "$app/embedded.mobileprovision" 2>/dev/null || echo none)"
  echo "mentions of the CarPlay entitlement in the executable: $(strings -a "$app/Runner" | grep -c 'carplay-maps')"
  echo "scene manifest:"
  /usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest' "$app/Info.plist" | sed 's/^/    /'
} 2>&1 | tee -a "$OUT/build.log"
exit 0

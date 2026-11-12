#!/bin/bash
# CarPlay spike, step 2: makes the scratch Flutter app and builds it for the simulator with the CarPlay navigation entitlement.
# No signing identity, no provisioning profile, no secret.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$RUNNER_TEMP/spike-out"
APPS="$RUNNER_TEMP/spike-apps"
B="$RUNNER_TEMP/carspike"
mkdir -p "$OUT" "$APPS/ent"
began=$SECONDS
{
  # CocoaPods for the scratch project, as the repository's other scratch iOS build (map-bench.yml).
  flutter config --no-enable-swift-package-manager
  flutter create --org org.example --project-name carspike --platforms ios "$B" > /dev/null
  cd "$B"
  V=$(awk '/^  maplibre_gl:/{f=1;next} f&&/version:/{gsub(/"/,"",$2);print $2;exit}' "$GITHUB_WORKSPACE/app/pubspec.lock")
  flutter pub add "maplibre_gl:$V"
  rm -rf test
  echo "--- what flutter create made in ios/Runner"
  ls ios/Runner
  cat ios/Runner/AppDelegate.swift
  ls ios/Runner/*.swift ios/Runner/*.h || true
  /usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest' ios/Runner/Info.plist || true
  { grep -n 'IPHONEOS_DEPLOYMENT_TARGET\|SWIFT_VERSION' ios/Runner.xcodeproj/project.pbxproj | sort -u -k2 | head -n 12; } || true
  echo "--- the spike's files go in"
  cp "$HERE/app/lib/main.dart" lib/main.dart
  cp "$HERE/app/ios/AppDelegate.swift" ios/Runner/AppDelegate.swift
  cp "$HERE/app/ios/CarSpike.entitlements" ios/Runner/CarSpike.entitlements
  python3 -I "$HERE/app/ios/prepare_project.py" ios
  flutter build ios --config-only --simulator --debug
  # iOS 16.3, static frameworks and the MapLibre pod at the version the product's map plugin uses.
  POD="pod 'MapLibre', '6.28.0'"
  sed -i '' "s/^# platform :ios.*/platform :ios, '16.3'/" ios/Podfile
  sed -i '' "s/^  use_frameworks!$/  use_frameworks! :linkage => :static/" ios/Podfile
  awk -v pod="$POD" '{print} /flutter_install_all_ios_pods/{print pod}' ios/Podfile > "$RUNNER_TEMP/Podfile" && cp "$RUNNER_TEMP/Podfile" ios/Podfile
  cat ios/Podfile

  # Round 1 built it without the entitlement too (the app then does not appear in CarPlay); from round 2 on only the entitled app.
  echo "--- build: the CarPlay navigation entitlement, through the Runner target's Debug.xcconfig ($((SECONDS - began)) s so far)"
  printf '\nCODE_SIGN_ENTITLEMENTS = Runner/CarSpike.entitlements\n' >> ios/Flutter/Debug.xcconfig
  cat ios/Flutter/Debug.xcconfig
  flutter build ios --simulator --debug
  cp -R build/ios/iphonesimulator/Runner.app "$APPS/ent/"
  echo "--- build done after $((SECONDS - began)) s"
} 2>&1 | tee "$OUT/build.log"

set +e
{
  echo "--- what each built app carries"
  for v in ent; do
    app="$APPS/$v/Runner.app"
    echo "== $v"
    echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    echo "provisioning profile in the app: $(ls "$app/embedded.mobileprovision" 2>/dev/null || echo none)"
    echo "\$ codesign -dv"
    codesign -dv "$app" 2>&1 | grep -E 'Identifier|Signature|TeamIdentifier|Authority|flags' | sed 's/^/    /'
    echo "\$ codesign -d --entitlements - (what the signature holds)"
    codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - 2>/dev/null | sed 's/^/    /'
    for bin in Runner Runner.debug.dylib; do
      [ -f "$app/$bin" ] || continue
      echo "$bin: sections named like entitlements: $(otool -l "$app/$bin" | grep -c -E 'sectname __ent')"
      echo "$bin: mentions of carplay-maps in the file: $(strings -a "$app/$bin" | grep -c 'carplay-maps')"
    done
    echo "scene manifest:"
    /usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest' "$app/Info.plist" | sed 's/^/    /'
  done
} 2>&1 | tee -a "$OUT/build.log"

# If Flutter's simulator build left the entitlement out, build once more with xcodebuild itself, signing to run locally.
# (grep -c reads to the end: with pipefail, grep -q would end early and make the pipeline look failed.)
mentions=$(cat "$APPS/ent/Runner.app/Runner" "$APPS/ent/Runner.app/Runner.debug.dylib" 2>/dev/null | strings -a | grep -c 'carplay-maps')
if [ "${mentions:-0}" = "0" ]; then
  {
    echo "--- the entitlement is not in the app Flutter built; building with xcodebuild"
    cd "$B/ios"
    xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$RUNNER_TEMP/spike-dd" \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build 2>&1 | tail -n 40
    built="$RUNNER_TEMP/spike-dd/Build/Products/Debug-iphonesimulator/Runner.app"
    if [ -d "$built" ]; then
      rm -rf "$APPS/ent/Runner.app"
      cp -R "$built" "$APPS/ent/"
      echo "xcodebuild's app: mentions of carplay-maps: $(strings -a "$APPS/ent/Runner.app/Runner" | grep -c 'carplay-maps')"
    fi
  } 2>&1 | tee -a "$OUT/build.log"
fi
exit 0

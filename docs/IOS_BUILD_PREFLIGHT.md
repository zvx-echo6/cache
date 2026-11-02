# iOS build preflight and release checklist

Run these gates in order on the **same full source commit**. Stop at a failed prerequisite and report its command, error and blocked next step. The workflow runs cheap source/secret checks in its plan, then the native gate and existing disk/WebKit fixtures before dependency compilation. Signing and real-device validation remain distinct gates.

## Evidence status

- Baseline commit `f49162e2eae82c0b5888b76349b016210bebb7fe`: CI run `40447614611` passed all automated preflight, native compile/link, archive, exported-IPA and guarded upload gates. The lead verified App Store Connect build **11** is **VALID**. Subsequent source changes still need their own release validation; this evidence does not establish real-device behavior.
- Mac disk-helper and exact WebKit rule fixtures also passed in run `40447614611`. Re-run them on each release SHA; earlier results are baseline evidence only.
- A successful preflight proves only source configuration and small host/device compiler-linker probes. It does not build Valhalla, check its merged archive, prove static FFI retention, sign an app or demonstrate device parity.
- Streaming was owner-confirmed on an earlier iPhone build. Reconfirm against the candidate; other device behaviors below remain unverified until recorded.

## Before expensive native builds

- [ ] Resolve the intended branch to a full 40-character SHA before dispatch. A short hex SHA can be interpreted by actions/checkout as a branch/tag and fail before compilation. Automated workflow plan gate (verified for the baseline in run `40447614611`; recheck each candidate): reject 7-39-character all-hex input refs before Mac jobs. Workflow branch-ref handling remains with the workflow owner; the script's optional argument accepts only a full SHA.

  ```bash
  git fetch origin ios-routing
  SOURCE_SHA=$(git rev-parse --verify 'origin/ios-routing^{commit}')
  git checkout --detach "$SOURCE_SHA"
  bash packages/valhalla/scripts/preflight-ios.sh "$SOURCE_SHA"
  ```

  Without a separately supplied expected SHA:

  ```bash
  bash packages/valhalla/scripts/preflight-ios.sh
  ```

- [ ] Record `git rev-parse HEAD`, `git status --short`, `xcodebuild -version`, `xcrun --sdk iphoneos --show-sdk-version`, Rust/Flutter versions and cache provenance. Require a clean candidate checkout; do not combine caches/artifacts from unverified sources. The native gate checks native tools only; Flutter and CocoaPods are prepared and checked in the app job. Preflight checks that required commands already exist; it installs/downloads nothing and does not warm caches or build dependencies.
- [ ] Require preflight success: Valhalla 3.7.0 source `72f459fc5661fb906ad424be5378c4e32d9a5b3b`; vcpkg revision and manifest baseline `0e39c10736341cc8135b560438229bbda3d3219a`; iOS **16.3** everywhere checked: app Podfile and its post-install override, Runner project, both native podspecs, llama/search/Valhalla build scripts and routing triplet. The gate also requires CoreFoundation in the search podspec and standalone merged-archive link command. Intentional pin/minimum changes must update this gate in review.
- [ ] Confirm host/target separation. Ambient `IPHONEOS_DEPLOYMENT_TARGET` previously made the Mac pkgconf sanity program target iPhone and fail execution. Preflight compiles and runs a Mac probe with that variable and inherited SDK/compiler flags unset, requiring `TARGET_OS_IPHONE == 0`. The actual native recipe must also sanitize its host-tool environment. The independent device probe links std::format, chrono formatting and CoreFoundation at 16.3 and verifies arm64; it is **never executed** on the runner.
- [ ] Run the existing statvfs helper fixture early, before dependency compilation. This tests actual SDK struct layout and valid/null/empty/missing paths; do not substitute a hand-declared Dart struct. Keep zero available bytes distinct from unavailable (`-1`).

  ```bash
  CHECK_DIR=$(mktemp -d /private/tmp/cache-ios-checks.XXXXXX)
  trap 'rm -rf -- "$CHECK_DIR"' EXIT
  env -u IPHONEOS_DEPLOYMENT_TARGET clang -Wall -Wextra -Werror \
    packages/cache_search/ios/Classes/cache_search.c \
    packages/cache_search/ios/tests/free_space_test.c -o "$CHECK_DIR/free-space-test"
  "$CHECK_DIR/free-space-test" "$CHECK_DIR" "$CHECK_DIR/missing"
  ```

- [ ] Compile the existing exact reader-rule fixture with native WebKit early. Dart regex acceptance does not prove WKContentRuleList acceptance: its supported regex subset excludes patterns such as the earlier scheme alternation. Swift's optional `WKContentRuleListStore(url:)` must be unwrapped. These existing tests remain separate from the new preflight.

  ```bash
  env -u IPHONEOS_DEPLOYMENT_TARGET swift \
    packages/cache_search/ios/tests/reader_rules_test.swift \
    packages/cache_search/ios/tests/offline-reader-rules.json
  ```

- [ ] Export the actual app rule JSON, compare it byte-for-byte to the native fixture, and run targeted app tests. Use normalized file URIs for Windows path comparisons; raw separator comparisons previously caused a false failure. Run Flutter tests on desktop or Mac CI, never cortex.

  ```bash
  # In the same shell as CHECK_DIR above, from the repo root:
  export CACHE_READER_RULES_FILE="$CHECK_DIR/reader-rules.json"
  (cd app && flutter test --no-pub test/core_config_test.dart \
    test/nav_speaker_test.dart test/browse/zim_download_test.dart \
    test/browse/storage_test.dart test/browse/reader_resources_test.dart \
    test/video_player_screen_test.dart)
  cmp packages/cache_search/ios/tests/offline-reader-rules.json "$CACHE_READER_RULES_FILE"
  env -u IPHONEOS_DEPLOYMENT_TARGET swift \
    packages/cache_search/ios/tests/reader_rules_test.swift "$CACHE_READER_RULES_FILE"
  ```

  These commands assume existing Flutter packages/toolchains are prepared by the build owner. Preflight does not fetch them.

- [ ] Run plugin tests from `packages/cache_search`, with that package's own `.dart_tool/package_config.json` prepared. Running its tests from `app` breaks relative fixture paths; supplying the app's package config alone does not satisfy Flutter's plugin discovery. With dependencies already cached, use `(cd packages/cache_search && flutter pub get --offline && flutter test --no-pub)`. A setup failure blocks release until corrected; do not weaken assertions or skip fixture tests. Keep generated build outputs on the approved build drive.

## Signing readiness (separate gate; no secrets needed by preflight)

- [ ] Automated workflow plan gate (verified for the baseline in run `40447614611`; recheck each candidate): for `stage=all`, require nonempty `IOS_DIST_P12_B64`, `IOS_DIST_P12_PASSWORD` and `IOS_PROFILE_B64`; for `upload=true`, require nonempty `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8_B64`. Report missing names only, never values, before Mac jobs. These workflow gates are separate from the compiler preflight, which requires no signing secrets. Secret presence does not establish validity, expiry or authorization.
- [ ] Confirm certificate and provisioning profile validity/expiry through the intended release window, distribution type, matching team and bundle identifier, and required entitlements. Verify the **actual installed signing identity name** matches the archive/export configuration rather than assuming a certificate display name. Inspect privately; do not publish certificate/profile contents.

  ```bash
  # Existing prepared signing keychain, on Mac CI only; inspect output privately.
  security find-identity -v -p codesigning
  # With PROFILE pointing to the existing candidate provisioning profile:
  security cms -D -i "$PROFILE" > "$CHECK_DIR/profile.plist"
  /usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$CHECK_DIR/profile.plist"
  /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' "$CHECK_DIR/profile.plist"
  /usr/libexec/PlistBuddy -c 'Print :Entitlements' "$CHECK_DIR/profile.plist"
  # With CERTIFICATE_PEM pointing to the existing public signing certificate:
  openssl x509 -in "$CERTIFICATE_PEM" -noout -dates
  ```

  Confirm certificate/profile pairing and entitlement compatibility as well as expiry; a listed identity alone is insufficient. Never echo passwords, private keys or upload tokens. Remove temporary decoded profile metadata after this private check.
- [ ] Confirm upload authentication is present/valid and the candidate build number is unique for the app version in App Store Connect before spending a full build. Record the chosen version/build without personal identifiers.

## Native link, resources, archive and signing

- [ ] Build using the approved recipe on the pinned source. Verify each device archive contains arm64 device code, not a simulator slice, and retain its build provenance and SHA256. A tiny successful probe does not prove dependency compilation.
- [ ] Link the C harness against both the native dependency closure and the **actual merged routing archive**, explicitly linking `-lc++ -lz -framework CoreFoundation` at iOS 16.3. Commit `12e65b9` supplies the merged-archive CoreFoundation repair. Do not count a CMake-only harness link as validation of the merged archive.
- [ ] Inventory app resources explicitly: Metal resources required by the native LLM recipe, embedded timezone configuration, any genuinely required bundle files, and separately installed routing packs. Verify shipped paths/case and data versions against the build recipe; do not include external timezone archives by assumption.
- [ ] **Native recipe fix `f072caf`; Mac compile/flag/link gates passed in run `40447614611`, device runtime remains unverified:** Valhalla embeds timezone strings, but `date::init_tzdb_strings` still reaches unused `get_install`, whose iOS path scans the app bundle for `.tar.gz`. The native worker added an iOS-only `INSTALL=.` compile definition scoped to `tz_alt.cpp`, using CMake source properties with `TARGET_DIRECTORY valhalla-baldr`. Coordinate exact definition/source/property strings with the native/workflow owner before making them a static preflight requirement. The integrated gate checks the wrapper configuration; the recipe verifies actual compile-command definitions after CMake configuration. Verify the final compile command scopes the definition only as intended, embedded timezone strings remain enabled, and no external timezone bundle is required by that configuration. **Static configuration is not runtime proof**: confirm device initialization and routing across timezone/date boundaries before checking those behaviors off.
- [ ] Check static FFI retention in the archived **app executable**, after linking/stripping. Libraries can define symbols which the final app silently discards. Verify force-load/linker roots and at least the existing required exports below. Include all additional Dart-looked-up exports required by the candidate ABI.

  ```bash
  # Point at the actual archive produced by this candidate build.
  ARCHIVE="$RUNNER_TEMP/Runner.xcarchive"
  APP="$ARCHIVE/Products/Applications/Runner.app"
  BIN="$APP/Runner"
  xcrun lipo -archs "$BIN"   # Require arm64 device architecture.
  xcrun nm -gU "$BIN" > "$CHECK_DIR/app-symbols.txt"
  for symbol in _cs_open _cs_version _cs_tool _cs_map_route _cs_map_progress \
    _cs_conversation_export _cs_conversation_import _cl_load _cl_next \
    _valhalla_shim_init _valhalla_shim_route _cache_free_bytes_on_disk; do
    grep -Eq " ${symbol}$" "$CHECK_DIR/app-symbols.txt" || exit 1
  done
  codesign --verify --deep --strict "$APP"
  codesign -d --entitlements :- "$APP"
  /usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist"
  ```

- [ ] Automated signed-archive gate (verified for the baseline in run `40447614611`; recheck each candidate): require arm64, `MinimumOSVersion` exactly `16.3`, the expected `application-identifier` (team plus bundle), and successful `codesign --verify`. Require **all three** entitlement values to be true: `com.apple.developer.kernel.increased-memory-limit`, `com.apple.developer.kernel.extended-virtual-addressing`, and `com.apple.developer.usernotifications.time-sensitive`. The earlier alternation grep only proved that any one name appeared and is insufficient. Verify expected bundle/version/build identity and distribution profile as well. The workflow now runs `packages/cache_search/ios/check-app.sh` on both the archive and exported IPA: arm64, minimum16.3, bundle/version/build, FFI symbols, signature, signed application identity and ALL three required entitlements. Check usage descriptions, document sharing, background audio and notification configuration. Keep signing material/private identifiers out of public logs/docs. After IPA export, repeat architecture, export-symbol and signature checks on the exported payload; successful archive signing alone does not validate the final exported artifact.

## TestFlight processing

- [ ] Record final IPA byte size and SHA256, compare size with expected contents/previous candidate, and investigate unexpected growth or truncation. Require final payload architecture and symbols as above.

  ```bash
  # IPA is the actual export path from the approved workflow.
  stat -f %z "$IPA"
  shasum -a 256 "$IPA"
  ```

- [ ] Upload only the verified candidate under the existing release authorization. Record full SHA, artifact hash, CI run, app version/build and upload result without secrets or personal information.
- [ ] Wait for App Store Connect processing, inspect processing errors/compliance status, and confirm the exact build is assigned to the intended internal/external test groups and appears for their testers. Upload success, processing completion, external review approval and installation are distinct states.
- [ ] Install that exact build on a real iPhone and record OS/device class and build identity without personal identifiers. Preserve app data. A simulator or Windows test pass does not establish iPhone parity.

## Real-device parity (record pass/fail/unverified separately)

- [ ] First launch, model load/Metal/memory behavior, chat persistence and reopening saved chats.
- [ ] Library download/resume/low-storage reporting and search; offline ZIM reader text, images/CSS, history, find, citations and network isolation.
- [ ] Offline maps/layers in airplane mode, place search, route preview and guidance with the installed routing extract. Confirm embedded timezone initialization and date/time-sensitive routes without a supplied timezone archive.
- [ ] Notification permission, screen-locked navigation/TTS, ducking and recovery after backgrounding.
- [ ] In iOS Settings grant and revoke location permission, and turn the system location switch off/on; return to Cache each time. Confirm fresh fixes recover without another prompt, revoked/unavailable location clears the map/core position, and the app's location-off setting stays off. Repeat during active guidance: resume must not acquire a competing stream or steal guidance ownership. These device checks remain **unverified**; desktop fake-source tests cover logic only.
- [ ] Streaming, downloaded video, local captions and citation timestamp jumps; safe disposal while initialization is pending.
- [ ] Settings and key persistence, storage reporting including unavailable/zero-space behavior, and Files-based pack placement. Never uninstall or clear app data as a shortcut.
- [ ] Record remaining failures as failures, and untested items as unverified. Desktop logic tests do not prove desktop UI parity either. No new features are implied by this checklist.

Preflight scratch files are removed by its exit trap outside the checkout. Remove checklist scratch files when finished; preserve only candidate artifacts and evidence still needed for review. Do not create backups or install tools as part of this gate.

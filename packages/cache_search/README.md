# cache_search

Cache's search core (Rust, `native/`) as a Flutter FFI plugin, plus the Dart API the app uses. The C ABI is
`native/include/cache_search.h`; the design is in `DESIGN.md`.

## Layout

* `native/` - the Rust workspace (crate `cache_search`, a `cdylib`).
* `lib/src/native.dart` - hand-written `dart:ffi` binding of every `cs_*` function (`CsNative`, `FfiCsNative`).
  Returned strings are copied and freed with `cs_free_string`; byte buffers with `cs_free_bytes`.
* `lib/src/engine.dart` - JSON in and out, typed results, errors raised from `cs_last_error`
  (`SearchEngine`, `ConversationNumbers`, `CoreJob`). Synchronous.
* `lib/src/search_core.dart` - `SearchCore`, the same calls from the UI: one background isolate owns the handle,
  so `cs_open`, search, read and the job calls never run on the UI isolate.
* `android/` - Gradle builds the core with `cargo ndk` before the app's native libraries are merged.

## Android build

`flutter build apk --release` runs `cargo ndk` (task `cargoNdkBuild` in `android/build.gradle`) and packages
`libcache_search.so`. Needs the Rust toolchain with the Android targets, `cargo-ndk` and the Android NDK on the
build machine (cargo is found in `$CARGO_HOME/bin` or `~/.cargo/bin`). Only arm64-v8a is built by default
(every phone); for the emulator add `-PcacheSearchAbis=arm64-v8a,x86_64` to the Gradle command line. An ABI
without the core still runs; Search then says it is not available. The Rust release profile is always used.

## iOS build

iPhone only (device, `aarch64-apple-ios`; no simulator slice). `ios/build-core.sh <libzim-build-dir>` builds the Rust
core as a static library (`ios/native/libcache_search.a`), unpacks Kiwix's CoreKiwix.xcframework as
`ios/native/libCoreKiwix.a` and builds Valhalla (`libcache_valhalla.a`); run it on a Mac with Xcode and the
`aarch64-apple-ios` Rust target before `pod install`. `ios/cache_search.podspec` links the three libraries into the app
(`ios: ffiPlugin: true` in `pubspec.yaml`), and `FfiCsNative.open` finds the C ABI with `DynamicLibrary.process()`.
The TestFlight workflow (`.github/workflows/ios-testflight.yml`) runs the same steps.

## Other platforms (TODO)

* Windows: build `cache_search.dll` (the Qdrant Edge dependency has to be checked there) and add
  `windows: ffiPlugin: true`.

Until then the app builds there without the core and `SearchCore.open` throws a `CacheSearchException`/error that
the app shows as "Search is not available".

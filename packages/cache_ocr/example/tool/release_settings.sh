#!/usr/bin/env bash
# Makes the example's generated Android release build match the app's (app/android/app/build.gradle.kts): the app's own
# proguard-rules.pro (copied, so the real rules are tested) and legacy JNI packaging. The x86_64 libraries are kept so the emulator can
# run it (the app ships arm64 only). Run in packages/cache_ocr/example after `flutter create`.
set -euo pipefail
f=android/app/build.gradle.kts
[ -f "$f" ] || { echo "no $f"; ls android/app; exit 1; }
cp ../../../app/android/app/proguard-rules.pro android/app/proguard-rules.pro
cat >> "$f" <<'KTS'

// --- mirrored from app/android/app/build.gradle.kts for this test
android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    buildTypes {
        getByName("release") {
            proguardFiles("proguard-rules.pro")
        }
    }
}
KTS
echo "----- $f"; cat "$f"

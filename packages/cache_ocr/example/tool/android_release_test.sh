#!/usr/bin/env bash
# The emulator step of .github/workflows/ocr-release.yml: installs the RELEASE (R8) self-test APK, launches it, and waits for
# the OCR-RESULT line in logcat. Prints the per-page lines and every ML Kit / CacheOcr / AndroidRuntime log line.
set -uo pipefail
cd packages/cache_ocr/example
apk=build/app/outputs/flutter-apk/app-release.apk
pkg=co.cache.cache_ocr_example
log="$RUNNER_TEMP/ocr-release-logcat.log"
adb logcat -c
adb logcat -v time > "$log" 2>&1 &
lc=$!
adb install -r "$apk" || { echo 'install failed'; exit 1; }
adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1
end=$((SECONDS + 600))
until grep -q 'OCR-RESULT' "$log"; do
  [ "$SECONDS" -lt "$end" ] || { echo 'no OCR-RESULT in 10 min'; break; }
  sleep 5
done
sleep 3
kill $lc 2>/dev/null
echo '=== OCR lines'
grep -E 'OCR-' "$log" | sed 's/^.*OCR-/OCR-/'
echo '=== ML Kit / CacheOcr / crash / loader lines'
grep -i -E 'mlkit|CacheOcr|AndroidRuntime|FATAL|UnsatisfiedLink|dlopen|ClassNotFound|NoSuchMethod|NoClassDef|tflite|ocr_pipeline|vision' "$log" | tail -n 120
echo '=== last 60 lines of the app process'
grep -E "$pkg|flutter" "$log" | tail -n 60
grep -q 'OCR-RESULT pass' "$log"

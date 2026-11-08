#!/usr/bin/env bash
# The Android emulator step of .github/workflows/ocr.yml: runs the OCR integration test, each try within 15 minutes. A second
# try is made only when the first never printed OCR-RESULT (the flutter tool did not get the test going); a test that ran and
# failed fails the step.
set -uo pipefail
cd packages/cache_ocr/example
log="$RUNNER_TEMP/ocr-android.log"
: > "$log"
for attempt in 1 2; do
  timeout 900 flutter test integration_test/ocr_test.dart -d emulator-5554 --reporter expanded 2>&1 | tee -a "$log"
  status=${PIPESTATUS[0]}
  if grep -q 'OCR-RESULT pass' "$log" && [ "$status" -eq 0 ]; then exit 0; fi
  if grep -q 'OCR-RESULT fail' "$log"; then exit 1; fi
  echo "::warning::OCR test try $attempt ended with status $status and no OCR-RESULT"
done
exit 1

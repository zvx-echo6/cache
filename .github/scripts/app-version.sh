#!/usr/bin/env bash
# The app's version, read from app/pubspec.yaml ("version: 1.0.30+31" is version 1.0.30, build number 31) and checked against
# app/lib/version.dart: kAppVersion and kAppBuild must be the same two values (the app's update check compares kAppBuild, so a
# build whose two files disagree must not be made). Fails with one line naming both values and both files when they differ.
#
#   app-version.sh [--store] [<app folder>]
#
# --store: also fails when the build number is 1000 or more; that range is for test builds and never goes to a store.
# <app folder>: where pubspec.yaml and lib/version.dart are; "app" when not given (or the APP_DIR environment variable).
# On success prints the two values and, in a workflow, writes build_name and build_number to $GITHUB_OUTPUT.
# Runs on the Ubuntu and macOS runners: bash 3.2 and plain grep only.
set -euo pipefail

store=false
app=${APP_DIR:-app}
for arg in "$@"; do
  case "$arg" in
    --store) store=true ;;
    -*) echo "::error::app-version.sh: unknown option $arg"; exit 2 ;;
    *) app=$arg ;;
  esac
done
pubspec="$app/pubspec.yaml"
dart="$app/lib/version.dart"
for f in "$pubspec" "$dart"; do
  [[ -f "$f" ]] || { echo "::error::$f is missing (in a sparse checkout, add it to the checked-out paths)"; exit 1; }
done

line=$(grep -E '^version:' "$pubspec" | head -n 1 || true)
if [[ ! "$line" =~ ^version:\ *([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\ *$ ]]; then
  echo "::error::$pubspec's version must be <major>.<minor>.<patch>+<build number>, as in 1.0.30+31, found: $line"; exit 1
fi
name=${BASH_REMATCH[1]} build=${BASH_REMATCH[2]}

line=$(grep -E '^const String kAppVersion *=' "$dart" | head -n 1 || true)
if [[ ! "$line" =~ ^const\ String\ kAppVersion\ *=\ *\'([^\']*)\'\ *\; ]]; then
  echo "::error::$dart must have a line like const String kAppVersion = '1.0.30'; found: $line"; exit 1
fi
dart_name=${BASH_REMATCH[1]}

line=$(grep -E '^const int kAppBuild *=' "$dart" | head -n 1 || true)
if [[ ! "$line" =~ ^const\ int\ kAppBuild\ *=\ *([0-9]+)\ *\; ]]; then
  echo "::error::$dart must have a line like const int kAppBuild = 31; found: $line"; exit 1
fi
dart_build=${BASH_REMATCH[1]}

if [[ "$dart_name" != "$name" ]]; then
  echo "::error::The version differs: $pubspec has $name, $dart has kAppVersion '$dart_name'. Set both to the same version."; exit 1
fi
# Compared as numbers (base 10), so 048 and 48 are the same build.
if (( 10#$dart_build != 10#$build )); then
  echo "::error::The build number differs: $pubspec has +$build, $dart has kAppBuild = $dart_build. Set both to the same number."; exit 1
fi
if [[ "$store" == true ]] && (( 10#$build >= 1000 )); then
  echo "::error::Build number $build ($pubspec) is 1000 or more. That range is for test builds; a store build needs a number below 1000."; exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "build_name=$name" >> "$GITHUB_OUTPUT"
  echo "build_number=$build" >> "$GITHUB_OUTPUT"
fi
echo "version $name, build $build ($pubspec and $dart agree)"

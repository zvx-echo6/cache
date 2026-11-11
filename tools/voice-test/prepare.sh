#!/usr/bin/env bash
# Puts together, in one work folder, everything the Pocket TTS test APK is built from. Nothing is compiled here: the
# workflow (.github/workflows/voice-test-apk.yml) runs Gradle on the result.
#
#   1. the sherpa-onnx source at the pinned commit (only the TTS example app and the Kotlin API it links to)
#   2. the files in overlay/ copied over the example app, and the engine's WaveReader.kt added beside its Tts.kt
#   3. the engine's own prebuilt Android libraries for that release (arm64-v8a: the JNI library and ONNX Runtime)
#   4. the Pocket TTS model archive from the engine's tts-models release, unpacked into the app's assets
#   5. two reference clips in assets/ref: donated.wav from the model makers' voices catalogue, and archive.wav, the
#      clip from the model archive's test_wavs that the engine's own Pocket TTS examples use
#
# Every download is checked against a SHA-256 given by the caller, so a changed file stops the build.
#
# Usage: prepare.sh <work folder>, with these in the environment (the workflow sets them):
#   ENGINE_REPO ENGINE_TAG ENGINE_COMMIT LIBS_ARCHIVE LIBS_SHA256 MODEL_DIR MODEL_SHA256
#   VOICES_REPO VOICES_COMMIT DONATED_CLIP DONATED_SHA256 ARCHIVE_CLIP_SHA256
# A download already in <work folder>/downloads is not fetched again (it is still checked).
set -euo pipefail

work=${1:?usage: prepare.sh <work folder>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for name in ENGINE_REPO ENGINE_TAG ENGINE_COMMIT LIBS_ARCHIVE LIBS_SHA256 MODEL_DIR MODEL_SHA256 \
  VOICES_REPO VOICES_COMMIT DONATED_CLIP DONATED_SHA256 ARCHIVE_CLIP_SHA256; do
  if [ -z "${!name:-}" ]; then
    echo "prepare.sh: $name is not set" >&2
    exit 1
  fi
done

mkdir -p "$work/downloads"
work=$(cd "$work" && pwd)
downloads="$work/downloads"

# fetch <url> <file name> <sha256>
fetch() {
  local url=$1 file="$downloads/$2" sum=$3
  if [ ! -f "$file" ]; then
    echo "downloading $url"
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  echo "$sum  $file" | sha256sum -c -
}

# 1. The engine source. A plain anonymous fetch of the one pinned commit, without file contents it does not need.
engine="$work/engine"
rm -rf "$engine"
git init -q "$engine"
git -C "$engine" remote add origin "$ENGINE_REPO.git"
git -C "$engine" sparse-checkout set android/SherpaOnnxTts sherpa-onnx/kotlin-api
git -C "$engine" fetch -q --depth 1 --filter=blob:none origin "$ENGINE_COMMIT"
git -C "$engine" -c advice.detachedHead=false checkout -q FETCH_HEAD
if [ "$(git -C "$engine" rev-parse HEAD)" != "$ENGINE_COMMIT" ]; then
  echo "prepare.sh: the engine checkout is not at $ENGINE_COMMIT" >&2
  exit 1
fi
# The tag is named for people; the commit is what is built. Say so if the tag has been moved.
tag_commit=$(git -C "$engine" ls-remote origin "refs/tags/$ENGINE_TAG" "refs/tags/$ENGINE_TAG^{}" | tail -n 1 | cut -f 1) || tag_commit=
if [ "$tag_commit" = "$ENGINE_COMMIT" ]; then
  echo "engine: $ENGINE_TAG is $ENGINE_COMMIT"
else
  echo "::warning::The engine tag $ENGINE_TAG now points at ${tag_commit:-nothing}, not the pinned $ENGINE_COMMIT"
fi

app="$engine/android/SherpaOnnxTts"
src="$app/app/src/main"
kotlin="$src/java/com/k2fsa/sherpa/onnx"
if ! grep -q 'versionName "'"${ENGINE_TAG#v}"'"' "$app/app/build.gradle"; then
  echo "prepare.sh: the example app is not version ${ENGINE_TAG#v}" >&2
  exit 1
fi

# 2. The overlay, and the engine's wave reader (the example app links only Tts.kt).
cp -R "$here/overlay/." "$app/"
cp "$engine/sherpa-onnx/kotlin-api/WaveReader.kt" "$kotlin/WaveReader.kt"
for f in MainActivity.kt Tts.kt WaveReader.kt; do
  # -s follows the link the example keeps for Tts.kt
  if [ ! -s "$kotlin/$f" ]; then
    echo "prepare.sh: $f is missing from the app" >&2
    exit 1
  fi
done
# More memory for Gradle, as the engine's own APK script gives it: the assets are about 200 MB.
sed -i 's/-Xmx2048m/-Xmx6g/' "$app/gradle.properties"
grep -q -- '-Xmx6g' "$app/gradle.properties"

# 3. The engine's prebuilt libraries.
fetch "$ENGINE_REPO/releases/download/$ENGINE_TAG/$LIBS_ARCHIVE" "$LIBS_ARCHIVE" "$LIBS_SHA256"
rm -rf "$work/libs"
mkdir -p "$work/libs"
tar xjf "$downloads/$LIBS_ARCHIVE" -C "$work/libs" \
  ./jniLibs/arm64-v8a/libsherpa-onnx-jni.so ./jniLibs/arm64-v8a/libonnxruntime.so
cp "$work/libs/jniLibs/arm64-v8a/libsherpa-onnx-jni.so" "$work/libs/jniLibs/arm64-v8a/libonnxruntime.so" \
  "$src/jniLibs/arm64-v8a/"

# 4. The model.
fetch "$ENGINE_REPO/releases/download/tts-models/$MODEL_DIR.tar.bz2" "$MODEL_DIR.tar.bz2" "$MODEL_SHA256"
assets="$src/assets"
tar xjf "$downloads/$MODEL_DIR.tar.bz2" -C "$assets"
for f in lm_flow.int8.onnx lm_main.int8.onnx encoder.onnx decoder.int8.onnx text_conditioner.onnx vocab.json \
  token_scores.json LICENSE README.md; do
  if [ ! -s "$assets/$MODEL_DIR/$f" ]; then
    echo "prepare.sh: $f is missing from the model archive" >&2
    exit 1
  fi
done

# 5. The reference clips. The archive's clip is picked by its SHA-256; the other test_wavs stay out of the APK.
mkdir -p "$assets/ref"
archive_clip=
for f in "$assets/$MODEL_DIR"/test_wavs/*.wav; do
  if [ "$(sha256sum "$f" | cut -d ' ' -f 1)" = "$ARCHIVE_CLIP_SHA256" ]; then
    archive_clip=$f
  fi
done
if [ -z "$archive_clip" ]; then
  echo "prepare.sh: no clip in the model archive's test_wavs has the expected SHA-256" >&2
  exit 1
fi
echo "archive clip: test_wavs/$(basename "$archive_clip")"
cp "$archive_clip" "$assets/ref/archive.wav"
rm -rf "$assets/$MODEL_DIR/test_wavs"

fetch "$VOICES_REPO/resolve/$VOICES_COMMIT/$DONATED_CLIP" donated.wav "$DONATED_SHA256"
cp "$downloads/donated.wav" "$assets/ref/donated.wav"

# What went in, for the build log and the artifact.
{
  echo "engine: $ENGINE_REPO $ENGINE_TAG $ENGINE_COMMIT"
  echo "libraries: $LIBS_ARCHIVE sha256 $LIBS_SHA256"
  echo "model: $MODEL_DIR.tar.bz2 sha256 $MODEL_SHA256"
  echo "reference clip, donated: $VOICES_REPO at $VOICES_COMMIT, $DONATED_CLIP sha256 $DONATED_SHA256"
  echo "reference clip, archive: test_wavs/$(basename "$archive_clip") of the model archive sha256 $ARCHIVE_CLIP_SHA256"
  echo
  echo "files packaged (sha256, bytes, path under app/src/main):"
  (cd "$src" && find assets jniLibs -type f ! -name .gitignore ! -name .gitkeep | LC_ALL=C sort | while read -r f; do
    printf '%s %10d %s\n' "$(sha256sum "$f" | cut -d ' ' -f 1)" "$(stat -c %s "$f")" "$f"
  done)
} | tee "$work/build-info.txt"

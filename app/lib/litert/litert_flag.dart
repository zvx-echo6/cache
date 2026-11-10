/// True only in the Cache test APK built with `--dart-define=CACHE_LITERT=true` (android-test-apk.yml, its litert input). With it
/// false nothing of the LiteRT-LM path runs: no .litertlm files are listed and no channel is called.
const bool kLiteRt = bool.fromEnvironment('CACHE_LITERT');

import 'platform.dart' as plat;

/// Cache on Linux's own wording and rows (storage and log, share fallback, update banner, location). On only in the browser build
/// (plat.isWeb); a phone never sees them. A widget test cannot set plat.isWeb (a compile-time define), so it sets [debugLinuxUi].
bool? debugLinuxUi;

bool get linuxUi => debugLinuxUi ?? plat.isWeb;

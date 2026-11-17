// The browser's Screen Wake Lock (web_wake_lock_web.dart); everywhere else there is none (web_wake_lock_io.dart).
export 'web_wake_lock_io.dart' if (dart.library.js_interop) 'web_wake_lock_web.dart';

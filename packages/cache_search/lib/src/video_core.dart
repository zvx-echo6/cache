// The video connector for the UI: the phone and the desktop app run it in an isolate on the native library (video_core_io.dart);
// the browser reaches the same engine through Cache Server's helper (video_core_web.dart). Same public API.
export 'video_core_io.dart' if (dart.library.js_interop) 'video_core_web.dart';

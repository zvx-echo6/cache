// The browser map's mouse (map_mouse_web.dart); everywhere else it does nothing (map_mouse_io.dart).
export 'map_mouse_io.dart' if (dart.library.js_interop) 'map_mouse_web.dart';

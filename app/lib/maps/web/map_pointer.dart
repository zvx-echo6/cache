// The browser's map element (map_pointer_web.dart); everywhere else the call does nothing (map_pointer_io.dart).
export 'map_pointer_io.dart' if (dart.library.js_interop) 'map_pointer_web.dart';

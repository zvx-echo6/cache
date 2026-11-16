// The whole-route picture's maker for this platform: the native snapshotter on phones and the desktop app, MapLibre GL JS
// offscreen in a browser (Cache on Linux).
export 'route_snapshotter_io.dart' if (dart.library.js_interop) 'route_snapshotter_web.dart';

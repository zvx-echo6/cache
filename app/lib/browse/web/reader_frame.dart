// The browser's reader frame (reader_frame_web.dart); everywhere else the same names do nothing (reader_frame_io.dart), so the
// reader screen runs in tests and on phones unchanged.
export 'reader_frame_base.dart';
export 'reader_frame_io.dart' if (dart.library.js_interop) 'reader_frame_web.dart';

// The browser's own files: the file picker, drag and drop, the upload and the "leave this page?" warning. The web side is
// local_files_web.dart (package:web); everywhere else the same names do nothing, so the code that uses them runs in tests.
export 'local_files_base.dart';
export 'local_files_io.dart' if (dart.library.js_interop) 'local_files_web.dart';

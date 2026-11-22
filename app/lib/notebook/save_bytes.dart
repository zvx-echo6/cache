// Hands a file's bytes to the person in a browser (a download, or a new tab for a PDF). Web side: save_bytes_web.dart. Elsewhere it
// is never called (a phone opens an attached file through the share sheet).
export 'save_bytes_io.dart' if (dart.library.js_interop) 'save_bytes_web.dart';

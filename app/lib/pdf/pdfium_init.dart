import 'dart:io';
import 'dart:isolate';

import 'package:cache_search/cache_search.dart';
import 'package:pdfrx/pdfrx.dart';

/// The PDFium library the core and pdfrx share (its module path; the bundled `libpdfium.so` on Android, none on iOS, where the
/// core finds it in the process).
String? pdfiumLibraryPath() => Pdfrx.pdfiumModulePath ?? (Platform.isAndroid || Platform.isLinux ? 'libpdfium.so' : null);

Map<String, dynamic> _installFonts(String? lib) => SearchEngine.ingestCall(FfiCsNative.open(), 'probe', {
      'engines': {'pdfium_lib': ?lib},
      'fonts': true,
      'fonts_only': true,
    });

/// Makes sure the core has given PDFium the process's one font mapper (native, never replaced, usable from any isolate; see
/// packages/cache_ingest/src/pdfium.rs). Idempotent and quick; the core also does it by itself the first time it uses PDFium. A
/// failure is not an error here (PDFium then uses its own default fonts).
///
/// [onPdfrxWorker]: where pdfrx is in use the call runs on pdfrx's PDFium worker isolate, so it never overlaps with pdfrx's own PDFium
/// calls (PDFium is not thread-safe); in the background run, where pdfrx is not started, it runs on a short-lived isolate.
Future<void> installNativePdfFonts({bool onPdfrxWorker = false}) async {
  final lib = pdfiumLibraryPath();
  try {
    if (onPdfrxWorker) {
      await PdfrxEntryFunctions.instance.compute(_installFonts, lib);
    } else {
      await Isolate.run(() => _installFonts(lib));
    }
  } catch (_) {
    // the core of an older build has no such call, or PDFium is not there yet
  }
}

/// The addresses of the core's one PDFium lock (null when the core has none: an older build, or no core yet). Asked on a short-lived
/// isolate, before pdfrx starts its worker, so the worker can take the same lock around each of its PDFium calls.
Future<({int lock, int unlock})?> _coreLockFunctions() async {
  try {
    final lib = pdfiumLibraryPath();
    final r = await Isolate.run(() => _installFonts(lib));
    final f = r['lock_fns'];
    if (f is Map && f['lock'] is int && f['unlock'] is int) return (lock: f['lock'] as int, unlock: f['unlock'] as int);
  } catch (_) {
    // no core, or one without the lock
  }
  return null;
}

/// Starts pdfrx (PDFium for the viewer and the PDF indexing), the core's one font mapper and the core's one PDFium lock. pdfrx itself
/// no longer installs a font mapper (third_party/pdfrx_engine): it did so in every Flutter engine, with Dart callbacks bound to that
/// engine's isolate, and a second engine's (the background run's) replaced the first's. Its worker takes the core's lock around each
/// PDFium call, so the viewer and the core never use PDFium (which is not thread-safe) at the same moment.
Future<void> initPdfium() async {
  PdfiumLock.functions ??= await _coreLockFunctions();
  await pdfrxFlutterInitialize();
  await installNativePdfFonts(onPdfrxWorker: true);
}

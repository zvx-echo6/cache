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

/// Starts pdfrx (PDFium for the viewer and the PDF indexing) and the core's one font mapper. pdfrx itself no longer installs a font
/// mapper (third_party/pdfrx_engine): it did so in every Flutter engine, with Dart callbacks bound to that engine's isolate, and a
/// second engine's (the background run's) replaced the first's.
Future<void> initPdfium() async {
  await pdfrxFlutterInitialize();
  await installNativePdfFonts(onPdfrxWorker: true);
}

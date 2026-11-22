import 'dart:io';
import 'dart:isolate';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdfrx/pdfrx.dart';

import '../platform/app_log.dart' show logError;

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

/// The addresses of the core's one PDFium lock (null when the core did not give them: an older build, or no core yet). Asked on a
/// short-lived isolate, before pdfrx starts its worker, so the worker can take the same lock around each PDFium call. A failed ask is
/// tried again a few times; the core's backstop (the lock taken away from a holder that has had it for minutes) is logged when it has
/// happened.
Future<PdfiumLockFunctions?> _coreLockFunctions({int tries = 3}) async {
  final lib = pdfiumLibraryPath();
  for (var i = 0; i < tries; i++) {
    try {
      final r = await Isolate.run(() => _installFonts(lib));
      final f = r['lock_fns'];
      final st = r['lock_status'];
      if (st is Map && (st['backstop_releases'] as num? ?? 0) > 0) logError('PDFium lock: the core took the lock away from a holder that kept it for minutes', detail: '${st['last_backstop']}');
      if (f is Map && f['acquire'] is int && f['release'] is int && f['drop_owner'] is int && f['finalize'] is int) {
        return (acquire: f['acquire'] as int, release: f['release'] as int, dropOwner: f['drop_owner'] as int, finalize: f['finalize'] as int);
      }
    } catch (_) {
      // no core, or one without the lock
    }
    if (i + 1 < tries) await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}

/// Whether PDFium may be started without the core's lock. It may not, in the app: pdfrx's worker and the core would then use PDFium (which
/// is not thread-safe) at the same moment. Tests that run pdfrx without the core set this false.
bool pdfiumLockRequired = true;

/// Starts pdfrx (PDFium for the viewer and the PDF indexing), the core's one font mapper and the core's one PDFium lock. pdfrx itself
/// no longer installs a font mapper (third_party/pdfrx_engine): it did so in every Flutter engine, with Dart callbacks bound to that
/// engine's isolate, and a second engine's (the background run's) replaced the first's. Its worker takes the core's lock around each
/// PDFium call, so the viewer and the core never use PDFium at the same moment. When the core's lock cannot be had (asked three times)
/// this fails, loudly, and starts nothing: PDFium is never used without the lock for the life of the process.
Future<void> initPdfium() async {
  // A browser has no process PDFium, font mapper or core lock (and `Platform` throws there): it only starts pdfrx, and never needs the
  // lock (the web's PdfiumLock is a stub that does nothing).
  if (kIsWeb) return pdfrxFlutterInitialize();
  if (PdfiumLock.functions == null) {
    final fns = await _coreLockFunctions();
    if (fns == null) {
      if (pdfiumLockRequired) {
        logError('PDFium lock: the core did not give its lock; PDFium is not started');
        throw StateError('PDFium cannot start: the core did not give its lock');
      }
    } else {
      PdfiumLock.functions = fns;
    }
  }
  await pdfrxFlutterInitialize();
  await installNativePdfFonts(onPdfrxWorker: true);
}

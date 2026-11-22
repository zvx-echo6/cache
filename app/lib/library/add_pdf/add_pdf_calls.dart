import 'dart:isolate';

import 'package:cache_search/cache_search.dart';
import 'package:pdfrx/pdfrx.dart' show PdfrxEntryFunctions;

import '../../pdf/pdfium_init.dart';

/// The core's ingest job (packages/cache_ingest/INGEST-API.md): `start`, `step`, `ocr`, `cancel` and `probe`, each one JSON
/// object in and out. A failure throws [CacheSearchException] with the core's code. [pdfium]: the call may use PDFium (opening
/// the PDF, reading or drawing its pages). Tests use a fake.
abstract class IngestCalls {
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args, {bool pdfium = true});
}

Map<String, dynamic> _onWorker((String, Map<String, dynamic>) m) => SearchEngine.ingestCall(FfiCsNative.open(), m.$1, m.$2);

/// [IngestCalls] on the real core. The calls are handle-less and the job lives in the core's process, so any isolate may make them.
/// The core's PDFium has one font mapper for the whole process, native and never replaced (packages/cache_ingest/src/pdfium.rs; pdfrx
/// installs none, third_party/pdfrx_engine), so PDFium never calls back into Dart code and no isolate is special:
/// - the app's: a call that may use PDFium runs on pdfrx's own PDFium worker isolate ([PdfrxEntryFunctions.compute]), which keeps
///   PDFium, which is not thread-safe, to one thread with the PDF viewer; the rest runs on a short-lived isolate of its own, so a long
///   embed batch never holds up the PDF viewer, the UI or the search core's worker;
/// - the background run's ([CoreIngestCalls.withoutPdfrx]): pdfrx is never started there; every call runs on a short-lived isolate (the
///   core serialises its own PDFium calls).
class CoreIngestCalls implements IngestCalls {
  const CoreIngestCalls({this.init = initPdfium}) : usePdfrxWorker = true;

  /// The background run's calls: no pdfrx at all.
  const CoreIngestCalls.withoutPdfrx()
      : init = _none,
        usePdfrxWorker = false;

  static Future<void> _none() async {}

  /// Makes sure pdfrx (and its worker) is up before the first PDFium call.
  final Future<void> Function() init;

  /// PDFium calls go through pdfrx's worker isolate (the app), or not (the background run).
  final bool usePdfrxWorker;

  @override
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args, {bool pdfium = true}) async {
    if (pdfium && usePdfrxWorker) {
      await init();
      return PdfrxEntryFunctions.instance.compute(_onWorker, (op, args));
    }
    return Isolate.run(() => _onWorker((op, args)), debugName: 'cs_ingest_$op');
  }
}

import 'dart:isolate';

import 'package:cache_search/cache_search.dart';
import 'package:pdfrx/pdfrx.dart' show PdfrxEntryFunctions, pdfrxFlutterInitialize;

/// The core's ingest job (packages/cache_ingest/INGEST-API.md): `start`, `step`, `ocr`, `cancel` and `probe`, each one JSON
/// object in and out. A failure throws [CacheSearchException] with the core's code. [pdfium]: the call may use PDFium (opening
/// the PDF, reading or drawing its pages). Tests use a fake.
abstract class IngestCalls {
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args, {bool pdfium = true});
}

Map<String, dynamic> _onWorker((String, Map<String, dynamic>) m) => SearchEngine.ingestCall(FfiCsNative.open(), m.$1, m.$2);

/// [IngestCalls] on the real core. The calls are handle-less and the job lives in the core's process, so any isolate may make
/// them; which one matters:
/// - a call that may use PDFium runs on pdfrx's own PDFium worker isolate ([PdfrxEntryFunctions.compute]). The core uses the same
///   PDFium library pdfrx loaded, and PDFium then calls back into Dart code pdfrx set up on that isolate: from any other isolate
///   the Dart VM aborts the app ("Cannot invoke native callback from a different isolate"; found by the add-pdf-core CI job). It
///   also keeps PDFium, which is not thread-safe, to one thread with the PDF viewer.
/// - the rest (embedding, writing, the OCR answers) runs on a short-lived isolate of its own, so a long embed batch never holds
///   up the PDF viewer, the UI or the search core's worker.
class CoreIngestCalls implements IngestCalls {
  const CoreIngestCalls({this.init = pdfrxFlutterInitialize});

  /// Makes sure pdfrx (and its worker) is up before the first PDFium call.
  final Future<void> Function() init;

  @override
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args, {bool pdfium = true}) async {
    if (pdfium) {
      await init();
      return PdfrxEntryFunctions.instance.compute(_onWorker, (op, args));
    }
    return Isolate.run(() => _onWorker((op, args)), debugName: 'cs_ingest_$op');
  }
}

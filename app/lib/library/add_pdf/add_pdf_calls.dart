import 'dart:isolate';

import 'package:cache_search/cache_search.dart';

/// The core's ingest job (packages/cache_ingest/INGEST-API.md): `start`, `step`, `ocr`, `cancel` and `probe`, each one JSON
/// object in and out. A failure throws [CacheSearchException] with the core's code. Tests use a fake.
abstract class IngestCalls {
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args);
}

CsNative _openCore() => FfiCsNative.open();

/// [IngestCalls] on the real core. Each call runs on a short-lived isolate of its own: a step works for up to its budget (an
/// embed batch or the write can take longer), and it must never hold up the UI or the search core's worker, which answers
/// searches meanwhile. The calls are handle-less and the job lives in the core's process, so any isolate may make them.
class CoreIngestCalls implements IngestCalls {
  const CoreIngestCalls({this.open = _openCore});

  final CsNative Function() open;

  @override
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args) {
    final o = open;
    return Isolate.run(() => SearchEngine.ingestCall(o(), op, args), debugName: 'cs_ingest_$op');
  }
}

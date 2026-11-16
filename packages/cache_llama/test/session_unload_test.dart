import 'dart:isolate';

import 'package:cache_llama/llama_session_io.dart';
import 'package:flutter_test/flutter_test.dart';

const _report = '{"what":"anon","before_kb":555000,"after_kb":275000,"result":1}';

/// Frees after 300 ms (as a real free and purge take a moment) and answers with the allocator's report.
void _slowFree(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  rp.listen((dynamic m) async {
    final msg = m as Map;
    if (msg['type'] == 'free' && msg['id'] != null) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      toMain.send({'type': 'freed', 'id': msg['id'], 'purge': _report});
    }
  });
}

/// Never answers a free (an older worker, or one stuck).
void _silent(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  rp.listen((_) {});
}

void main() {
  test('unload waits until the worker has freed the model, and keeps what the allocator gave back', () async {
    final s = LlamaSession()..workerEntry = _slowFree;
    await s.startWorker();
    final clock = Stopwatch()..start();
    await s.unload();
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(250), reason: 'it returned before the worker had freed the model');
    expect(s.lastFreeReport, _report);
    await s.dispose();
  });

  test('a worker that never answers: unload gives up after its timeout, with no report', () async {
    final s = LlamaSession()
      ..workerEntry = _silent
      ..freeTimeout = const Duration(milliseconds: 200);
    await s.startWorker();
    await s.unload().timeout(const Duration(seconds: 5));
    expect(s.lastFreeReport, isNull);
    await s.dispose();
  });
}

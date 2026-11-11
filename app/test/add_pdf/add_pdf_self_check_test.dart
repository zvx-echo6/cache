import 'dart:async';

import 'package:cache/library/add_pdf/add_pdf_calls.dart';
import 'package:cache/library/add_pdf/add_pdf_engines.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers `probe` with [answer], or never when [answer] is null.
class _ProbeCalls implements IngestCalls {
  _ProbeCalls(this.answer);
  final Map<String, dynamic>? answer;
  final List<String> ops = [];
  final List<Map<String, dynamic>> sent = [];

  @override
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args, {bool pdfium = true}) {
    ops.add(op);
    sent.add(args);
    final a = answer;
    return a == null ? Completer<Map<String, dynamic>>().future : Future.value(a);
  }
}

void main() {
  const engines = {'embed_model': '/nonexistent/bge-m3-Q8_0.gguf'};

  test('the self-check returns the probe answer', () async {
    final calls = _ProbeCalls({
      'pdfium': {'ok': true, 'from': 'path', 'version': 'chromium/7811'},
      'embedder': {'ok': true},
      'model': {'ok': true},
      'classifier': {'ok': true, 'version': 2},
    });
    final r = await addPdfSelfCheck(calls, engines);
    expect(calls.ops, ['probe']);
    expect((r!['embedder'] as Map)['ok'], isTrue);
  });

  test('the self-check checks the model file and hash and does not load the embedder', () async {
    final calls = _ProbeCalls({
      'pdfium': {'ok': true},
      'embedder': {'ok': null, 'skipped': true},
      'model': {'ok': true},
      'classifier': {'ok': true, 'version': 2},
    });
    await addPdfSelfCheck(calls, engines);
    expect(calls.sent.single['load_embedder'], isFalse);
  });

  test('a probe with no answer ends at the timeout instead of hanging', () async {
    final calls = _ProbeCalls(null);
    final r = await addPdfSelfCheck(calls, engines, timeout: const Duration(milliseconds: 50));
    expect(calls.ops, ['probe']);
    expect(r, isNull);
  });
}

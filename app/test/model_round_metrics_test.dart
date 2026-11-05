import 'dart:io';

import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements ModelBackend {
  _Backend(this.replies);
  final List<PartialMessage> replies;
  final List<Map<String, dynamic>> requests = [];

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    requests.add(request);
    final reply = replies[requests.length - 1];
    if (reply.content.isNotEmpty) {
      yield PartialMessage(content: reply.content.substring(0, 1));
    }
    yield reply;
  }

  @override
  void stop() {}
}

class _Search extends Tool {
  @override
  String get name => 'search';
  @override
  String get description => 'Synthetic search';
  @override
  Map<String, dynamic> get parameters => {'type': 'object'};
  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async => [
    SourceResult(
      title: 'Synthetic source',
      snippet: 'A reference.',
      address: 'local:reference',
    ),
  ];
}

void main() {
  test(
    'absent counters remain unknown; explicit zero reuse means a fresh prompt',
    () {
      const remote = PartialMessage(promptTokens: 3000);
      expect(remote.evaluatedPromptTokens, isNull);
      final local = PartialMessage.fromJson(
        {'content': 'answer'},
        isFinal: true,
        promptTokens: 3000,
        reusedTokens: 0,
        startMs: 12,
        firstTokenMs: 15,
        totalMs: 20,
      );
      expect(local.evaluatedPromptTokens, 3000);
      expect((local.startMs, local.firstTokenMs, local.totalMs), (12, 15, 20));
    },
  );

  test(
    'round logs distinguish cumulative input from actual evaluation without logging content',
    () async {
      final dir = Directory.systemTemp.createTempSync('cache-round-metrics');
      final backend = _Backend([
        const PartialMessage(
          isFinal: true,
          toolCalls: [
            ToolCall(
              id: 'call_0',
              name: 'search',
              arguments: '{"query":"synthetic"}',
            ),
          ],
          promptTokens: 3000,
          reusedTokens: 0,
          generatedTokens: 20,
          startMs: 10,
          firstTokenMs: 12,
          totalMs: 30,
        ),
        PartialMessage.fromJson(
          {'content': 'The synthetic answer [1].'},
          isFinal: true,
          promptTokens: 5000,
          reusedTokens: 3000,
          generatedTokens: 50,
          startMs: 8,
          firstTokenMs: 11,
          totalMs: 25,
        ),
      ]);
      final loop = ToolLoop(backend: backend, tools: [_Search()]);
      try {
        await appLog.open(dir);
        await appLog.setLevel(LogLevel.standard);
        final updates = await loop.ask('private telemetry sentinel').toList();
        expect(backend.requests, hasLength(2));
        expect(updates.last.text, 'The synthetic answer [1].');
        expect(updates.last.promptTokens, 8000);
        expect(updates.last.generatedTokens, 70);
        await appLog.flush();
        final text = appLog.logFiles.map((f) => f.readAsStringSync()).join();
        expect(
          text,
          contains('Ask round 1 done: prompt=3000, reused=0, evaluated=3000'),
        );
        expect(
          text,
          contains(
            'Ask round 2 done: prompt=5000, reused=3000, evaluated=2000',
          ),
        );
        expect(text, contains('start_ms=8, first_token_ms=11'));
        expect(text, contains('Ask tool search starts'));
        expect(text, contains('Ask tool search finished in'));
        expect(text, isNot(contains('private telemetry sentinel')));
        expect(text, isNot(contains('The synthetic answer')));
      } finally {
        await loop.dispose();
        await appLog.close();
        dir.deleteSync(recursive: true);
      }
    },
  );
}

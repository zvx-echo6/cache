import 'dart:convert';
import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:cache_llama/llm_remote_events.dart';
import 'package:flutter_test/flutter_test.dart';

// The fixture is shared with server/src/llm.rs: there the native outputs must make the events, here the events must make the same
// PartialMessages that llama_session_io.dart makes from those native outputs.
const _fixture = '../packages/cache_llama/test/fixtures/llm-remote-parity.json';

/// Every field of a PartialMessage, so two can be compared.
Map<String, Object?> _flat(PartialMessage m) => {
      'content': m.content,
      'reasoning': m.reasoning,
      'toolCalls': [for (final c in m.toolCalls) c.toJson()],
      'isFinal': m.isFinal,
      'parseError': m.parseError,
      'promptTokens': m.promptTokens,
      'generatedTokens': m.generatedTokens,
      'reusedTokens': m.reusedTokens,
      'startMs': m.startMs,
      'firstTokenMs': m.firstTokenMs,
      'totalMs': m.totalMs,
    };

/// What llama_session_io.dart's _onMessage makes from the worker's 'partial' and 'final' messages.
List<PartialMessage> _ioMessages(Map<String, dynamic> n) => [
      for (final p in (n['partials'] as List).cast<String>()) PartialMessage.fromJson(jsonDecode(p) as Map<String, dynamic>),
      if (n['finish'] != null)
        PartialMessage.fromJson(jsonDecode(n['finish'] as String) as Map<String, dynamic>,
            isFinal: true, promptTokens: n['prompt_tokens'] as int, generatedTokens: n['generated_tokens'] as int),
    ];

/// The body of a stream as bytes cut into [size]-byte chunks (so also inside multi-byte characters).
Stream<List<int>> _chunked(String text, int size) async* {
  final b = utf8.encode(text);
  for (var i = 0; i < b.length; i += size) {
    yield b.sublist(i, i + size > b.length ? b.length : i + size);
  }
}

String _ndjson(List events) => events.map((e) => '${jsonEncode(e)}\n').join();

void main() {
  final fx = jsonDecode(File(_fixture).readAsStringSync()) as Map<String, dynamic>;

  for (final c in (fx['cases'] as List).cast<Map<String, dynamic>>()) {
    test('events of ${c['name']} make the messages the phone makes', () async {
      final native = c['native'] as Map<String, dynamic>;
      final text = _ndjson(c['events'] as List);
      for (final size in [1, 5, 4096]) {
        final events = await parseLlmEvents(_chunked(text, size)).toList();
        final failed = native['fail_after_partials'] == true;
        final msgs = <PartialMessage>[];
        for (final e in events) {
          switch (e) {
            case LlmPartial(:final message):
              msgs.add(message);
            case LlmDone(:final message):
              msgs.add(message);
            case LlmError(:final code, :final message):
              expect(failed, isTrue);
              expect(code, 'generation_failed');
              expect(message, 'The model stopped with an error while answering');
            case LlmQueued():
              fail('no queued event in this case');
          }
        }
        expect(events.last is LlmError, failed);
        expect([for (final m in msgs) _flat(m)], [for (final m in _ioMessages(native)) _flat(m)], reason: 'chunk size $size');
        if (!failed) expect(msgs.last.isFinal, isTrue);
      }
    });
  }

  test('queued events carry the position; blank lines and unknown types are skipped', () async {
    final text = '${_ndjson(fx['queued_events'] as List)}\n{"type":"future","x":1}\n';
    final events = await parseLlmEvents(_chunked(text, 7)).toList();
    expect([for (final e in events) (e as LlmQueued).position], [2, 1]);
  });

  test('a line that is not JSON is a FormatException', () {
    expect(() => parseLlmEventLine('not json'), throwsFormatException);
    expect(() => parseLlmEventLine('[1]'), throwsFormatException);
  });

  test('server error bodies give their message', () {
    expect(llmErrorMessage('{"ok":false,"error":{"code":"no_model","message":"No model is loaded"}}', 'x'), 'No model is loaded');
    expect(llmErrorMessage('<html>', 'HTTP 502'), 'HTTP 502');
  });
}

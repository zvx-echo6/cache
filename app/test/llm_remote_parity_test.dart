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
            case LlmStarted(:final id):
              expect(id, 'ID');
          }
        }
        expect(events.last is LlmError, failed);
        expect([for (final m in msgs) _flat(m)], [for (final m in _ioMessages(native)) _flat(m)], reason: 'chunk size $size');
        if (!failed) expect(msgs.last.isFinal, isTrue);
      }
    });
  }

  test('stop acts by what the stream has shown, and the final message comes after it', () async {
    final c = (fx['cases'] as List).cast<Map<String, dynamic>>().firstWhere((c) => c['stop_after_events'] != null);
    final events = await parseLlmEvents(_chunked(_ndjson(c['events'] as List), 9)).toList();
    final run = LlmRunState();
    expect(run.stopAction, LlmStopAction.abort, reason: 'nothing seen yet: close the request');
    final after = c['stop_after_events'] as int;
    for (var i = 0; i < after; i++) {
      run.see(events[i]);
    }
    expect(run.stopAction, LlmStopAction.requestStop);
    expect(run.id, 'ID');
    // the client stopped here and went on reading: the rest of the stream still ends with the final message
    final rest = [for (final e in events.skip(after)) if (e is LlmPartial) e.message else if (e is LlmDone) e.message];
    final io = _ioMessages(c['native'] as Map<String, dynamic>);
    expect(rest.last.isFinal, isTrue);
    expect(_flat(rest.last), _flat(io.last));
  });

  test('a queued stream has no id yet: stop closes the request', () {
    final run = LlmRunState()..see(const LlmQueued(2));
    expect(run.stopAction, LlmStopAction.abort);
  });

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

  test('a context_full error event becomes ContextFullException, by its code only', () async {
    final events = await parseLlmEvents(_chunked(_ndjson([
      {'type': 'error', 'code': 'context_full', 'message': 'any text at all'},
    ]), 7)).toList();
    expect((events.single as LlmError).toException(), isA<ContextFullException>());
    // the same words under another code stay a plain failure; a context_full code with other words is still the chat being full
    expect(const LlmError('start_failed', 'The chat is full').toException(), isA<StateError>());
    expect(const LlmError('context_full', '').toException(), isA<ContextFullException>());
    expect(const LlmError('generation_failed', 'x').toException(), isA<StateError>());
  });

  test('a done event with stop context marks the answer as cut off (as the phone does)', () async {
    final events = await parseLlmEvents(_chunked(_ndjson([
      {'type': 'done', 'role': 'assistant', 'content': 'half an answ', 'tool_calls': [], 'stop': 'context', 'prompt_tokens': 7, 'generated_tokens': 3},
      {'type': 'done', 'role': 'assistant', 'content': 'whole', 'tool_calls': [], 'prompt_tokens': 7, 'generated_tokens': 3},
    ]), 11)).toList();
    expect((events[0] as LlmDone).message.cutByContext, isTrue);
    expect((events[1] as LlmDone).message.cutByContext, isFalse);
  });
}

import 'dart:convert';

import 'package:cache/chat/ask_about.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/parity_fixtures.dart';
import 'support/act_core_stand_in.dart';

/// The core's tools: live_data answers with the recorded result, search with one line.
class LiveHost implements ToolHost {
  LiveHost(this.liveResult);
  final String liveResult;
  final calls = <(String, Map<String, dynamic>)>[];

  @override
  Future<List<Map<String, dynamic>>> schemas() async => [
        for (final n in ['live_data', 'search'])
          {
            'type': 'function',
            'function': {'name': n, 'parameters': {'type': 'object'}},
          },
      ];

  @override
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now) async {
    calls.add((name, args));
    if (name == 'live_data') return HostToolResult(content: liveResult, ids: const [NumberedAddress(n: 1, address: 'live:nws-alerts-point/1', title: 'Freeze Warning')]);
    return HostToolResult(content: '[${calls.length + 1}] Freezing pipes — Insulate them.', ids: [NumberedAddress(n: calls.length + 1, address: 'zim:x/$name${calls.length}', title: 'Freezing pipes')]);
  }

  @override
  Future<void> dispose() async {}
}

/// A model call as the phone's parser gives it: each message numbers its calls from call_0.
PartialMessage _call(String name, String arguments) =>
    PartialMessage(isFinal: true, toolCalls: [ToolCall(id: 'call_0', name: name, arguments: arguments)]);

List<Map<String, dynamic>> _messages(Map<String, dynamic> request) => [for (final m in request['messages'] as List) (m as Map).cast<String, dynamic>()];

void main() {
  final fixture = parityJson('ask-about-this-seed.json') as Map<String, dynamic>;
  final seededMessage = (fixture['seeded_message'] as Map).cast<String, dynamic>();
  final seededResult = (fixture['seeded_result'] as Map).cast<String, dynamic>();
  const about = AskAbout(sourceTitle: 'Weather Service alerts', sourceId: 'nws-alerts-point', place: 'Pocatello', label: 'Freeze Warning');

  test('the seeded arguments are the captures\' bytes', () {
    expect(about.arguments, (fixture['seed'] as Map).cast<String, dynamic>());
    final arguments = ((seededMessage['tool_calls'] as List).single as Map)['function']['arguments'] as String;
    expect(spacedJson(about.arguments), arguments);
    expect(spacedJson(about.arguments), '{"source": "nws-alerts-point", "place": "Pocatello"}');
    expect(spacedJson({'a': [1, 2.5, true, null], 'b': {'c': 'é "q"'}}), '{"a": [1, 2.5, true, null], "b": {"c": "é \\"q\\""}}');
  });

  test('Ask about this: the question, then the live_data call and its real result, then the model writes', () async {
    final host = LiveHost(seededResult['content'] as String);
    final backend = ScriptedBackend([
      (r) {
        final m = _messages(r);
        expect(m[1], {'role': 'user', 'content': about.question});
        expect(about.question,
            'Tell me about this weather service alerts item near Pocatello: Freeze Warning. What does it mean for me, and what should I do?');
        // Byte for byte as recorded: the seeded assistant message and the tool result after it.
        expect(jsonEncode(m[2]), jsonEncode(seededMessage));
        expect(jsonEncode(m[3]), jsonEncode(seededResult));
        expect(m, hasLength(4));
        expect(r['tools'], isNotNull);
        return say('A freeze warning means sub-freezing temperatures are expected [1].');
      },
    ]);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [], newHost: (_) => host)..setBackend(backend);
    await chat.send(about.question, seed: about);
    expect(host.calls.single.$1, 'live_data');
    expect(host.calls.single.$2, {'source': 'nws-alerts-point', 'place': 'Pocatello'});
    expect(backend.requests, hasLength(1));
    expect(chat.messages.last.text, contains('[1]'));
    expect(chat.messages.last.sources.single.result.address, 'live:nws-alerts-point/1');
  });

  test('the seed is not a tool round, and call ids run on from call_1 across the chat', () async {
    final host = LiveHost(seededResult['content'] as String);
    final backend = ScriptedBackend([
      (_) => _call('search', '{"query": "freeze"}'),
      (_) => _call('search', '{"query": "pipes"}'),
      (_) => _call('search', '{"query": "plants"}'),
      (r) {
        expect(r['tools'], isNull, reason: 'three rounds of its own after the seed, then the request without tools');
        return say('Cover plants and drain pipes [2].');
      },
      (_) => _call('search', '{"query": "pets"}'),
      (_) => say('Bring pets in [5].'),
    ]);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [], newHost: (_) => host)..setBackend(backend);
    await chat.send(about.question, seed: about);
    for (final r in backend.requests.take(3)) {
      expect(r['tools'], isNotNull);
    }
    await chat.send('And my dog?');
    final m = _messages(backend.requests.last);
    final ids = [
      for (final x in m)
        if (x['role'] == 'assistant' && x['tool_calls'] != null)
          for (final c in x['tool_calls'] as List) (c as Map)['id'],
    ];
    expect(ids, ['call_1', 'call_2', 'call_3', 'call_4', 'call_5']);
    expect([for (final x in m) if (x['role'] == 'tool') x['tool_call_id']], ids);
  });

  test('a chat without a seed numbers its first call call_1, and a reopened one carries on', () async {
    final backend = ScriptedBackend([(_) => _call('search', '{"query": "x"}'), (_) => say('Done.')]);
    final loop = ToolLoop(backend: backend, tools: const [], host: LiveHost('{}'));
    await loop.ask('hi').drain<void>();
    expect(((loop.messages[1]['tool_calls'] as List).single as Map)['id'], 'call_1');
    expect(loop.messages[2]['tool_call_id'], 'call_1');

    final reopened = ToolLoop(
      backend: ScriptedBackend([(_) => _call('search', '{"query": "y"}'), (_) => say('Done.')]),
      tools: const [],
      host: LiveHost('{}'),
      history: loop.messages,
    );
    await reopened.ask('more').drain<void>();
    final last = reopened.messages.lastWhere((x) => x['tool_calls'] != null);
    expect(((last['tool_calls'] as List).single as Map)['id'], 'call_2');
  });
}

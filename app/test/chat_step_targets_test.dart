// The steps list keeps what each call saw, so its lines can open it: the address of what a `read` opened and the arguments of a
// search. App side only: the tool messages the model reads are the same as before.
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

class _Read extends TextTool {
  @override
  String get name => 'read';
  @override
  String get description => 'read';
  @override
  Map<String, dynamic> get parameters => {'type': 'object'};
  @override
  Future<String> runText(Map<String, dynamic> args, NumberedResult? Function(int n) lookup) async => lookup((args['n'] as num).toInt())?.result.snippet ?? 'No such result.';
}

void main() {
  test('a finished read step keeps the source it opened, and a search step its query', () async {
    final backend = ScriptedBackend([
      (_) => callSearch('compass'),
      (_) => const PartialMessage(isFinal: true, toolCalls: [ToolCall(id: 'c2', name: 'read', arguments: '{"n":1}')]),
      (_) => say('It points north [1].'),
    ]);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: [
      BatchSearch([
        [hit('Compass', 'It points north.', address: 'place:osm:w1')],
      ]),
      _Read(),
    ])..setBackend(backend);
    await chat.send('compass?');
    final steps = chat.messages.last.steps;
    expect([for (final s in steps) s.tool], ['search', 'read']);
    expect(steps[0].arguments['query'], 'compass');
    expect(steps[1].source?.address, 'place:osm:w1');
    expect(steps[1].title, 'Compass');
  });
}

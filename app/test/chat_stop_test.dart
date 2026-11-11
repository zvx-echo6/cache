import 'dart:async';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

/// A search that waits for [release] before it returns, so a test can tap Stop while the tool runs.
class GatedSearch extends Tool {
  final entered = Completer<void>();
  final release = Completer<void>();
  int finished = 0;

  @override
  String get name => 'search';
  @override
  String get description => 'search';
  @override
  Map<String, dynamic> get parameters => {'type': 'object'};
  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    finished++;
    return [hit('Compass', 'It points north.')];
  }
}

void main() {
  test('Stop while Ask runs a tool ends the turn: nothing more is generated, Send works again and the next question is answered', () async {
    final search = GatedSearch();
    final backend = ScriptedBackend([(_) => callSearch('compass'), (_) => say('North is that way.')]);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: [search])..setBackend(backend);
    final sending = chat.send('Which way is north?');
    await search.entered.future;
    expect(chat.busy, isTrue);
    chat.stop();
    search.release.complete();
    await sending;
    expect(search.finished, 1, reason: 'the running tool finishes');
    expect(backend.requests, hasLength(1), reason: 'its result does not start another generation');
    expect(chat.busy, isFalse);
    expect(chat.canSend, isTrue);
    expect(chat.messages.last.phase, TurnPhase.done);
    expect(chat.messages.last.text, isEmpty);
    expect(chat.messages.last.error, isNull);

    await chat.send('And south?');
    await chat.whenIdle();
    expect(backend.requests, hasLength(2));
    expect(chat.messages.last.text, 'North is that way.');
    expect(chat.messages.last.error, isNull);
    expect(chat.busy, isFalse);
    // The next request carries the stopped turn as Stop before the model's first word leaves it.
    final sent = [for (final m in backend.requests[1]['messages'] as List) (m as Map)['role']];
    expect(sent, ['system', 'user', 'assistant', 'tool', 'assistant', 'user']);
  });
}

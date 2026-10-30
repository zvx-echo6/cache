import 'dart:async';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';

void main() {
  test('a question asked while the core starts shows Starting… and waits; it is answered once the core is up', () async {
    final core = Completer<bool>();
    final backend = ScriptedBackend([(_) => say('Boil it for a minute.')]);
    final chat = ChatController(tools: const [], waitForCore: () => core.future)..setBackend(backend);
    final sent = chat.send('How do I make water safe?');
    await Future<void>.delayed(Duration.zero);
    expect(chat.messages.last.phase, TurnPhase.starting);
    expect(backend.requests, isEmpty, reason: 'nothing goes to the model before the core is up');
    core.complete(true);
    await sent;
    expect(backend.requests, hasLength(1));
    expect(chat.messages.last.text, 'Boil it for a minute.');
    expect(chat.messages.last.error, isNull);
  });

  test('when the core does not start, the question is not answered: an error with Try again, and no tools are ever offered', () async {
    final store = ConversationStore.memory();
    addTearDown(store.close);
    var starts = 0;
    var up = false;
    final backend = ScriptedBackend([(_) => say('Boil it.')]);
    final chat = ChatController(tools: const [], waitForCore: () async {
      starts++;
      return up;
    })
      ..setBackend(backend)
      ..attachStore(store);
    await chat.send('How do I make water safe?');
    expect(chat.messages.last.error, kCoreDidNotStart);
    expect(backend.requests, isEmpty);
    expect(store.list(), isEmpty, reason: 'nothing is kept for a question that was not answered');
    // Try again asks the same question in place of the failed answer.
    up = true;
    await chat.retryLast();
    expect(starts, 2);
    expect(chat.messages.where((m) => m.isUser).map((m) => m.text), ['How do I make water safe?']);
    expect(chat.messages.last.text, 'Boil it.');
    expect((backend.requests.single['tools'] as List?) ?? const [], isEmpty, reason: 'no Dart tools: without a core host the model gets none');
  });
}

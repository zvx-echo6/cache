import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/local_llama_backend.dart';
import 'package:cache/history/titles.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';

/// A model session on a server: the test says where the answer waits ([queue]) and when its tokens arrive ([answer]).
class QueueSession implements LlamaSession {
  final queue = StreamController<int?>.broadcast();
  final requests = <Map<String, dynamic>>[];
  StreamController<PartialMessage>? answer;

  @override
  Stream<int?> get queuePosition => queue.stream;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    final messages = request['messages'] as List;
    if ((messages.last as Map)['content'] == kTitlePrompt) return Stream.value(const PartialMessage(isFinal: true, content: 'Boiling'));
    requests.add(request);
    return (answer = StreamController<PartialMessage>()).stream;
  }

  @override
  void stop() {}

  /// The rest of a session (load, metrics) is never used by the Ask screen.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  testWidgets('a turn waiting on the server says how many answers are ahead, then answers; the model sees none of it', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ask-queue-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final session = QueueSession();
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])
      ..setBackend(LocalLlamaBackend(session), queuePosition: session.queuePosition);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: AskScreen(app: app, chat: chat)));

    unawaited(chat.send('How long do I boil water?'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(session.requests, hasLength(1));
    expect(find.textContaining('Waiting for'), findsNothing);

    session.queue.add(2);
    await tester.pump();
    expect(find.text('Waiting for 2 answers ahead to finish'), findsOneWidget);

    session.queue.add(1);
    await tester.pump();
    expect(find.text('Waiting for another answer to finish'), findsOneWidget);
    expect(find.text('Waiting for 2 answers ahead to finish'), findsNothing);

    session.queue.add(null); // it runs
    await tester.pump();
    expect(find.textContaining('Waiting for'), findsNothing);

    session.answer!
      ..add(const PartialMessage(content: 'Boil it for one minute.'))
      ..add(const PartialMessage(isFinal: true, content: 'Boil it for one minute.'));
    await session.answer!.close();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Boil it for one minute.'), findsOneWidget);
    expect(find.textContaining('Waiting for'), findsNothing);

    // A position after the answer is done (its title waiting, say) is not shown.
    session.queue.add(3);
    await tester.pump();
    expect(find.textContaining('Waiting for'), findsNothing);

    expect(jsonEncode(session.requests), isNot(contains('Waiting')), reason: 'the line is on screen only');

    await tester.pumpWidget(const SizedBox.shrink());
    await session.queue.close();
    chat.dispose();
    app.dispose();
  });
}

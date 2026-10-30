import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

const _message = '[1] Purifying water, part 2 — Bring it to a rolling boil.\n[2] Water — Boiling kills germs.';

/// A host whose search gives a video moment (link and time in the id map, as the core sends them) and an article.
class _VideoHost implements ToolHost {
  final contents = <String>[];
  @override
  Future<List<Map<String, dynamic>>> schemas() async => [
        {
          'type': 'function',
          'function': {'name': 'search', 'parameters': {'type': 'object'}},
        },
      ];
  @override
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now) async {
    contents.add(_message);
    return const HostToolResult(content: _message, ids: [
      NumberedAddress(n: 1, address: 'lib:talks/7', title: 'Purifying water, part 2', link: 'https://videos.example/w/abc', time: 125.5),
      NumberedAddress(n: 2, address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Water', title: 'Water'),
    ]);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a video moment keeps its link and time beside the citation, and they are kept with the chat', () async {
    final store = ConversationStore.memory();
    addTearDown(store.close);
    final host = _VideoHost();
    final backend = ScriptedBackend([(_) => callSearch('boil water'), (_) => say('Boil it for a minute [1][2].')]);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [], newHost: (_) => host)
      ..setBackend(backend)
      ..attachStore(store);
    await chat.send('How do I make water safe?');
    final sources = chat.messages.last.sources;
    expect([for (final s in sources) (s.id, s.result.isVideoMoment)], [(1, true), (2, false)]);
    expect((sources.first.result.link, sources.first.result.time), ('https://videos.example/w/abc', 125.5));
    // the model got exactly the host's text: the link and time are never in it
    final toolMsg = (backend.requests.last['messages'] as List).cast<Map>().firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['content'], _message);
    // read back from storage, the citation still opens the video at its moment
    final stored = store.messages(store.list().single.id).last;
    final back = ChatMessage.stored(stored).sources;
    expect((back.first.result.link, back.first.result.time), ('https://videos.example/w/abc', 125.5));
    expect(back.last.result.isVideoMoment, isFalse);
    expect(stored.citations.last.toJson().containsKey('time'), isFalse, reason: 'an article stores what it always did');
    chat.dispose();
  });

  testWidgets('tapping a video citation opens the video at its moment; an article still opens in the Library', (tester) async {
    final dir = Directory.systemTemp.createTempSync('video-cite-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
    chat.messages.add(ChatMessage.assistant()
      ..phase = TurnPhase.done
      ..text = 'Boil it [1][2].'
      ..sources = const [
        NumberedResult(1, SourceResult(title: 'Purifying water, part 2', snippet: '', address: 'lib:talks/7', link: 'https://videos.example/w/abc', time: 125.5)),
        NumberedResult(2, SourceResult(title: 'Water', snippet: '', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Water')),
      ]);
    (String, double)? video;
    String? article;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: AskScreen(app: app, chat: chat, onOpenSource: (a) => article = a, onOpenVideo: (l, t) => video = (l, t)),
    ));
    await tester.tap(find.text('2 sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('[1] Purifying water, part 2'));
    expect(video, ('https://videos.example/w/abc', 125.5));
    expect(article, isNull);
    await tester.tap(find.text('[2] Water'));
    expect(article, 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Water');
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    chat.dispose();
  });
}

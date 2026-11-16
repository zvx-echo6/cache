// An answer whose turn searched or read the person's sources but cites none of them says "Searched your sources, but cites none
// of them"; "Not from your sources" is only for an answer whose turn used none (owner, 2026-11-14). The same after the chat is
// reopened from history.

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

const _searched = 'Searched your sources, but cites none of them';
const _notFrom = 'Not from your sources';

void main() {
  group('the turn says whether it used the sources', () {
    late ConversationStore store;
    setUp(() => store = ConversationStore.memory());
    tearDown(() => store.close());

    ChatController controller(ScriptedBackend backend) => ChatController(
          actCore: const ActCoreStandIn(),
          tools: [BatchSearch([[hit('Survival manual', 'Pack a signal mirror.')]])],
        )
          ..setBackend(backend)
          ..attachStore(store);

    test('searched, cites nothing: flagged live and after reopening', () async {
      final chat = controller(ScriptedBackend([(_) => callSearch('wildfire kit'), (_) => say('Pack water, a mirror and a first aid kit.')]));
      await chat.send('What should I pack for a wildfire evacuation?');
      final reply = chat.messages.last;
      expect(reply.sources, isEmpty);
      expect(reply.searchedSources, isTrue);
      final id = store.list().single.id;
      chat.newChat();
      chat.openConversation(id);
      expect(chat.messages.last.searchedSources, isTrue, reason: 'the stored turn has its search call');
      chat.dispose();
    });

    test('searched and cites: the sources are the label, flagged too', () async {
      final chat = controller(ScriptedBackend([(_) => callSearch('mirror'), (_) => say('Pack a signal mirror [1].')]));
      await chat.send('What signals can I carry?');
      expect(chat.messages.last.sources, hasLength(1));
      expect(chat.messages.last.searchedSources, isTrue);
      chat.dispose();
    });

    test('no search or read: not flagged, live and after reopening; each answer judged by its own turn', () async {
      final chat = controller(ScriptedBackend([(_) => callSearch('mirror'), (_) => say('A mirror.'), (_) => say('Hello again.')]));
      await chat.send('What signals can I carry?');
      await chat.send('Thanks!');
      expect(chat.messages.last.searchedSources, isFalse, reason: 'the second turn searched nothing');
      final id = store.list().single.id;
      chat.newChat();
      chat.openConversation(id);
      final answers = chat.messages.where((m) => !m.isUser).toList();
      expect(answers.map((m) => m.searchedSources), [true, false]);
      chat.dispose();
    });
  });

  test('turnUsedSources: a search or a read in the turn counts; other tools and none do not', () {
    Map<String, dynamic> calls(List<String> names) => {
          'role': 'assistant',
          'content': null,
          'tool_calls': [for (final n in names) {'id': 'c', 'type': 'function', 'function': {'name': n, 'arguments': '{}'}}],
        };
    expect(turnUsedSources([calls(['search'])]), isTrue);
    expect(turnUsedSources([calls(['nearby']), calls(['read'])]), isTrue);
    expect(turnUsedSources([calls(['nearby', 'calculate'])]), isFalse);
    expect(turnUsedSources([{'role': 'tool', 'content': 'x'}, {'role': 'assistant', 'content': 'Hi'}]), isFalse);
    expect(turnUsedSources(const []), isFalse);
    expect(usesSources('search') && usesSources('read') && !usesSources('locate'), isTrue);
  });

  // The screen after a real turn (no hand-set flag): a search, then an answer citing nothing.
  testWidgets('on screen after a turn that searched and cites nothing: "$_searched", not "$_notFrom"', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ask-label-turn-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: [BatchSearch([[hit('Survival manual', 'Pack a signal mirror.')]])])
      ..setBackend(ScriptedBackend([(_) => callSearch('wildfire kit'), (_) => say('Pack water, a mirror and a first aid kit.')]));
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    addTearDown(() {
      chat.dispose();
      app.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
    await tester.runAsync(() => chat.send('What should I pack for a wildfire evacuation?'));
    await tester.pump();
    expect(find.text(_notFrom), findsNothing, reason: 'it did search the sources');
    expect(find.text(_searched), findsOneWidget);
  });

  group('the label under an answer with no sources', () {
    Future<void> show(WidgetTester tester, {required bool searched}) async {
      final dir = Directory.systemTemp.createTempSync('ask-label-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
      chat.messages.add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'Pack water and a mirror.'
        ..searchedSources = searched);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
      await tester.pump();
      addTearDown(() {
        chat.dispose();
        app.dispose();
      });
    }

    testWidgets('searched: "$_searched"', (tester) async {
      await show(tester, searched: true);
      expect(find.text(_searched), findsOneWidget);
      expect(find.text(_notFrom), findsNothing);
    });

    testWidgets('not searched: "$_notFrom", as before', (tester) async {
      await show(tester, searched: false);
      expect(find.text(_notFrom), findsOneWidget);
      expect(find.text(_searched), findsNothing);
    });
  });
}

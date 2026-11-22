import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/model_backend.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/history/titles.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

const _engineText = 'prompt does not fit the context (9001 tokens)';

/// A model whose request never fits: the session throws the typed exception.
class _FullBackend implements ModelBackend {
  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) => Stream.error(const ContextFullException(_engineText));

  @override
  void stop() {}
}

/// A model whose answer is cut off by the context.
class _CutBackend implements ModelBackend {
  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    if (((request['messages'] as List).last as Map)['content'] == kTitlePrompt) {
      yield const PartialMessage(isFinal: true, content: 'Safe water');
      return;
    }
    yield const PartialMessage(isFinal: true, content: 'First you boil the water and then', cutByContext: true);
  }

  @override
  void stop() {}
}

Future<(AppState, ChatController)> _screen(WidgetTester tester, ModelBackend backend, {ConversationStore? store}) async {
  final dir = Directory.systemTemp.createTempSync('chat-full-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
  final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..setBackend(backend);
  if (store != null) chat.attachStore(store);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
  return (app, chat);
}

void main() {
  test('PartialMessage reads the context stop from the native JSON', () {
    expect(PartialMessage.fromJson({'content': 'x', 'stop': 'context'}, isFinal: true).cutByContext, isTrue);
    expect(PartialMessage.fromJson({'content': 'x'}, isFinal: true).cutByContext, isFalse);
  });

  testWidgets('a prompt that does not fit shows the plain message and New chat, never the engine text', (tester) async {
    final (_, chat) = await _screen(tester, _FullBackend());
    await chat.send('How long do I boil water?');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('This chat is full. Start a new chat to keep asking.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-new-chat')), findsOneWidget);
    expect(find.textContaining('does not fit'), findsNothing);
    expect(find.textContaining('9001'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('ask-new-chat'))).height, greaterThanOrEqualTo(44));
    expect(find.text('No answer was produced.'), findsNothing);
  });

  testWidgets('New chat from the full message starts a new chat', (tester) async {
    final (_, chat) = await _screen(tester, _FullBackend());
    await chat.send('How long do I boil water?');
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.messages, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('ask-new-chat')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.messages, isEmpty);
    expect(find.text('This chat is full. Start a new chat to keep asking.'), findsNothing);
  });

  testWidgets('a cut-off answer stays as written with the muted note and New chat', (tester) async {
    final (_, chat) = await _screen(tester, _CutBackend());
    await chat.send('How do I make water safe?');
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.messages.last.cutShort, isTrue);
    expect(find.textContaining('First you boil the water and then'), findsOneWidget);
    expect(find.text('This answer was cut short because the chat is full.'), findsOneWidget);
    expect(find.text('Answer delivered'), findsNothing);
    final note = tester.widget<Text>(find.text('This answer was cut short because the chat is full.'));
    expect(note.style?.fontSize, 14);
    expect(tester.getSize(find.byKey(const ValueKey('ask-new-chat'))).height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const ValueKey('ask-new-chat')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.messages, isEmpty);
    expect(find.text('This answer was cut short because the chat is full.'), findsNothing);
  });

  testWidgets('an ordinary answer shows neither note', (tester) async {
    final (_, chat) = await _screen(tester, ScriptedBackend([(_) => say('Boil it for a minute.')]));
    await chat.send('How do I make water safe?');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('ask-new-chat')), findsNothing);
    expect(find.text('Answer delivered'), findsOneWidget);
  });

  test('a full chat is kept as a flag, not as an error, and reopened the same', () async {
    final store = ConversationStore.memory();
    addTearDown(store.close);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])
      ..setBackend(_FullBackend())
      ..attachStore(store);
    await chat.send('How long do I boil water?');
    expect(chat.messages.last.chatFull, isTrue);
    expect(chat.messages.last.error, isNull);
    final id = store.list().single.id;
    chat.newChat();
    chat.openConversation(id);
    expect(chat.messages.last.chatFull, isTrue);
    expect(chat.messages.last.error, isNull);
  });
}

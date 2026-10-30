import 'dart:io';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/system_prompt.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'chat_fakes.dart';

String _prompt(Map<String, dynamic> request) => ((request['messages'] as List).first as Map)['content'] as String;

const _clockLine = 'Current local date and time: ';

/// The prompt without its clock line, which is the current time on every turn.
String _fixed(String prompt) => [for (final l in prompt.split('\n')) if (!l.startsWith(_clockLine)) l].join('\n');

void main() {
  test('voice mode is per conversation: set before the first question, on every request, and a new chat is text', () async {
    final backend = ScriptedBackend([(_) => say('Hello')]);
    final chat = ChatController(tools: const [])..setBackend(backend);
    expect(chat.voice, isFalse);
    await chat.send('hi');
    expect(_prompt(backend.requests.last), isNot(contains(kVoiceLine)));
    await chat.send('still typing');
    expect(_prompt(backend.requests.last), isNot(contains(kVoiceLine)));

    chat.newChat();
    chat.setVoice(true);
    await chat.send('by voice');
    expect(_prompt(backend.requests.last), endsWith('\n$kVoiceLine'));
    await chat.send('still by voice');
    expect(_prompt(backend.requests.last), endsWith('\n$kVoiceLine'));

    chat.newChat();
    expect(chat.voice, isFalse);
    await chat.send('a new chat');
    expect(_prompt(backend.requests.last), isNot(contains(kVoiceLine)));
  });

  test('switching the mode of a chat that has started starts a new chat in that mode; the old one keeps its mode', () async {
    final store = ConversationStore.memory();
    addTearDown(store.close);
    final backend = ScriptedBackend([(_) => say('Hello')]);
    final chat = ChatController(tools: const [])
      ..attachStore(store)
      ..setBackend(backend);
    await chat.send('typed');
    await chat.whenIdle();
    final text = chat.activeId!;

    chat.setVoice(true);
    expect(chat.voice, isTrue);
    expect(chat.activeId, isNull);
    expect(chat.messages, isEmpty);
    await chat.send('spoken');
    await chat.whenIdle();
    expect(_prompt(backend.requests.last), endsWith('\n$kVoiceLine'));
    expect(chat.activeId, isNot(text));
    expect(store.get(text)!.voice, isFalse);
    expect(store.get(chat.activeId!)!.voice, isTrue);
  });

  test('a reopened chat keeps its mode and the same prompt bytes, voice and text, after a restart', () async {
    final dir = Directory.systemTemp.createTempSync('chat_voice_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/c.db';

    var store = ConversationStore.open(path);
    var backend = ScriptedBackend([(_) => say('Hello')]);
    var chat = ChatController(tools: const [], locationKnown: () => true)
      ..attachStore(store)
      ..setBackend(backend);
    chat.setVoice(true);
    await chat.send('spoken');
    await chat.whenIdle();
    final voiceId = chat.activeId!;
    final voicePrompt = _prompt(backend.requests.last);
    chat.newChat();
    await chat.send('typed');
    await chat.whenIdle();
    final textId = chat.activeId!;
    final textPrompt = _prompt(backend.requests.last);
    expect(voicePrompt, endsWith('\n$kVoiceLine'));
    expect(textPrompt, isNot(contains(kVoiceLine)));
    store.close();

    store = ConversationStore.open(path);
    addTearDown(store.close);
    backend = ScriptedBackend([(_) => say('Again')]);
    chat = ChatController(tools: const [], locationKnown: () => true)
      ..attachStore(store)
      ..setBackend(backend);
    for (final (id, voice, before) in [(voiceId, true, voicePrompt), (textId, false, textPrompt), (voiceId, true, voicePrompt)]) {
      chat.openConversation(id);
      expect(chat.voice, voice);
      await chat.send('once more');
      await chat.whenIdle();
      final after = _prompt(backend.requests.last);
      expect(_fixed(after), _fixed(before));
      // The clock line is the current time, as on every turn.
      expect(after.split('\n')[1], startsWith(_clockLine));
    }
  });

  test('a database from before voice was stored opens with every conversation in text', () {
    final dir = Directory.systemTemp.createTempSync('chat_voice_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/c.db';
    var store = ConversationStore.open(path);
    final id = store.create(title: 'Old', voice: true).id;
    store.close();
    final db = sqlite3.open(path);
    db.execute('ALTER TABLE conversations DROP COLUMN voice');
    db.userVersion = 2;
    db.close();

    store = ConversationStore.open(path);
    addTearDown(store.close);
    expect(store.get(id)!.voice, isFalse);
    expect(store.create(title: 'New', voice: true).voice, isTrue);
  });
}

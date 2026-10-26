import 'dart:io';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/history/markdown_export.dart';
import 'package:cache/history/titles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';

void main() {
  late ConversationStore store;
  var clock = DateTime(2026, 10, 26, 12);

  setUp(() {
    clock = DateTime(2026, 10, 26, 12);
    store = ConversationStore.memory(now: () => clock);
  });
  tearDown(() => store.close());

  void say1(int id, String q, String a, {List<StoredCitation> cites = const []}) {
    store.addMessage(id, role: 'user', content: q, message: {'role': 'user', 'content': q});
    store.addMessage(id,
        role: 'assistant',
        content: a,
        message: {'role': 'assistant', 'content': a},
        citations: cites,
        stats: const GenerationStats(promptTokens: 10, generatedTokens: 5, durationMs: 900));
  }

  group('store', () {
    test('FTS5 is available', () {
      expect(store.search('anything'), isEmpty);
    });

    test('create and continue keep the exact transcript and the stats', () {
      final c = store.create(title: 'How do I treat a burn?', model: 'Gemma 4 E2B');
      store.addMessage(c.id, role: 'user', content: 'burn?', message: {'role': 'user', 'content': 'burn?'});
      final call = {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {'id': 'c1', 'type': 'function', 'function': {'name': 'search', 'arguments': '{"query":"burn"}'}},
        ],
      };
      store.addMessage(c.id, role: 'assistant', content: '', message: call);
      store.addMessage(c.id,
          role: 'tool', content: '[1] Burn — Cool it.', message: {'role': 'tool', 'tool_call_id': 'c1', 'content': '[1] Burn — Cool it.'});
      store.addMessage(c.id,
          role: 'assistant',
          content: 'Cool it [1].',
          message: {'role': 'assistant', 'content': 'Cool it [1]. Also [9].'},
          citations: const [StoredCitation(n: 1, title: 'Burn', snippet: 'Cool it.', address: 'zim:Burn')],
          stats: const GenerationStats(promptTokens: 321, generatedTokens: 42, durationMs: 1234));

      expect(store.transcript(c.id), [
        {'role': 'user', 'content': 'burn?'},
        call,
        {'role': 'tool', 'tool_call_id': 'c1', 'content': '[1] Burn — Cool it.'},
        {'role': 'assistant', 'content': 'Cool it [1]. Also [9].'},
      ]);
      final msgs = store.messages(c.id);
      expect([for (final m in msgs) m.shown], [true, false, false, true]);
      expect(msgs.last.content, 'Cool it [1].');
      expect(msgs.last.citations.single.address, 'zim:Burn');
      expect(msgs.last.stats.promptTokens, 321);
      expect(msgs.last.stats.generatedTokens, 42);
      expect(msgs.last.stats.durationMs, 1234);

      // Continue: more messages go after the old ones.
      say1(c.id, 'and a scald?', 'Same.');
      expect(store.transcript(c.id).length, 6);
      expect(store.get(c.id)!.model, 'Gemma 4 E2B');
    });

    test('rename, pin, generated title only replaces the question title', () {
      final a = store.create(title: 'q');
      expect(store.setGeneratedTitle(a.id, 'Burns'), isTrue);
      expect(store.get(a.id)!.title, 'Burns');
      store.rename(a.id, 'My title');
      expect(store.setGeneratedTitle(a.id, 'Other'), isFalse);
      expect(store.get(a.id)!.title, 'My title');
      expect(store.get(a.id)!.titleSource, TitleSource.user);
      store.setPinned(a.id, true);
      expect(store.get(a.id)!.pinned, isTrue);
    });

    test('list is most recently changed first', () {
      final a = store.create(title: 'a');
      clock = clock.add(const Duration(minutes: 1));
      final b = store.create(title: 'b');
      expect([for (final c in store.list()) c.id], [b.id, a.id]);
      clock = clock.add(const Duration(minutes: 1));
      say1(a.id, 'x', 'y');
      expect([for (final c in store.list()) c.id], [a.id, b.id]);
    });

    test('search finds titles and message text, one hit per chat, prefix on the last word', () {
      final a = store.create(title: 'Water purification');
      say1(a.id, 'How do I boil water?', 'Boil it for one minute at a rolling boil.');
      final b = store.create(title: 'Fire starting');
      say1(b.id, 'flint steel?', 'Strike the steel against the flint.');

      expect([for (final h in store.search('purif')) h.conversation.id], [a.id]);
      final byText = store.search('rolling boi');
      expect([for (final h in byText) h.conversation.id], [a.id]);
      expect(byText.single.snippet, contains('rolling'));
      expect(store.search('water').length, 1);
      expect([for (final h in store.search('flint')) h.conversation.id], [b.id]);
      expect(store.search('zzzz'), isEmpty);
      expect(store.search('   '), isEmpty);
      // Quotes and operators typed by a person are plain text, not query syntax.
      expect(() => store.search('"unbalanced AND (OR *'), returnsNormally);
      // Renamed titles are searchable at once; the old title is not.
      store.rename(a.id, 'Drinking supply');
      expect([for (final h in store.search('drinking')) h.conversation.id], [a.id]);
      expect(store.search('purification'), isEmpty);
    });

    test('delete hides, undelete restores, purge removes for good', () {
      final a = store.create(title: 'Gone soon');
      say1(a.id, 'hello there', 'hi');
      store.delete(a.id);
      expect(store.list(), isEmpty);
      expect(store.search('hello'), isEmpty);
      expect(store.get(a.id), isNull);
      store.undelete(a.id);
      expect(store.list().length, 1);
      expect(store.search('hello').length, 1);
      store.delete(a.id);
      store.purgeDeleted();
      expect(store.messages(a.id), isEmpty);
      expect(store.search('hello'), isEmpty);
    });

    test('delete all removes everything', () {
      for (var i = 0; i < 3; i++) {
        say1(store.create(title: 'chat $i').id, 'question $i', 'answer $i');
      }
      store.deleteAll();
      expect(store.list(), isEmpty);
      expect(store.search('question'), isEmpty);
    });
  });

  group('restart', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('chat_store_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('conversation, messages and numbering survive closing and reopening the file', () async {
      final path = '${dir.path}/c.db';
      var s = ConversationStore.open(path);
      final c = s.create(title: 'Burns', model: 'M');
      say1Via(s, c.id);
      const state = MemoryNumberingState();
      final numbering = MemoryNumbering([]);
      await numbering.format([hit('Burn', 'Cool it.'), hit('Scald', 'Same.')]);
      s.setNumbering(c.id, await state.save(numbering));
      s.close();

      s = ConversationStore.open(path);
      addTearDown(s.close);
      expect(s.list().single.title, 'Burns');
      expect(s.messages(c.id).length, 2);
      expect(s.search('cool').length, 1);
      final restored = (await state.restore(s.numbering(c.id)!))!;
      expect([for (final i in await restored.ids()) '${i.n}:${i.address}'], ['1:zim:Burn', '2:zim:Scald']);
      // Numbers continue at 3; an address seen before keeps its number.
      expect(await restored.format([hit('New', 'x'), hit('Burn', 'again')]), '[3] New — x\n[1] Burn — again');
    });
  });

  group('titles and export', () {
    test('question title is trimmed to about 40 characters', () {
      expect(questionTitle('  How do I   treat a burn? '), 'How do I treat a burn?');
      final long = questionTitle('How do I purify water from a stream when I have no filter or tablets?');
      expect(long.runes.length, lessThanOrEqualTo(kQuestionTitleLength + 1));
      expect(long.endsWith('…'), isTrue);
      expect(long, 'How do I purify water from a stream…');
    });

    test('a generated title keeps the first line only', () {
      expect(cleanTitle('  Treating burns \nExplanation'), 'Treating burns');
      expect(cleanTitle('   '), isNull);
    });

    test('markdown lists the cited sources at the end', () {
      final c = store.create(title: 'Burns');
      say1(c.id, 'burn?', 'Cool it [1], see [2].', cites: const [
        StoredCitation(n: 1, title: 'Burn', snippet: '', address: 'zim:Burn'),
        StoredCitation(n: 2, title: 'Scald', snippet: '', address: 'zim:Scald'),
      ]);
      say1(c.id, 'again?', 'Yes [1].', cites: const [StoredCitation(n: 1, title: 'Burn', snippet: '', address: 'zim:Burn')]);
      final md = conversationToMarkdown(store.get(c.id)!, store.messages(c.id));
      expect(md, startsWith('# Burns\n\n**You**\n\nburn?\n\n**Cache**\n\nCool it [1], see [2].'));
      expect(md, endsWith('## Sources\n\n- [1] Burn (zim:Burn)\n- [2] Scald (zim:Scald)'));
    });
  });

  group('chat controller', () {
    ChatController make(ConversationStore s, ScriptedBackend backend, BatchSearch search) {
      final chat = ChatController(
        tools: [search],
        newNumbering: () => MemoryNumbering([]),
        numberingState: const MemoryNumberingState(),
      )
        ..attachStore(s)
        ..setBackend(backend, modelName: 'Test model');
      return chat;
    }

    test('stores a chat as it goes, writes a title, and a restart continues it with numbering intact', () async {
      final dir = Directory.systemTemp.createTempSync('chat_ctl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/c.db';

      var s = ConversationStore.open(path);
      var backend = ScriptedBackend([
        (_) => callSearch('burn'),
        (_) => say('Cool it [1], get help [2]. Bogus [7].'),
      ]);
      var chat = make(s, backend, BatchSearch([[hit('Burn', 'Cool it.'), hit('Manual', 'Seek help.')]]));
      await chat.send('How do I treat a burn on my hand?');
      await chat.whenIdle();

      final id = chat.activeId!;
      expect(s.get(id)!.title, 'Treating burns'); // replaced by the model's title
      expect(s.get(id)!.titleSource, TitleSource.generated);
      expect(backend.titleRequests.length, 1);
      // The title request is the conversation plus the instruction, with the same tool definitions.
      final tr = backend.titleRequests.single;
      expect(tr['tools'], backend.requests.first['tools']);
      expect((tr['messages'] as List).length, 6); // system, user, call, tool, answer, instruction
      final stored = s.messages(id);
      expect([for (final m in stored) m.role], ['user', 'assistant', 'tool', 'assistant']);
      expect(stored.last.content, 'Cool it [1], get help [2]. Bogus.');
      expect([for (final c in stored.last.citations) c.n], [1, 2]);
      expect(stored.last.stats.promptTokens, 120);
      expect(stored.last.stats.durationMs, greaterThanOrEqualTo(0));
      expect(s.get(id)!.model, 'Test model');
      s.close();

      // Restart: new store, new controller, nothing in memory.
      s = ConversationStore.open(path);
      addTearDown(s.close);
      backend = ScriptedBackend([
        (_) => callSearch('water', id: 'c2'),
        (_) => say('Boil it [3]. Earlier advice [1].'),
      ]);
      final search = BatchSearch([[hit('Water', 'Boil it.'), hit('Burn', 'Cool it, again.')]]);
      chat = make(s, backend, search);
      expect(chat.messages, isEmpty);
      chat.openConversation(id);
      expect([for (final m in chat.messages) m.isUser], [true, false]);
      expect(chat.messages.last.text, 'Cool it [1], get help [2]. Bogus.');
      expect([for (final r in chat.messages.last.sources) r.id], [1, 2]);
      expect(chat.messages.last.sources.first.result.address, 'zim:Burn');

      await chat.send('And dirty water?');
      await chat.whenIdle();
      // The model got the earlier transcript exactly as it saw it, then the new question.
      final sent = (backend.requests.first['messages'] as List).skip(1).toList();
      expect(sent.take(4), s.transcript(id).take(4));
      expect(sent[4], {'role': 'user', 'content': 'And dirty water?'});
      // The new tool message continues the numbering: Burn keeps [1], Water is [3].
      final toolMsg = (backend.requests[1]['messages'] as List).last as Map;
      expect(toolMsg['content'], '[3] Water — Boil it.\n[1] Burn — Cool it, again.');
      expect(chat.messages.last.text, 'Boil it [3]. Earlier advice [1].');
      expect([for (final r in chat.messages.last.sources) r.id], [1, 3]);
      expect(s.list().length, 1);
      expect(s.get(id)!.title, 'Treating burns'); // not asked again
      expect(backend.titleRequests, isEmpty);

      // A second restart still numbers on from [3].
      final blob = await const MemoryNumberingState().restore(s.numbering(id)!);
      expect([for (final i in await blob!.ids()) i.n], [1, 2, 3]);
    });

    test('a title the user typed is never replaced and a new chat starts empty', () async {
      final s = ConversationStore.memory(now: () => clock);
      addTearDown(s.close);
      final chat = make(s, ScriptedBackend([(_) => say('Hi.')]), BatchSearch([[]]));
      await chat.send('hello there');
      final id = chat.activeId!;
      await chat.renameConversation(id, 'Mine');
      await chat.whenIdle();
      expect(s.get(id)!.title, 'Mine');
      chat.newChat();
      expect(chat.messages, isEmpty);
      expect(chat.activeId, isNull);
      await chat.send('second chat');
      await chat.whenIdle();
      expect(s.list().length, 2);
    });

    test('a question stops a title that is being written', () async {
      final s = ConversationStore.memory(now: () => clock);
      addTearDown(s.close);
      final backend = ScriptedBackend([(_) => say('Hi.')]);
      final chat = make(s, backend, BatchSearch([[]]));
      await chat.send('hello there');
      await chat.send('and again'); // started while the title may still be running
      await chat.whenIdle();
      expect(chat.messages.length, 4);
      expect(s.messages(chat.activeId!).where((m) => m.role == 'user').length, 2);
    });

    test('delete can be undone; delete all empties the list', () async {
      final s = ConversationStore.memory(now: () => clock);
      addTearDown(s.close);
      final chat = make(s, ScriptedBackend([(_) => say('Hi.')]), BatchSearch([[]]));
      await chat.send('hello there');
      await chat.whenIdle();
      final id = chat.activeId!;
      chat.deleteConversation(id);
      expect(chat.activeId, isNull);
      expect(s.list(), isEmpty);
      chat.undoDelete(id);
      expect(s.list().length, 1);
      chat.deleteAllConversations();
      expect(s.list(), isEmpty);
    });

    test('a failed answer is stored and shown again as an error', () async {
      final s = ConversationStore.memory(now: () => clock);
      addTearDown(s.close);
      final chat = make(s, ScriptedBackend([(_) => throw StateError('model crashed')]), BatchSearch([[]]));
      await chat.send('hello there');
      final id = chat.activeId!;
      expect(chat.messages.last.error, isNotNull);
      chat.newChat();
      chat.openConversation(id);
      expect(chat.messages.last.error, isNotNull);
      expect(chat.messages.length, 2);
    });
  });
}

void say1Via(ConversationStore s, int id) {
  s.addMessage(id, role: 'user', content: 'How to cool a burn?', message: {'role': 'user', 'content': 'How to cool a burn?'});
  s.addMessage(id, role: 'assistant', content: 'Cool it [1].', message: {'role': 'assistant', 'content': 'Cool it [1].'});
}

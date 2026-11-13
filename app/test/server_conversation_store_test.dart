import 'dart:async';

import 'package:cache/history/conversation_store.dart';
import 'package:cache/history/server_conversation_store.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException, CoreTransport;
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the helper's `history.*` ops (server/helper/bin/history_ops.dart), shared by the "tabs" of a test.
class FakeServer implements CoreTransport {
  final Map<int, Map<String, dynamic>> convs = {};
  final List<int> gone = [];
  final List<String> calls = [];
  int rev = 0;
  bool down = false;

  /// An error to throw for an op (by name) instead of doing it, and the `since` of the last sync.
  final Map<String, Object> fails = {};
  int lastSince = -1;

  @override
  Future<void> close() async {}

  @override
  Future<dynamic> call(String op, Map<String, dynamic> a) async {
    if (down) throw const CacheSearchException('internal', 'unreachable');
    calls.add(op);
    final f = fails[op];
    if (f != null) throw f;
    if (op == 'history.sync') lastSince = a['since'] as int;
    Map<String, dynamic> save(Map<String, dynamic> c) {
      c['rev'] = ++rev;
      return c;
    }

    switch (op) {
      case 'history.sync':
        final since = a['since'] as int;
        return {
          'rev': rev,
          'conversations': [for (final c in convs.values) if ((c['rev'] as int) > since) c],
          'gone': gone,
        };
      case 'history.create':
        final c = Map<String, dynamic>.from(a['conversation'] as Map);
        convs.putIfAbsent(c['id'] as int, () => save({...c, 'deleted': false, 'numbering': null, 'messages': <Map<String, dynamic>>[]}));
        return null;
      case 'history.update':
        final c = convs[a['id']];
        if (c == null) return false;
        c.addAll((a['fields'] as Map).cast<String, dynamic>());
        save(c);
        return true;
      case 'history.addMessage':
        final c = convs[a['id']];
        if (c == null) return false;
        (c['messages'] as List).add(Map<String, dynamic>.from(a['message'] as Map));
        c['updated'] = a['updated'];
        if (a['model'] != null) c['model'] = a['model'];
        save(c);
        return true;
      case 'history.purge':
        final c = convs[a['id']];
        if (c == null || c['deleted'] != true) return false;
        convs.remove(a['id']);
        gone.add(a['id'] as int);
        rev++;
        return true;
      default:
        return null;
    }
  }
}

Future<ServerConversationStore> tab(FakeServer s, {void Function()? onChanged, List<String>? log}) =>
    ServerConversationStore.open(s, poll: null, onChanged: onChanged, log: log?.add ?? (_) {}, retryDelay: const Duration(milliseconds: 5));

Future<void> say(ServerConversationStore st, int id, String q) async {
  st.addMessage(id, role: 'user', content: q, message: {'role': 'user', 'content': q});
}

void main() {
  test('a conversation is kept on the server and a second tab lists and reopens it', () async {
    final server = FakeServer();
    final a = await tab(server);
    final c = a.create(title: 'How do I treat a burn?', model: 'Gemma');
    await say(a, c.id, 'burn?');
    a.addMessage(c.id,
        role: 'assistant',
        content: 'Cool it.',
        message: {'role': 'assistant', 'content': 'Cool it.'},
        citations: const [StoredCitation(n: 1, title: 'Burns', snippet: 's', address: 'zim:x/Burns')],
        stats: const GenerationStats(promptTokens: 9, generatedTokens: 4, durationMs: 700));
    await a.flush();

    final b = await tab(server);
    expect(b.list().single.title, 'How do I treat a burn?');
    final m = b.messages(c.id);
    expect(m.map((x) => x.content), ['burn?', 'Cool it.']);
    expect(m[1].citations.single.address, 'zim:x/Burns');
    expect(m[1].stats.generatedTokens, 4);
    expect(b.transcript(c.id).length, 2);
    expect(b.search('burn').single.conversation.id, c.id);
  });

  test('rename, pin, delete and undo in one tab reach another on its next refresh, which tells the page', () async {
    final server = FakeServer();
    final a = await tab(server);
    var told = 0;
    final b = await tab(server, onChanged: () => told++);
    final c = a.create(title: 'Q', voice: true);
    await a.flush();
    await b.refresh();
    expect(b.get(c.id)!.voice, isTrue);
    expect(told, 1);

    a.rename(c.id, 'Mine');
    a.setPinned(c.id, true);
    await a.flush();
    await b.refresh();
    expect(b.get(c.id)!.title, 'Mine');
    expect(b.get(c.id)!.titleSource, TitleSource.user);
    expect(b.get(c.id)!.pinned, isTrue);
    expect(told, 2);

    a.delete(c.id);
    await a.flush();
    await b.refresh();
    expect(b.list(), isEmpty);
    a.undelete(c.id);
    await a.flush();
    await b.refresh();
    expect(b.list().single.id, c.id);

    await b.refresh();
    expect(told, 4, reason: 'a refresh that finds nothing new tells nobody');

    a.delete(c.id);
    a.purge(c.id);
    await a.flush();
    await b.refresh();
    expect(b.get(c.id), isNull);
    expect(b.list(), isEmpty);
  });

  test('a tab does not hear its own writes back as news', () async {
    final server = FakeServer();
    var told = 0;
    final a = await tab(server, onChanged: () => told++);
    final c = a.create(title: 'Q');
    await say(a, c.id, 'one');
    await a.flush();
    await a.refresh();
    expect(told, 0);
    expect(a.messages(c.id).length, 1);
  });

  test('writes wait in order while the server is down and go when it is back; a refresh meanwhile keeps them', () async {
    final server = FakeServer();
    final a = await tab(server);
    server.down = true;
    final c = a.create(title: 'Q');
    await say(a, c.id, 'one');
    a.rename(c.id, 'Named');
    await a.flush();
    expect(server.convs, isEmpty);
    expect(a.get(c.id)!.title, 'Named');
    server.down = false;
    await a.flush();
    expect(server.calls.where((o) => o != 'history.sync'), ['history.create', 'history.addMessage', 'history.update']);
    await a.refresh();
    expect(a.messages(c.id).single.content, 'one');
    expect(a.get(c.id)!.title, 'Named');
  });

  test('ids made in the same moment do not repeat', () async {
    final server = FakeServer();
    final a = await ServerConversationStore.open(server, poll: null, now: () => DateTime.fromMillisecondsSinceEpoch(5000000));
    final b = await ServerConversationStore.open(server, poll: null, now: () => DateTime.fromMillisecondsSinceEpoch(6000000));
    final ids = {for (var i = 0; i < 50; i++) ...[a.create(title: 'a$i').id, b.create(title: 'b$i').id]};
    expect(ids.length, 100);
  });

  test('the first sync failing is an error unless the caller keeps the store', () async {
    final server = FakeServer()..down = true;
    expect(() => tab(server), throwsA(isA<CacheSearchException>()));
  });

  /// Waits until [ok] holds, with a deadline: what a test expects to have happened is waited for, not given a fixed time (a loaded
  /// machine can overrun one).
  Future<void> until(bool Function() ok, {Duration within = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(within);
    while (!ok() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a write the server refuses (io_error) is dropped with a log, and the writes behind it still go', () async {
    final server = FakeServer();
    final log = <String>[];
    final a = await tab(server, log: log);
    final c = a.create(title: 'T');
    await a.flush();
    server.fails['history.update'] = const CacheSearchException('io_error', 'History could not be saved: disk full');
    a.rename(c.id, 'New');
    await a.flush();
    server.fails.clear();
    await say(a, c.id, 'still saved');
    await a.flush();
    expect(log.where((l) => l.contains('history.update was dropped') && l.contains('io_error')), hasLength(1));
    expect((server.convs[c.id]!['messages'] as List), hasLength(1), reason: 'the queue went on');
  });

  test('a write that keeps failing inside the server (internal) while it answers is dropped after a few tries, with a log', () async {
    final server = FakeServer();
    final log = <String>[];
    final a = await tab(server, log: log);
    final c = a.create(title: 'T');
    await a.flush();
    server.fails['history.update'] = const CacheSearchException('internal', 'type error in the helper');
    a.rename(c.id, 'New');
    await say(a, c.id, 'behind it');
    await until(() => log.any((l) => l.contains('history.update was dropped')));
    expect(log.where((l) => l.contains('history.update was dropped')), hasLength(1));
    expect(server.calls.where((x) => x == 'history.update').length, ServerConversationStore.maxInternalRetries);
    server.fails.clear();
    await a.flush();
    expect((server.convs[c.id]!['messages'] as List), hasLength(1), reason: 'the write behind it was not blocked');
  });

  test('internal while the server cannot be reached is kept and retried, never dropped', () async {
    final server = FakeServer();
    final log = <String>[];
    final a = await tab(server, log: log);
    final c = a.create(title: 'T');
    await a.flush();
    server.down = true;
    await say(a, c.id, 'later');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(log.any((l) => l.contains('was dropped')), isFalse);
    server.down = false;
    await until(() => (server.convs[c.id]!['messages'] as List).isNotEmpty);
    expect((server.convs[c.id]!['messages'] as List), hasLength(1));
  });

  test('an error in the poll is caught: no uncaught async error while the server is away', () async {
    final server = FakeServer();
    final log = <String>[];
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final a = await ServerConversationStore.open(server, poll: const Duration(milliseconds: 10), log: log.add);
      server.down = true;
      await until(() => log.any((l) => l.contains('could not look for changes')));
      a.close();
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
    expect(log.any((l) => l.contains('could not look for changes')), isTrue);
  });

  test('one malformed row is logged and skipped, the rest are taken in, and the position still moves on', () async {
    final server = FakeServer();
    final a0 = await tab(server);
    final good = a0.create(title: 'Good');
    await a0.flush();
    server.convs[7] = {'id': 7, 'rev': ++server.rev, 'title': 5, 'titleSource': 'user', 'created': 1, 'updated': 1, 'messages': <Object>[]};
    server.convs[8] = {'id': 8, 'rev': ++server.rev, 'title': 'ok', 'created': 1, 'updated': 2, 'messages': [{'id': 1, 'role': 'user', 'message': 'not a map'}]};
    server.convs[9] = {'id': 9, 'rev': ++server.rev, 'title': 'After', 'created': 1, 'updated': 3, 'messages': <Object>[]};
    final log = <String>[];
    final b = await tab(server, log: log);
    expect({for (final c in b.list()) c.title}, {'Good', 'After'});
    expect(log.where((l) => l.contains('skipped a conversation')), hasLength(2));
    expect(good.id, isNonZero);
    await b.refresh();
    expect(server.lastSince, server.rev, reason: 'since advanced past the bad rows');
    expect(log.where((l) => l.contains('skipped a conversation')), hasLength(2), reason: 'not downloaded and failed again');
  });

  test('the first sync is tried again with a wait; a server that comes up in time gives the history', () async {
    final server = FakeServer();
    final seed = await tab(server);
    seed.create(title: 'Kept');
    await seed.flush();
    server.down = true;
    Timer(const Duration(milliseconds: 30), () => server.down = false);
    final log = <String>[];
    final a = await ServerConversationStore.open(server, poll: null, attempts: 4, backoff: const Duration(milliseconds: 25), log: log.add);
    expect([for (final c in a.list()) c.title], ['Kept']);
    expect(log.any((l) => l.contains('the first sync failed')), isTrue);
  });

  test('if the first sync never works it is logged, the session keeps its chats, and a later sync attaches the server', () async {
    final server = FakeServer();
    final seed = await tab(server);
    seed.create(title: 'On the server');
    await seed.flush();
    server.down = true;
    final log = <String>[];
    final a = await ServerConversationStore.open(server,
        poll: const Duration(milliseconds: 20), attempts: 2, backoff: const Duration(milliseconds: 5), keepOnFailure: true, log: log.add, retryDelay: const Duration(milliseconds: 10));
    expect(log.any((l) => l.contains('this session keeps its chats')), isTrue);
    final mine = a.create(title: 'Written offline');
    await say(a, mine.id, 'hello');
    server.down = false;
    await until(() =>
        server.convs[mine.id]?['title'] == 'Written offline' &&
        (server.convs[mine.id]!['messages'] as List).length == 1 &&
        a.list().length == 2);
    expect(server.convs[mine.id]!['title'], 'Written offline', reason: 'the session was not lost');
    expect((server.convs[mine.id]!['messages'] as List), hasLength(1));
    expect({for (final c in a.list()) c.title}, {'On the server', 'Written offline'}, reason: 'the server history came in too');
    a.close();
  });
}

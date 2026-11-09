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

  @override
  Future<void> close() async {}

  @override
  Future<dynamic> call(String op, Map<String, dynamic> a) async {
    if (down) throw const CacheSearchException('internal', 'unreachable');
    calls.add(op);
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

Future<ServerConversationStore> tab(FakeServer s, {void Function()? onChanged}) =>
    ServerConversationStore.open(s, poll: null, onChanged: onChanged);

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

  test('the first sync failing is an error, so the page can fall back to memory', () async {
    final server = FakeServer()..down = true;
    expect(() => tab(server), throwsA(isA<CacheSearchException>()));
  });
}

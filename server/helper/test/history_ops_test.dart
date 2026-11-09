import 'dart:io';

import 'package:test/test.dart';

import '../bin/history_ops.dart';

void main() {
  late Directory tmp;
  late HistoryOps h;
  var clock = DateTime.fromMillisecondsSinceEpoch(1000000);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('history_ops_test');
    clock = DateTime.fromMillisecondsSinceEpoch(1000000);
    h = HistoryOps(Directory('${tmp.path}/history'), now: () => clock);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> sync(HistoryOps o, [int since = 0]) => (o.handle('history.sync', {'since': since}) as Map).cast<String, dynamic>();
  Map<String, dynamic> msg(int id, {bool inTranscript = true}) => {
        'id': id, 'role': 'user', 'content': 'q$id', 'message': {'role': 'user', 'content': 'q$id'}, 'citations': [], 'error': null,
        'created': 5, 'promptTokens': 0, 'generatedTokens': 0, 'durationMs': 0, 'inTranscript': inTranscript, 'navigationActions': [],
      };
  void create(int id, [String title = 'T']) => h.handle('history.create', {'conversation': {'id': id, 'title': title, 'created': 10, 'updated': 10}});

  test('create, add messages, rename, and a second helper over the same folder sees it all', () {
    create(1, 'How?');
    create(1, 'ignored: the id exists');
    expect(h.handle('history.addMessage', {'id': 1, 'message': msg(7), 'updated': 20, 'model': 'M'}), isTrue);
    expect(h.handle('history.addMessage', {'id': 1, 'message': msg(7), 'updated': 30}), isFalse, reason: 'repeat is a no-op');
    h.handle('history.update', {'id': 1, 'fields': {'title': 'Mine', 'titleSource': 'user', 'pinned': true, 'numbering': 'AQI=', 'evil': 1}});
    final c = (sync(HistoryOps(Directory('${tmp.path}/history')))['conversations'] as List).single as Map;
    expect(c['title'], 'Mine');
    expect(c['titleSource'], 'user');
    expect(c['pinned'], true);
    expect(c['model'], 'M');
    expect(c['updated'], 20);
    expect(c['numbering'], 'AQI=');
    expect(c.containsKey('evil'), isFalse);
    expect((c['messages'] as List).single['content'], 'q7');
  });

  test('sync sends only what changed since a rev, and purges are reported as gone', () {
    create(1);
    create(2);
    final first = sync(h);
    final rev = first['rev'] as int;
    h.handle('history.update', {'id': 2, 'fields': {'title': 'B'}});
    var s = sync(h, rev);
    expect([for (final c in s['conversations'] as List) (c as Map)['id']], [2]);
    h.handle('history.update', {'id': 1, 'fields': {'deleted': true}});
    expect(h.handle('history.purge', {'id': 2}), isFalse, reason: 'only a deleted one');
    expect(h.handle('history.purge', {'id': 1}), isTrue);
    s = sync(h, rev);
    expect(s['gone'], [1]);
    expect(sync(HistoryOps(Directory('${tmp.path}/history')))['gone'], [1], reason: 'tombstones survive a restart');
    expect(File('${tmp.path}/history/c1.json').existsSync(), isFalse);
  });

  test('purgeDeleted spares a conversation deleted a moment ago; deleteAll clears', () {
    create(1);
    create(2);
    h.handle('history.update', {'id': 1, 'fields': {'deleted': true}});
    expect(h.handle('history.purgeDeleted', {'olderThanMs': 60000}), 0);
    clock = clock.add(const Duration(minutes: 2));
    expect(h.handle('history.purgeDeleted', {'olderThanMs': 60000}), 1);
    expect(h.handle('history.deleteAll', {}), 1);
    expect(sync(h)['conversations'], isEmpty);
  });

  test('navigation actions and action drafts', () {
    create(1);
    h.handle('history.addMessage', {'id': 1, 'message': msg(1, inTranscript: false)});
    h.handle('history.addMessage', {'id': 1, 'message': msg(2)});
    expect(h.handle('history.setNavigationActions', {'id': 1, 'messageId': 1, 'actions': [{'address': 'nav:x'}]}), isTrue);
    expect(h.handle('history.removeMessage', {'id': 1, 'messageId': 2}), isFalse, reason: 'the model saw it');
    expect(h.handle('history.removeMessage', {'id': 1, 'messageId': 1}), isTrue);
    expect((((sync(h)['conversations'] as List).single as Map)['messages'] as List).single['id'], 2);
  });
}

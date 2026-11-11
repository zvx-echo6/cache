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

  group('a damaged store', () {
    late Directory hdir;
    late List<String> logs;
    setUp(() {
      hdir = Directory('${tmp.path}/history')..createSync(recursive: true);
      logs = [];
    });
    HistoryOps open() => HistoryOps(hdir, now: () => clock, log: logs.add);

    test('a file with no numeric rev, and a tombstone without one, are logged and skipped; the helper starts', () {
      File('${hdir.path}/c5.json').writeAsStringSync('{"id":5,"title":"no rev","messages":[]}');
      File('${hdir.path}/c6.json').writeAsStringSync('{"id":6,"rev":"x","messages":[]}');
      File('${hdir.path}/c7.json').writeAsStringSync('{"id":7,"rev":4,"title":"ok","messages":[]}');
      File('${hdir.path}/tombstones.json').writeAsStringSync('[{"id":9},{"id":8,"rev":6}]');
      final o = open();
      final s = sync(o);
      expect([for (final c in s['conversations'] as List) (c as Map)['id']], [7]);
      expect(s['gone'], [8]);
      expect(s['rev'], 6);
      expect(logs.where((l) => l.contains('c5.json')), hasLength(1));
      expect(logs.where((l) => l.contains('c6.json')), hasLength(1));
      expect(logs.where((l) => l.contains('tombstone')), hasLength(1));
    });

    test('a purged conversation whose file could not be deleted is deleted at the next start', () {
      final o = open();
      o.handle('history.create', {'conversation': {'id': 1, 'title': 'T'}});
      o.handle('history.update', {'id': 1, 'fields': {'deleted': true}});
      final file = File('${hdir.path}/c1.json');
      final copy = file.readAsStringSync();
      expect(o.handle('history.purge', {'id': 1}), isTrue);
      file.writeAsStringSync(copy); // as if the delete had failed
      final again = open();
      expect(file.existsSync(), isFalse, reason: 'the tombstone says it is purged');
      expect(sync(again)['conversations'], isEmpty);
      expect(sync(again)['gone'], [1]);
      expect(logs.any((l) => l.contains('purged')), isTrue);
    });

    test('a failed delete in a purge is logged', () {
      final o = HistoryOps(hdir, now: () => clock, log: logs.add, deleteFile: (f) => throw const FileSystemException('locked'));
      o.handle('history.create', {'conversation': {'id': 2, 'title': 'T'}});
      o.handle('history.update', {'id': 2, 'fields': {'deleted': true}});
      expect(o.handle('history.purge', {'id': 2}), isTrue);
      expect(logs.any((l) => l.contains('cannot delete c2.json')), isTrue);
    });
  });

  test('history.update and history.addMessage refuse fields of the wrong type with bad_args, and store nothing', () {
    create(1);
    String code(void Function() f) {
      try {
        f();
      } on Exception catch (e) {
        return (e as dynamic).code as String;
      }
      return 'none';
    }

    for (final f in [
      {'title': 5}, {'updated': 'x'}, {'deleted': 'yes'}, {'pinned': 1}, {'model': []}, {'numbering': 3}, {'titleSource': {}},
    ]) {
      expect(code(() => h.handle('history.update', {'id': 1, 'fields': f})), 'bad_args', reason: '$f');
    }
    expect(code(() => h.handle('history.update', {'id': 1, 'fields': {'title': 'ok', 'pinned': 'x'}})), 'bad_args');
    expect(((sync(h)['conversations'] as List).single as Map)['title'], 'T', reason: 'a refused update changes nothing');
    final bad = [
      {...msg(1), 'role': 3}, {...msg(2), 'content': null}, {...msg(3), 'message': 'x'}, {...msg(4), 'citations': 'x'},
      {...msg(5), 'created': 'x'}, {...msg(6), 'inTranscript': 'x'}, {...msg(7), 'navigationActions': {}},
    ];
    for (final m in bad) {
      expect(code(() => h.handle('history.addMessage', {'id': 1, 'message': m})), 'bad_args', reason: '$m');
    }
    expect(((sync(h)['conversations'] as List).single as Map)['messages'], isEmpty);
    expect(h.handle('history.addMessage', {'id': 1, 'message': msg(8)}), isTrue);
  });
}

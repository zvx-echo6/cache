import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import '../bin/indexes_sync.dart';
import '../bin/sharing_host.dart';
import '../bin/video_ops.dart';
import 'fake_native.dart';
import 'sharing_host_test.dart' show FakeCore, FakeDisk;

/// The server keeps the `indexes` share's fetch list (setOnly) and never-fetch list (setNeverFetch) in step with the core, as the
/// phone's `_syncIndexesOnly` does, and after a sync changed the share it gives the core its sources again and kicks the driver
/// (main.dart `_syncIndexesOnly` and the indexes branch of `sharing.onShareChanged`).
class _Fake extends FakeNative {
  final Map<String, String?> videoReplies = {};
  @override
  String? video(int handle, String op, String requestJson) => videoReplies[op];
}

String _status(List<Map<String, Object?>> sources, [List<Map<String, Object?>> rejected = const []]) =>
    jsonEncode({'sources': sources, 'rejected_snapshots': rejected});

Map<String, Object?> _src(String kind, String path, String? sourceId) => {'id': sourceId == null ? null : 'x', 'kind': kind, 'path': path, 'source_id': sourceId};

void main() {
  late Directory tmp, data, support, docs;
  late FakeDisk disk;
  late List<FakeCore> opened;
  late SharingHost host;
  late _Fake fake;
  late CoreDispatcher d;
  var saved = <Map<String, dynamic>>[];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('indexes_sync_test');
    data = Directory('${tmp.path}/data')..createSync();
    support = Directory('${data.path}/app/support')..createSync(recursive: true);
    docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
    disk = FakeDisk();
    opened = [];
    saved = [];
    host = SharingHost(
      dataDir: data,
      supportDir: support,
      docsDir: docs,
      pollEvery: const Duration(milliseconds: 20),
      opener: (cfg) async {
        final c = FakeCore(disk, cfg);
        opened.add(c);
        return c;
      },
    );
    await host.setUp();
    fake = _Fake()..statusFn = () => _status([]);
    d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': <Object>[], 'extra': null});
  });
  tearDown(() async {
    await host.stop();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> only() => opened.single.argsOf('set_only');
  // the engine is also told never to fetch the server's own Bookshelves log: only the indexes share's calls are looked at here
  List<Map<String, Object?>> never() => [for (final a in opened.single.argsOf('set_never_fetch')) if (a['id'] == 'indexes') a];

  test('the fetch list is the regions indexes, the open sources\' index folders and the saved videos\' captions; the never-fetch list the rejected snapshots', () async {
    fake.statusFn = () => _status([
          _src('zim', '/docs/zims/a.zim', 'zim-a'),
          _src('library', '/docs/libraries/L/shard', 'lib-1'),
          _src('zim', '/docs/zims/broken.zim', null),
        ], [
          {'kind': 'zim', 'source_id': 'zim-a', 'build_id': 'b1', 'path': 'zim/zim-a/snap/b1'},
          {'kind': 'library', 'source_id': 'lib/1', 'build_id': 'b2'},
        ]);
    saved = [
      {'instance': 'peer.example', 'uuid': 'u1', 'captions_index': {'source_id': 'peer.example/u1', 'needs_build': false}},
      {'instance': 'peer.example', 'uuid': 'u2'},
    ];
    await IndexesSync(host: host, dispatcher: d, savedVideos: () => saved).update();
    expect(only().single, {
      'id': 'indexes',
      'only': [
        'captions/peer.example%2Fu1',
        'captions/peer.example%2Fu2',
        'library/lib-1',
        'places-index',
        'region-index',
        'zim-captions/zim-a',
        'zim-epub/zim-a',
        'zim-pdf/zim-a',
        'zim/zim-a',
      ],
    });
    expect(never().single, {
      'id': 'indexes',
      'never_fetch': ['library/lib%2F1/snap/b2', 'zim/zim-a/snap/b1'],
    });
  });

  test('a change in the core\'s sources, the rejected snapshots or the saved videos is sent again, and no change sends nothing', () async {
    final sync = IndexesSync(host: host, dispatcher: d, savedVideos: () => saved);
    await sync.update();
    expect(only().single['only'], ['places-index', 'region-index']);
    await sync.update();
    expect(only(), hasLength(1), reason: 'nothing changed: the engine is not told again');
    expect(never(), isEmpty, reason: 'an empty never-fetch list is what the engine already has');
    fake.statusFn = () => _status([_src('zim', '/z.zim', 'z1')], [
          {'kind': 'zim', 'source_id': 'z1', 'build_id': 'b'}
        ]);
    await sync.update();
    expect(only().last['only'], contains('zim/z1'));
    expect(never().last['never_fetch'], ['zim/z1/snap/b']);
    saved = [
      {'instance': 'h', 'uuid': 'v'},
    ];
    await sync.update();
    expect(only().last['only'], contains('captions/h%2Fv'));
    saved = [];
    await sync.update();
    expect(only().last['only'], isNot(contains('captions/h%2Fv')), reason: 'a removed video leaves the list');
  });

  test('a core that is not open yet, or a video folder that cannot be read, does not stop the update', () async {
    final closed = CoreDispatcher(() => _Fake()..statusFn = () => throw StateError('closed'));
    await IndexesSync(host: host, dispatcher: closed).update();
    expect(only(), isEmpty);
    await IndexesSync(host: host, dispatcher: d, savedVideos: () => throw StateError('no video folder')).update();
    expect(only().single['only'], ['places-index', 'region-index']);
  });

  test('the list is kept for the next open when sharing is not running yet', () async {
    await host.stop();
    final again = SharingHost(dataDir: data, supportDir: support, docsDir: docs, pollEvery: const Duration(milliseconds: 20), opener: (cfg) async {
      final c = FakeCore(disk, cfg);
      opened.add(c);
      return c;
    });
    addTearDown(again.stop);
    fake.statusFn = () => _status([_src('zim', '/z.zim', 'z1')]);
    await IndexesSync(host: again, dispatcher: d).update();
    await again.init();
    expect((opened.last.config['only'] as Map)['indexes'], contains('zim/z1'));
  });

  group('when it is sent again', () {
    late Directory appSupport, appDocs;
    late AppDirs dirs;
    var updates = 0;

    setUp(() {
      appSupport = Directory('${tmp.path}/s')..createSync();
      appDocs = Directory('${tmp.path}/d')..createSync();
      dirs = AppDirs(appSupport, appDocs);
      updates = 0;
    });

    test('after every sources.rescan, once', () {
      final rescan = RescanOp(dirs, d, onRescanned: () => updates++);
      rescan.handle('sources.rescan', {'sources': <Object>[]});
      expect(updates, 1);
      rescan.handle('sources.rescan', {'sources': null});
      expect(updates, 2);
    });

    test('after the core opens', () {
      var opens = 0;
      final op = OpenOp(dirs, d, onOpened: () => opens++);
      op.handle('open', {'sources': <Object>[]});
      expect(opens, 1);
    });

    test('when a video is removed (delete, and removing an instance with its downloads) but not for a read', () {
      final v = _Fake();
      final ops = VideoOps(dirs, () => v, onRemoved: () => updates++);
      v.videoReplies['delete'] = '{}';
      v.videoReplies['instance_remove'] = '{}';
      v.videoReplies['instances'] = '{"instances":[]}';
      ops.handle('video.call', {'op': 'instances', 'request': ''});
      expect(updates, 0);
      ops.handle('video.call', {'op': 'delete', 'request': '{"instance":"a","video":"u"}'});
      expect(updates, 1);
      ops.handle('video.call', {'op': 'instance_remove', 'request': '{"instance":"a","delete_downloads":true}'});
      expect(updates, 2);
    });
  });

  group('after a sync changes the indexes share', () {
    test('the core is given its sources again the way sources.rescan does, and the driver is kicked, once per change', () {
      final tmpDirs = AppDirs(Directory('${tmp.path}/s2')..createSync(), Directory('${tmp.path}/d2')..createSync());
      final given = GivenSources();
      final rescan = RescanOp(tmpDirs, d, given: given);
      var kicks = 0;
      final react = IndexesShareReaction(
        refreshSources: () => rescan.handle('sources.rescan', {'sources': given.value}),
        kick: () => kicks++,
      );
      final before = fake.calls.where((c) => c.startsWith('setSources:')).length;
      react({'indexes'});
      expect(fake.calls.where((c) => c.startsWith('setSources:')).length, before + 1);
      expect(kicks, 1);
      react({'indexes', 'libraries'});
      expect(kicks, 2);
      expect(fake.calls.where((c) => c.startsWith('setSources:')).length, before + 2);
    });

    test('another share changing does nothing', () {
      var refreshes = 0, kicks = 0;
      final react = IndexesShareReaction(refreshSources: () => refreshes++, kick: () => kicks++);
      react({'libraries', 'maps', 'settings'});
      expect((refreshes, kicks), (0, 0));
    });

    test('the sources the server gave are the ones given again; with none given the folders are scanned', () {
      final given = GivenSources();
      final dirs = AppDirs(Directory('${tmp.path}/s3')..createSync(), Directory('${tmp.path}/d3')..createSync());
      OpenOp(dirs, d, given: given).handle('open', {
        'sources': [
          {'kind': 'zim', 'path': '/given.zim', 'index_dir': '/i'}
        ]
      });
      expect(given.value, isA<List>());
      final rescan = RescanOp(dirs, d, given: given);
      fake.calls.clear();
      rescan.handle('sources.rescan', {'sources': given.value});
      expect(fake.calls.single, contains('/given.zim'));
      rescan.handle('sources.rescan', {'sources': null});
      expect(given.value, isNull, reason: 'the server\'s last word wins');
    });

    test('a failing refresh is logged and the driver is still kicked', () {
      var kicks = 0;
      final logs = <String>[];
      IndexesShareReaction(refreshSources: () => throw StateError('core closed'), kick: () => kicks++, log: logs.add)({'indexes'});
      expect(kicks, 1);
      expect(logs.single, contains('core closed'));
    });
  });
}

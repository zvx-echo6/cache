import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../bin/line_protocol.dart';
import '../bin/sharing_host.dart';
import 'fake_native.dart';

/// What the engine keeps between opens (its sync.json): the shares.
class FakeDisk {
  final List<Map<String, dynamic>> shares = [];
}

/// A stand-in for the sync engine: records every call and the config it was opened with, keeps shares in [disk].
class FakeCore implements SyncCoreLike {
  FakeCore(this.disk, this.config);

  final FakeDisk disk;
  final Map<String, Object?> config;
  final List<(String, Map<String, Object?>)> calls = [];
  bool closed = false;

  /// While set, `link` waits for it (then answers with [linkResult] or throws [linkError]).
  Completer<void>? linkGate;
  Object? linkError;
  List<Map<String, dynamic>> peers = [];

  List<String> names(String m) => [for (final c in calls) if (c.$1 == m) c.$1];
  List<Map<String, Object?>> argsOf(String m) => [for (final c in calls) if (c.$1 == m) c.$2];

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    if (closed) throw const CacheSearchException('sync', 'Sharing is stopped');
    calls.add((method, args));
    switch (method) {
      case 'status':
        return {'id': 'me', 'name': 'Fake', 'peers': peers, 'shares': [for (final s in disk.shares) ({...s})], 'offers': <Object>[]};
      case 'share_add':
        disk.shares.add({'id': args['id'], 'name': args['name'], 'path': args['path'], 'files': 0, 'bytes': 0, 'pending_files': 0});
        return {'ok': true, 'id': args['id']};
      case 'share_remove':
        disk.shares.removeWhere((s) => s['id'] == args['id']);
        return {'ok': true};
      case 'link':
        final g = linkGate;
        if (g != null) await g.future;
        if (linkError != null) throw linkError!;
        return {'ok': true, 'peer': 'peer-1', 'name': 'Phone'};
      case 'link_code':
        return {'code': 'CACHE1-abc', 'valid_secs': 900};
      case 'take_secrets':
        return {
          'secrets': {
            'peer-1': {'k': 'v'},
          },
        };
      default:
        return {'ok': true};
    }
  }

  @override
  Future<void> close() async => closed = true;
}

Future<void> until(bool Function() ok, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tmp;
  late Directory data, support, docs;
  late FakeDisk disk;
  late List<FakeCore> opened;
  late List<SharingHost> hosts;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sharing_host_test');
    data = Directory('${tmp.path}/data')..createSync();
    support = Directory('${data.path}/app/support')..createSync(recursive: true);
    docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
    disk = FakeDisk();
    opened = [];
    hosts = [];
  });
  tearDown(() async {
    for (final h in hosts) {
      await h.stop();
    }
    tmp.deleteSync(recursive: true);
  });

  SharingHost host({Duration poll = const Duration(milliseconds: 20), Future<SyncCoreLike> Function(Map<String, Object?>)? opener}) {
    final h = SharingHost(
      dataDir: data,
      supportDir: support,
      docsDir: docs,
      deviceName: 'Test box',
      pollEvery: poll,
      opener: opener ??
          (cfg) async {
            final c = FakeCore(disk, cfg);
            opened.add(c);
            return c;
          },
    );
    hosts.add(h);
    return h;
  }

  Map<String, dynamic> flag() => jsonDecode(File('${data.path}/sharing.json').readAsStringSync()) as Map<String, dynamic>;

  test('the share table maps the phone\'s share ids onto the server folders', () {
    final t = host().table;
    final d = data.path, s = support.path, o = docs.path;
    expect({for (final k in t.kinds) k.id: k.shares}, {
      'library': {'library': '$o/zims', 'libraries': '$o/libraries'},
      'regions': {'maps': '$s/layers', 'regions': '$s/regions'},
      'models': {'models': '$d/models'},
      'notebooks': {'notebooks': '$s/notebook-share'},
      'videos': {'videos': '$o/videos'},
    });
    expect(t.always.single.id, 'indexes');
    expect(t.always.single.dir.path, '$s/shared-indexes');
    expect({for (final l in t.links) l.id: l.dir.path}, {'settings': '$s/settings-sync', 'bookshelves': '$d/bookshelves'});
    expect({for (final l in t.links) l.id: l.modes}, {
      'settings': ['match', 'send'],
      'bookshelves': ['match'],
    });
    final ex = {for (final k in t.kinds) ...k.notShared};
    // the same lists the phone's Library kind gives its engine (app/lib/main.dart dataKinds): a server that synced what phones never
    // do would send those files, and their deletes, to every linked device
    expect(ex['libraries'], ['*/index', '*/index-snapshots']);
    expect(ex['library'], ['*.illustration.png']);
    expect(ex['maps'], contains('tiles.sqlite*'));
    expect(ex['regions'], contains('places/index'));
    expect(ex['models'], contains('*.part'));
  });

  test('nothing starts until sharing is set up, and the state says so', () async {
    final h = host();
    await h.init();
    expect(opened, isEmpty);
    expect(File('${data.path}/sharing.json').existsSync(), isFalse);
    final s = h.snapshot();
    expect(s['enabled'], false);
    expect(s['running'], false);
    expect(s['status'], isEmpty);
    expect(await h.invoke('sharing.state', {}), s);
  });

  test('set up opens the engine on <data>/sync with the phone\'s config, adds the always and link shares, and saves sharing.json', () async {
    final h = host();
    await h.invoke('sharing.setup', {});
    final c = opened.single;
    final cfg = c.config;
    expect(cfg['dir'], '${data.path}/sync');
    expect(cfg['name'], 'Test box');
    // the network settings are the engine's defaults, as on the phone: none of them is given
    for (final k in ['relay', 'relay_urls', 'dht', 'mdns', 'lookup', 'lookup_url', 'port', 'interval_secs', 'reserve_bytes']) {
      expect(cfg.containsKey(k), isFalse, reason: k);
    }
    expect((cfg['exclude'] as Map)['libraries'], ['*/index', '*/index-snapshots']);
    expect((cfg['exclude'] as Map)['library'], ['*.illustration.png']);
    expect((cfg['exclude'] as Map)['indexes'], contains('.local'));
    expect(cfg['only'], {'indexes': <String>[]});
    expect(cfg['local_deletes'], {'indexes': ['*/*/snap']});
    expect(cfg['last'], {'indexes': ['*/*/snap/*/manifest.json']});
    expect((cfg['hidden'] as Map)['indexes'], contains('*/*/snap/*/.managed.json'));
    expect(cfg['with'], {'settings': ['match', 'send'], 'bookshelves': ['match']});
    expect(cfg['never_fetch'], <String, Object?>{});
    expect(cfg['off'], {'library': <String>[], 'libraries': <String>[], 'maps': <String>[], 'regions': <String>[], 'models': <String>[], 'notebooks': <String>[], 'videos': <String>[]});
    expect(c.argsOf('set_policy'), [
      {'network': true},
    ]);
    expect({for (final a in c.argsOf('share_add')) a['id']: a['path']}, {
      'indexes': '${support.path}/shared-indexes',
      'settings': '${support.path}/settings-sync',
      'bookshelves': '${data.path}/bookshelves',
    });
    for (final p in ['${support.path}/shared-indexes', '${support.path}/settings-sync', '${data.path}/bookshelves']) {
      expect(Directory(p).existsSync(), isTrue, reason: p);
    }
    final f = flag();
    expect(f['enabled'], true);
    expect(f['ask_since'], isA<int>());
    expect(f.containsKey('off'), isFalse);
    expect(h.snapshot()['running'], true);
  });

  test('a kind on adds its folders as shares named as on the phone; off removes the shares and keeps the files', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    await h.invoke('sharing.set_kind', {'kind': 'regions', 'on': true});
    expect({for (final a in c.argsOf('share_add')) a['id']: a['name']}, containsPair('maps', 'Regions (maps)'));
    expect({for (final a in c.argsOf('share_add')) a['id']: a['path']}, containsPair('regions', '${support.path}/regions'));
    await h.invoke('sharing.set_kind', {'kind': 'models', 'on': true});
    expect({for (final a in c.argsOf('share_add')) a['id']: a['name']}, containsPair('models', 'Models'));
    File('${data.path}/models/a.gguf')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    await h.invoke('sharing.set_kind', {'kind': 'models', 'on': false});
    expect(c.argsOf('share_remove'), [
      {'id': 'models'},
    ]);
    expect(File('${data.path}/models/a.gguf').existsSync(), isTrue);
    await expectLater(h.invoke('sharing.set_kind', {'kind': 'nonsense', 'on': true}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_args')));
  });

  test('items switched off go to the engine as the share\'s off list, are kept in sharing.json, and are given again at every open', () async {
    final h = host();
    await h.setUp();
    await h.setKind('library', true);
    await h.invoke('sharing.set_item', {'kind': 'library', 'key': 'library/big.zim', 'on': false});
    expect(opened.single.argsOf('set_off').last, {'id': 'library', 'off': ['big.zim']});
    expect(flag()['off'], {'library': ['library/big.zim']});
    // a second item, then the first one back on
    await h.setItem('library', 'libraries/mine', false);
    expect(opened.single.argsOf('set_off').last, {'id': 'libraries', 'off': ['mine']});
    await h.setItem('library', 'library/big.zim', true);
    expect(opened.single.argsOf('set_off').last, {'id': 'library', 'off': <String>[]});
    expect(flag()['off'], {'library': ['libraries/mine']});
    // one item on in a kind that is off shares the kind with that item alone
    await h.setKind('library', false);
    await h.setItem('library', 'library/a.zim', true, all: ['library/a.zim', 'library/b.zim', 'libraries/mine']);
    expect(opened.single.argsOf('set_off').last, {'id': 'library', 'off': ['b.zim']});
    expect(flag()['off'], {'library': ['libraries/mine', 'library/b.zim']});
    expect(h.kindOn(h.table.kinds.first), isTrue);
    await h.setKind('library', false);
    await expectLater(h.setItem('library', 'library/a.zim', true), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_args')));
  });

  test('a restart starts sharing again by itself and gives the config again; shares kept by the engine are not added twice', () async {
    final h1 = host();
    await h1.setUp();
    await h1.setKind('models', true);
    await h1.setItem('models', 'models/x.gguf', false);
    await h1.stop();
    expect(opened.single.closed, isTrue);
    // the next helper: nothing asked, sharing.json says enabled
    final h2 = host();
    await h2.init();
    expect(opened, hasLength(2));
    final c = opened.last;
    expect(h2.snapshot()['running'], true);
    expect(c.config['dir'], '${data.path}/sync');
    expect((c.config['off'] as Map)['models'], ['x.gguf']);
    expect((c.config['with'] as Map).keys, containsAll(['settings', 'bookshelves']));
    expect((c.config['only'] as Map)['indexes'], <String>[]);
    expect(c.names('share_add'), isEmpty, reason: 'the engine kept its shares: ${disk.shares.map((s) => s['id'])}');
    expect(disk.shares.map((s) => s['id']), containsAll(['indexes', 'settings', 'bookshelves', 'models']));
    expect(h2.snapshot()['off'], {'models': ['models/x.gguf']});
  });

  test('sharing.json that was never set up or says disabled starts nothing; one without ask_since gets it', () async {
    File('${data.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': false}));
    final h = host();
    await h.init();
    expect(opened, isEmpty);
    expect(flag()['ask_since'], isA<int>());
    expect(flag()['enabled'], false);
  });

  test('the status is polled into a cache: the state costs no engine call, however many tabs ask', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    await until(() => c.names('status').length >= 4);
    expect(((h.snapshot()['status'] as Map)['name']), 'Fake');
    final before = c.names('status').length;
    // a burst of tabs asking at one moment
    for (var i = 0; i < 50; i++) {
      await h.invoke('sharing.state', {});
    }
    expect(c.names('status').length - before, lessThan(4), reason: 'the burst made no engine calls of its own');
    // and `status` through sharing.call is the cache too
    final n = c.names('status').length;
    final s = await h.invoke('sharing.call', {'method': 'status', 'args': {}}) as Map;
    expect(s['name'], 'Fake');
    expect(c.names('status').length - n, lessThan(4));
  });

  test('the production poll is every 2 s', () {
    expect(SharingHost(dataDir: data, supportDir: support, docsDir: docs).pollEvery, const Duration(seconds: 2));
  });

  test('a browser cannot reach the keys, nor anything the host owns; the allowed methods pass through', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    for (final m in ['set_secrets', 'take_secrets', 'link', 'share_add', 'share_join', 'share_remove', 'set_off', 'set_only', 'set_never_fetch', 'set_share_with', 'set_policy', 'network_changed', 'nope']) {
      await expectLater(
        h.invoke('sharing.call', {'method': m, 'args': {'peer': 'p', 'secrets': {'k': 'v'}, 'path': '/etc'}}),
        throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'forbidden')),
        reason: m,
      );
    }
    final names = c.calls.map((x) => x.$1).toSet();
    expect(names.intersection({'set_secrets', 'take_secrets', 'link', 'share_join', 'set_share_with', 'network_changed', 'nope'}), isEmpty);
    // only the host's own start-up share_add calls happened, none with the browser's path
    expect(c.argsOf('share_add').every((a) => a['path'] != '/etc'), isTrue);
    expect(await h.invoke('sharing.call', {'method': 'link_code', 'args': {}}), containsPair('code', 'CACHE1-abc'));
    for (final m in ['unlink', 'set_name', 'set_peer_name', 'set_link', 'sync_now', 'share_items']) {
      await h.invoke('sharing.call', {'method': m, 'args': {'x': 1}});
      expect(c.argsOf(m).last, {'x': 1}, reason: m);
    }
    // the error codes reach the browser as the line protocol's error
    final out = await handleLine(jsonEncode({'id': 1, 'op': 'sharing.call', 'args': {'method': 'take_secrets', 'args': {}}}), CoreDispatcher(() => FakeNative()), handlers: [SharingOps(h)]);
    expect((jsonDecode(out) as Map)['error'], containsPair('code', 'forbidden'));
  });

  test('the host does the keys itself, from inside, and a trusted call may use any method', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    await h.setSecrets('peer-1', {'openai': 'sk-x'});
    expect(c.argsOf('set_secrets').single, {'peer': 'peer-1', 'secrets': {'openai': 'sk-x'}});
    expect(await h.takeSecrets(), {
      'peer-1': {'k': 'v'},
    });
    await h.invoke('sharing.call', {'method': 'take_secrets', 'args': {}}, trusted: true);
    expect(c.names('take_secrets'), hasLength(2));
    await h.setOnly('indexes', ['zim/a/**', 'zim/a/**']);
    expect(c.argsOf('set_only').single['id'], 'indexes');
  });

  test('before sharing is set up the engine ops say so', () async {
    final h = host();
    await expectLater(h.invoke('sharing.call', {'method': 'link_code', 'args': {}}), throwsA(isA<CacheSearchException>().having((e) => e.message, 'message', contains('not set up'))));
    await expectLater(h.invoke('sharing.link_start', {'code': 'x'}), throwsA(isA<CacheSearchException>()));
    await expectLater(h.invoke('sharing.bogus', {}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'unsupported')));
    await expectLater(h.invoke('sharing.link_start', {}), throwsA(isA<CacheSearchException>()));
  });

  test('link_start returns at once; the snapshot carries linking, then done with the peer and its name', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    c.linkGate = Completer<void>();
    final first = await h.invoke('sharing.link_start', {'code': 'CACHE1-zzz'}) as Map;
    expect(first, {'state': 'linking'});
    expect((h.snapshot()['link'] as Map)['state'], 'linking');
    // the helper is not stuck behind the long call: other ops answer meanwhile
    expect((await h.invoke('sharing.state', {}) as Map)['running'], true);
    await expectLater(h.invoke('sharing.link_start', {'code': 'again'}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'busy')));
    expect(c.argsOf('link').single, {'code': 'CACHE1-zzz'});
    c.linkGate!.complete();
    await until(() => (h.snapshot()['link'] as Map)['state'] == 'done');
    expect(h.snapshot()['link'], {'state': 'done', 'peer': 'peer-1', 'name': 'Phone'});
    // and a refused link says why
    c
      ..linkGate = null
      ..linkError = const CacheSearchException('sync', 'the other device did not answer');
    await h.invoke('sharing.link_start', {'code': 'CACHE1-yyy'});
    await until(() => (h.snapshot()['link'] as Map)['state'] == 'failed');
    expect(h.snapshot()['link'], {'state': 'failed', 'error': 'the other device did not answer'});
  });

  test('a share that settles with other contents is reported once nothing is pending', () async {
    final h = host();
    final seen = <Set<String>>[];
    h.onShareChanged = seen.add;
    await h.setUp();
    await h.setKind('models', true);
    final c = opened.single;
    await until(() => c.names('status').length >= 3);
    final m = disk.shares.firstWhere((s) => s['id'] == 'models');
    m
      ..['files'] = 2
      ..['bytes'] = 10
      ..['pending_files'] = 1;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(seen, isEmpty, reason: 'mid-sync is not a change');
    m['pending_files'] = 0;
    await until(() => seen.isNotEmpty);
    expect(seen.first, {'models'});
    expect((h.snapshot()['changed'] as Map)['models'], 1);
    final n = seen.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(seen, hasLength(n), reason: 'one change is reported once');
  });

  test('a start that fails says why, leaves nothing half open, and set up again retries', () async {
    var fail = true;
    final h = host(
      opener: (cfg) async {
        if (fail) throw const CacheSearchException('internal', 'no port');
        final c = FakeCore(disk, cfg);
        opened.add(c);
        return c;
      },
    );
    await h.setUp();
    var s = h.snapshot();
    expect((s['enabled'], s['running'], s['error']), (true, false, 'Sharing could not start: no port'));
    fail = false;
    await h.setUp();
    s = h.snapshot();
    expect((s['running'], s['error']), (true, null));
  });

  test('stopping closes the engine and ends the polling; the shares stay set', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    await until(() => c.names('status').length >= 2);
    await h.stop();
    expect(c.closed, isTrue);
    final n = c.names('status').length;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.names('status').length, n);
    expect(disk.shares, isNotEmpty);
    expect(h.snapshot()['running'], false);
  });

  test('the host stops when the helper\'s input ends', () async {
    final h = host();
    await h.setUp();
    final c = opened.single;
    final out = <String>[];
    await serveLines(
      Stream.value(utf8.encode('${jsonEncode({'id': 1, 'op': 'sharing.state', 'args': {}})}\n${jsonEncode({'id': 2, 'op': 'sharing.link_code'})}\n')),
      out.add,
      CoreDispatcher(() => FakeNative()),
      handlers: [SharingOps(h)],
      onEnd: h.stop,
    );
    expect(jsonDecode(out[1]), containsPair('ok', true));
    expect(jsonDecode(out[2]), containsPair('ok', false));
    expect(c.closed, isTrue);
  });
}

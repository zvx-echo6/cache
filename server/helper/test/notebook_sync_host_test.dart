// Notebook sync on the server (L4 slice 6b): the helper keeps the notebooks in the core and `<support>/notebook-share` the same with
// no browser open, through the phone's engine over a CoreNotebookStore. A phone is simulated by the same engine over its own notebooks
// and the same folder. The sharing host runs on a fake engine, so what it tells the engine (off lists, photo gate, history) is read
// from the calls.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../../app/lib/notebook/notebook_model.dart';
import '../../../app/lib/notebook/sync/folder.dart';
import '../../../app/lib/notebook/sync/sync_engine_core.dart';
import '../../../app/lib/notebook/templates_model.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../bin/core_notebook_store.dart';
import '../bin/notebook_sync_host.dart';
import '../bin/sharing_host.dart';
import 'sharing_host_test.dart' show FakeCore, FakeDisk, until;

/// The core's notebook ops in memory (cache_notebook): enough of them for the engine, with a rev that goes up at every save.
class FakeNotebookCore {
  final Map<String, Map<String, dynamic>> books = {};
  final Map<String, Map<String, dynamic>> entries = {};
  final List<String> ops = [];
  int _n = 0;

  Map<String, dynamic> call(String op, Map<String, dynamic> a) {
    ops.add(op);
    switch (op) {
      case 'notebooks':
        return {'notebooks': books.values.toList()};
      case 'notebook':
        return books[a['id']] ?? (throw const CacheSearchException('not_found', 'no such notebook'));
      case 'notebook_save':
        final id = (a['id'] as String?) ?? 'nb${++_n}';
        final old = books[id];
        return books[id] = {
          'id': id,
          'template': a['template'] ?? old?['template'] ?? 'notes',
          'def': a['def'],
          'private': a['private'] ?? old?['private'] ?? false,
          'map': a['map'] ?? old?['map'] ?? true,
          'template_ref': a['template_ref'] ?? old?['template_ref'],
        };
      case 'entries':
        return {'entries': [for (final e in entries.values) if (e['notebook_id'] == a['notebook_id']) e]};
      case 'entry':
        return entries[a['id']] ?? (throw const CacheSearchException('not_found', 'no such entry'));
      case 'entry_save':
        final id = (a['id'] as String?) ?? 'e${++_n}';
        return entries[id] = {
          'id': id,
          'notebook_id': a['notebook_id'],
          'occurred_at': a['occurred_at'],
          'title': a['title'],
          'body': a['body'],
          'values': a['values'] ?? {},
          'place': a['place'],
          'photos': a['photos'] ?? [],
          'files': a['files'] ?? [],
          'draft': a['draft'] == true,
          'private': a['private'] == true,
          'rev': ((entries[id]?['rev'] as int?) ?? 0) + 1,
          'props': a['props'] ?? {},
        };
      case 'entry_delete':
        entries.remove(a['id']);
        return {'ok': true};
    }
    throw CacheSearchException('unsupported', 'unknown notebook op $op');
  }
}

NotebookDef _def(String name) => NotebookDef(name: name, fields: const [], sort: NotebookSort.recent);

/// One device's notebooks: a fake core behind the store the engine uses, with a media folder of its own.
class Device {
  Device(Directory root, {String name = 'dev'})
      : core = FakeNotebookCore(),
        media = Directory('${root.path}/$name-media')..createSync(recursive: true),
        state = File('${root.path}/$name-state.json') {
    store = CoreNotebookStore(call: core.call, mediaDir: media);
  }

  final FakeNotebookCore core;
  final Directory media;
  final File state;
  late final CoreNotebookStore store;

  Future<Notebook> book(String name, {bool private = false}) => store.saveNotebook(template: 'notes', def: _def(name), private: private);

  Future<NbEntry> entry(Notebook b, String title, {List<String> photos = const [], bool draft = false, bool private = false, String? body}) => store.saveEntry(
        notebookId: b.id,
        occurredAt: '2026-11-17T09:00:00-07:00',
        title: title,
        body: body,
        photos: [for (final p in photos) NbPhoto(id: p)],
        draft: draft,
        private: private,
      );

  void photo(String id, List<int> bytes) {
    File('${media.path}/photos/$id.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  /// This device runs the notebook sync with [share] (as the phone does): everything but the private notebooks.
  Future<SyncReport> run(Directory share, {Set<String> include = const {}}) => NotebookSyncCore(
        notebook: store,
        kind: SyncKind.share,
        folder: IoFolder(share.path),
        stateFile: state,
        includePrivate: false,
        privateBooks: include,
        templates: () async => const Templates([], []),
      ).run();
}

void main() {
  late Directory tmp, data, support, docs;
  late FakeDisk disk;
  late List<FakeCore> opened;
  late List<SharingHost> hosts;
  late List<NotebookSyncHost> nbs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('notebook_sync_host_test');
    data = Directory('${tmp.path}/data')..createSync();
    support = Directory('${data.path}/app/support')..createSync(recursive: true);
    docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
    disk = FakeDisk();
    opened = [];
    hosts = [];
    nbs = [];
  });
  tearDown(() async {
    for (final n in nbs) {
      n.stop();
    }
    for (final h in hosts) {
      await h.stop();
    }
    tmp.deleteSync(recursive: true);
  });

  Directory shareDir() => Directory('${support.path}/notebook-share');

  /// The server: its sharing host on a fake engine and its notebook sync, wired as the helper does.
  ({SharingHost sharing, NotebookSyncHost nb, Device server}) rig({bool shareOnAlways = false, Device? server}) {
    final dev = server ?? Device(tmp, name: 'server');
    final h = SharingHost(
      dataDir: data,
      supportDir: support,
      docsDir: docs,
      deviceName: 'Test box',
      pollEvery: const Duration(milliseconds: 20),
      opener: (cfg) async {
        final c = FakeCore(disk, cfg);
        opened.add(c);
        return c;
      },
    );
    hosts.add(h);
    final nb = NotebookSyncHost(
      support: support,
      store: dev.store,
      shareOn: () => shareOnAlways || (h.running && h.shareOf('notebooks') != null),
      prepareShare: h.refreshGate,
      offChanged: h.refreshOff,
      debounce: const Duration(milliseconds: 30),
      every: const Duration(hours: 1),
    );
    nbs.add(nb);
    attachNotebookSync(h, nb);
    h.onShareChanged = (ids) => nb.shareChanged(ids);
    return (sharing: h, nb: nb, server: dev);
  }

  List<String> files(Directory d) => d.existsSync()
      ? [for (final f in d.listSync(recursive: true).whereType<File>()) f.path.substring(d.path.length + 1)].where((p) => !p.startsWith('.') && !p.contains('/.')).toList()
      : [];

  Map<String, dynamic> flag() => jsonDecode(File('${data.path}/sharing.json').readAsStringSync()) as Map<String, dynamic>;

  group('the core as the engine\'s NotebookStore', () {
    test('reads and writes through the core\'s ops; an existing notebook keeps its fields; a missing one is null', () async {
      final d = Device(tmp);
      final b = await d.book('Camp notes');
      expect(d.store.notebooks.map((n) => n.name), ['Camp notes'], reason: 'the list is read again after a write');
      expect(d.store.nameTaken(' camp  NOTES '), isTrue);
      expect(d.store.nameTaken('camp notes', exceptId: b.id), isFalse);
      final e = await d.entry(b, 'Water', body: 'six jugs');
      expect((await d.store.entry(e.id))?.title, 'Water');
      expect((await d.store.entries(b.id)).single.body, 'six jugs');
      expect(await d.store.entry('nope'), isNull);
      expect(d.core.ops, contains('entries'));
      await d.store.deleteEntry(e.id);
      expect(await d.store.entries(b.id), isEmpty);
      // a rename keeps the notebook (and, in the real core, its fields: the definition given has none)
      final renamed = await d.store.saveNotebook(id: b.id, def: _def('Camp'));
      expect(renamed.id, b.id);
      expect(d.store.journal, isNull);
    });

    test('a photo that came from a folder is stored where the browser\'s viewer reads it, with a thumbnail; copyPhoto gives a photo its own files', () async {
      final d = Device(tmp);
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await d.store.storePhoto('aaaa', bytes);
      expect(File('${d.media.path}/photos/aaaa.jpg').readAsBytesSync(), bytes, reason: 'notebook/photos/<id>.jpg under the support folder');
      expect(File('${d.media.path}/thumbs/aaaa.jpg').existsSync(), isTrue);
      expect(await d.store.photoBytes('aaaa'), bytes);
      expect(await d.store.photoBytes('zzzz'), isNull);
      expect(await d.store.copyPhoto('aaaa', 'bbbb'), isTrue);
      expect(File('${d.media.path}/photos/bbbb.jpg').readAsBytesSync(), bytes);
      expect(File('${d.media.path}/thumbs/bbbb.jpg').existsSync(), isTrue);
      expect(await d.store.copyPhoto('missing', 'cccc'), isFalse);
    });
  });

  group('the passes', () {
    test('one pass at start: the notebooks go out to <support>/notebook-share and what is there comes in, with no browser', () async {
      final r = rig(shareOnAlways: true);
      final book = await r.server.book('Journal');
      await r.server.entry(book, 'From the server');
      // a phone's notebook is already in the share folder
      final phone = Device(tmp, name: 'phone');
      final trail = await phone.book('Trail log');
      await phone.entry(trail, 'From the phone');
      expect((await phone.run(shareDir())).written, 1);

      await r.nb.start();
      expect(files(shareDir()).where((p) => p.endsWith('.md')), hasLength(2), reason: 'the server\'s entry went out beside the phone\'s');
      expect(r.server.store.notebooks.map((n) => n.name).toSet(), {'Journal', 'Trail log'});
      final got = r.server.store.notebooks.firstWhere((n) => n.name == 'Trail log');
      expect((await r.server.store.entries(got.id)).single.title, 'From the phone');
      expect(r.nb.last!.arrived, 1);
      // and the phone takes the server's entry on its next pass
      await phone.run(shareDir());
      final theirs = phone.store.notebooks.firstWhere((n) => n.name == 'Journal');
      expect((await phone.store.entries(theirs.id)).single.title, 'From the server');
    });

    test('nothing runs while the kind is off, and the folder is left alone', () async {
      final r = rig();
      final book = await r.server.book('Journal');
      await r.server.entry(book, 'Not yet');
      await r.nb.start();
      expect(r.nb.passes, 0);
      expect(files(shareDir()), isEmpty);
      expect(r.server.core.ops, isNot(contains('entries')), reason: 'the notebooks are not even read');
    });

    test('a share that settled with other contents for notebooks imports; another share does not', () async {
      final r = rig(shareOnAlways: true);
      final phone = Device(tmp, name: 'phone');
      final b = await phone.book('Trail log');
      await phone.entry(b, 'Arrived');
      await phone.run(shareDir());
      await r.nb.shareChanged({'models', 'library'});
      expect(r.nb.passes, 0);
      expect(r.server.store.notebooks, isEmpty);
      await r.nb.shareChanged({'notebooks'});
      expect(r.nb.passes, 1);
      expect(r.server.store.notebooks.single.name, 'Trail log');
    });

    test('a share change the engine reports reaches the host through the sharing host', () async {
      final r = rig();
      await r.sharing.setUp();
      await r.sharing.setKind('notebooks', true);
      await until(() => r.nb.passes >= 1);
      final phone = Device(tmp, name: 'phone');
      final b = await phone.book('Trail log');
      await phone.entry(b, 'Arrived');
      await phone.run(shareDir());
      final before = r.nb.passes;
      final n = disk.shares.firstWhere((s) => s['id'] == 'notebooks');
      n
        ..['files'] = 3
        ..['bytes'] = 99;
      await until(() => r.nb.passes > before && r.server.store.notebooks.isNotEmpty);
      expect(r.server.store.notebooks.single.name, 'Trail log');
    });

    test('a write to the core\'s notebooks (a browser\'s) exports after a moment, several writes one pass; a read does nothing', () async {
      final r = rig(shareOnAlways: true);
      final hook = NotebookWriteHook(r.nb.changed);
      hook.after('notebook', {'op': 'notebooks', 'args': {}});
      hook.after('notebook', {'op': 'entries', 'args': {}});
      hook.after('search', {'query': 'x'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(r.nb.passes, 0, reason: 'reads and other ops are no change');

      final book = await r.server.book('Journal');
      await r.server.entry(book, 'Typed in a browser');
      hook.after('notebook', {'op': 'notebook_save', 'args': {}});
      hook.after('notebook', {'op': 'entry_save', 'args': {}});
      hook.after('notebook', {'op': 'entry_save', 'args': {}});
      await until(() => r.nb.passes == 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(r.nb.passes, 1);
      expect(files(shareDir()).where((p) => p.endsWith('.md')), hasLength(1));
    });

    test('an incoming photo is stored where the browser reads it (notebook/photos/<id>.jpg), and shows on the entry', () async {
      final r = rig(shareOnAlways: true);
      final phone = Device(tmp, name: 'phone');
      final b = await phone.book('Trail log');
      phone.photo('pppp', [9, 8, 7]);
      await phone.entry(b, 'With a photo', photos: ['pppp']);
      await phone.run(shareDir());
      expect(File('${shareDir().path}/photos/cache-pppp.jpg').readAsBytesSync(), [9, 8, 7]);

      await r.nb.run();
      expect(File('${r.server.media.path}/photos/pppp.jpg').readAsBytesSync(), [9, 8, 7]);
      expect(File('${r.server.media.path}/thumbs/pppp.jpg').existsSync(), isTrue);
      final got = r.server.store.notebooks.single;
      expect((await r.server.store.entries(got.id)).single.photos.map((p) => p.id), ['pppp']);
    });

    test('a photo added on the server goes out with its entry', () async {
      final r = rig(shareOnAlways: true);
      final b = await r.server.book('Journal');
      r.server.photo('qqqq', [5, 5]);
      await r.server.entry(b, 'Pic', photos: ['qqqq']);
      await r.nb.run();
      expect(File('${shareDir().path}/photos/cache-qqqq.jpg').readAsBytesSync(), [5, 5]);
    });

    test('an edit on the phone and an edit on the server travel both ways with the phone\'s merge rules', () async {
      final r = rig(shareOnAlways: true);
      final phone = Device(tmp, name: 'phone');
      final b = await phone.book('Trail log');
      final e = await phone.entry(b, 'Water', body: 'one\n\ntwo');
      await phone.run(shareDir());
      await r.nb.run();
      final mine = r.server.store.notebooks.single;
      final theirEntry = (await r.server.store.entries(mine.id)).single;
      // the server edits the first paragraph, the phone the second
      await r.server.store.saveEntry(id: theirEntry.id, notebookId: mine.id, occurredAt: theirEntry.occurredAt, title: 'Water', body: 'ONE\n\ntwo');
      await phone.store.saveEntry(id: e.id, notebookId: b.id, occurredAt: e.occurredAt, title: 'Water', body: 'one\n\nTWO');
      await phone.run(shareDir());
      await r.nb.run();
      await phone.run(shareDir());
      expect((await r.server.store.entries(mine.id)).single.body, 'ONE\n\nTWO');
      expect((await phone.store.entries(b.id)).single.body, 'ONE\n\nTWO');
    });

    test('a pass that fails is logged and the next trigger tries again', () async {
      final r = rig(shareOnAlways: true);
      final logged = <String>[];
      final broken = NotebookSyncHost(
        support: support,
        store: CoreNotebookStore(call: (op, args) => throw const CacheSearchException('not_configured', 'The search core is not available'), mediaDir: Directory('${tmp.path}/m')),
        shareOn: () => true,
        every: const Duration(hours: 1),
        log: logged.add,
      );
      nbs.add(broken);
      await broken.run();
      expect(logged.any((l) => l.contains('not available')), isTrue);
      expect(r.nb.passes, 0);
    });
  });

  group('the three sharing rules, on the server', () {
    test('photos leave only for shared entries: the engine\'s gate lists the photos an entry that goes out refers to', () async {
      final r = rig();
      final camp = await r.server.book('Camp notes');
      final off = await r.server.book('Quokka Log');
      final health = await r.server.book('Health', private: true);
      await r.server.entry(camp, 'shared', photos: ['aaaa']);
      await r.server.entry(off, 'in a notebook switched off', photos: ['bbbb']);
      await r.server.entry(camp, 'a draft', photos: ['cccc'], draft: true);
      await r.server.entry(camp, 'a private entry', photos: ['dddd'], private: true);
      await r.server.entry(health, 'in a private notebook', photos: ['eeee'], private: true);
      await r.sharing.setUp();
      await r.nb.start();
      final c = opened.single;
      Map<String, Object?> gate() => (c.argsOf('set_gate').isEmpty ? (c.config['gate'] as Map)['notebooks'] : c.argsOf('set_gate').last) as Map<String, Object?>;

      // switched off before the kind is on (the off list is given first, so the first round already leaves it out)
      await r.sharing.setKind('notebooks', true);
      await r.sharing.setItem('notebooks', 'notebooks/Quokka Log', false);
      await r.sharing.refreshGate();
      expect(gate()['dir'], 'photos');
      expect(gate()['allow'], ['photos/cache-aaaa.jpg'], reason: 'not the switched-off notebook\'s, a draft\'s, a private entry\'s, or a private notebook\'s');

      // the notebook switched on: its photo may go; the private notebook included: its photo may go
      await r.sharing.setItem('notebooks', 'notebooks/Quokka Log', true);
      expect(gate()['allow'], ['photos/cache-aaaa.jpg', 'photos/cache-bbbb.jpg']);
      await r.nb.setIncluded(health.id, true);
      expect(gate()['allow'], ['photos/cache-aaaa.jpg', 'photos/cache-bbbb.jpg', 'photos/cache-eeee.jpg']);
      // and the other way
      await r.sharing.setItem('notebooks', 'notebooks/Quokka Log', false);
      expect(gate()['allow'], ['photos/cache-aaaa.jpg', 'photos/cache-eeee.jpg']);
    });

    test('a gated share the host has no photo list for sends nothing from the folder, and the gate is in the engine\'s config from its start', () async {
      Map<String, Object?>? cfg;
      final h = SharingHost(dataDir: data, supportDir: support, docsDir: docs, pollEvery: const Duration(milliseconds: 20), opener: (c) async {
        cfg = c;
        return FakeCore(disk, c);
      });
      hosts.add(h);
      await h.setUp();
      expect(cfg!['gate'], {'notebooks': {'dir': 'photos', 'allow': <String>[]}});
    });

    test('per-item switches are kept through turning the kind off and on: a notebook switched off stays off, and a private notebook stays included', () async {
      final r = rig();
      final camp = await r.server.book('Camp notes');
      await r.server.book('Quokka Log');
      final health = await r.server.book('Health', private: true);
      await r.server.entry(camp, 'x');
      await r.sharing.setUp();
      await r.nb.start();
      await r.sharing.setKind('notebooks', true);
      await r.sharing.setItem('notebooks', 'notebooks/Quokka Log', false);
      await r.nb.setIncluded(health.id, true);
      final c = opened.single;
      expect(c.argsOf('set_off').last, {'id': 'notebooks', 'off': ['Quokka Log']});

      await r.sharing.setKind('notebooks', false);
      await r.sharing.setKind('notebooks', true);
      expect(c.argsOf('set_off').last, {'id': 'notebooks', 'off': ['Quokka Log']}, reason: 'the engine is not told anything else: the list stands');
      expect(flag()['off'], {'notebooks': ['notebooks/Quokka Log']});
      expect(r.nb.included(health.id), isTrue);
      expect(r.nb.privateOff(), isEmpty);
      expect(jsonDecode(File('${support.path}/notebook-sync/targets.json').readAsStringSync())['private_included'], [health.id]);

      // a restart (a new host over the same folders) reads both again
      final again = rig(server: r.server);
      await again.nb.start();
      expect(again.nb.included(health.id), isTrue);
      await again.sharing.init();
      expect(opened.last.config['off'], containsPair('notebooks', ['Quokka Log']));
    });

    test('turning the kind off keeps history: the engine is told to keep it, the folder and the sync record stay, nothing syncs while off, and on again carries on', () async {
      final r = rig();
      final b = await r.server.book('Journal');
      await r.server.entry(b, 'Before');
      await r.sharing.setUp();
      await r.nb.start();
      await r.sharing.setKind('notebooks', true);
      await until(() => files(shareDir()).any((p) => p.endsWith('.md')));
      final c = opened.single;
      final record = File('${support.path}/notebook-sync/share.json');
      expect(record.existsSync(), isTrue);
      final recorded = record.readAsStringSync();

      await r.sharing.setKind('notebooks', false);
      expect(c.argsOf('share_remove').last, {'id': 'notebooks', 'keep_history': true});
      expect(files(shareDir()).where((p) => p.endsWith('.md')), hasLength(1), reason: 'the files stay');
      expect(record.readAsStringSync(), recorded, reason: 'the engine\'s record of what both sides had stays: that is the history');

      // an entry added while the kind is off is not written out
      await r.server.entry(b, 'While off');
      NotebookWriteHook(r.nb.changed).after('notebook', {'op': 'entry_save', 'args': {}});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(files(shareDir()).where((p) => p.endsWith('.md')), hasLength(1));

      // on again: it goes out (the kind being switched on is a trigger)
      await r.sharing.setKind('notebooks', true);
      await until(() => files(shareDir()).where((p) => p.endsWith('.md')).length == 2);
    });

    test('a private notebook stays out of the share until its switch is on, and the switch survives a restart', () async {
      final r = rig(shareOnAlways: true);
      final health = await r.server.book('Health', private: true);
      await r.server.entry(health, 'Blood pressure', private: true);
      final notes = await r.server.book('Notes');
      await r.server.entry(notes, 'Public');
      await r.nb.run();
      expect(files(shareDir()).where((p) => p.endsWith('.md')), hasLength(1), reason: 'only Notes went out');
      expect(files(shareDir()).any((p) => p.startsWith('Health')), isFalse);
      expect(r.nb.privateOff(), ['Health']);

      await r.nb.setIncluded(health.id, true);
      await until(() => files(shareDir()).where((p) => p.endsWith('.md')).length == 2);
      expect(r.nb.privateOff(), isEmpty);
      await r.nb.setIncluded(health.id, false);
      expect(r.nb.privateOff(), ['Health']);
      expect(r.nb.includedIds, isEmpty);
    });

    test('a browser reaches the switch through sharing.set_private, and the state says which are on', () async {
      final r = rig(shareOnAlways: true);
      final health = await r.server.book('Health', private: true);
      await r.sharing.setUp();
      expect(r.sharing.snapshot()['private_included'], <String>[]);
      final snap = await r.sharing.invoke('sharing.set_private', {'notebook': health.id, 'on': true}) as Map;
      expect(snap['private_included'], [health.id]);
      expect(r.nb.included(health.id), isTrue);
      await expectLater(r.sharing.invoke('sharing.set_private', {'notebook': health.id}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_args')));
      await expectLater(r.sharing.invoke('sharing.set_private', {'on': true}), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_args')));
    });
  });

  test('the built-in templates are read from the web build\'s folder, once; without it there are none', () async {
    final load = serverTemplates('../../app/assets/notebook');
    final t = await load();
    expect(t.byId('journal'), isNotNull);
    expect(t.starters, isNotEmpty);
    expect(identical(await load(), t), isTrue, reason: 'read once');
    expect((await serverTemplates(null)()).notebooks, isEmpty);
    expect((await serverTemplates('${tmp.path}/nothing')()).notebooks, isEmpty);
  });
}

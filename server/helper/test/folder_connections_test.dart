// Obsidian and Logseq folders chosen on this computer (L4 notes-folder sync): the helper keeps the notebooks in the core and the chosen
// folder the same with no browser open, through the phone's engine over a CoreNotebookStore, both ways, with the phone's merge rules.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../app/lib/notebook/notebook_model.dart';
import '../../../app/lib/notebook/sync/sync_engine_core.dart' show SyncKind;
import '../../../packages/cache_search/lib/src/errors.dart';
import '../bin/folder_connections.dart';
import 'notebook_sync_host_test.dart' show Device;

void main() {
  late Directory tmp, support, vault, graph;
  late Device dev;
  final fixed = DateTime(2026, 11, 23, 17, 2);
  final made = <FolderConnections>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('folder_connections_test');
    support = Directory('${tmp.path}/support')..createSync();
    vault = Directory('${tmp.path}/Vault')..createSync();
    graph = Directory('${tmp.path}/Graph/logseq')..createSync(recursive: true);
    File('${graph.path}/config.edn').writeAsStringSync('{:preferred-format "Markdown"}');
    graph = graph.parent;
    dev = Device(tmp, name: 'server');
    made.clear();
  });
  tearDown(() {
    for (final c in made) {
      c.stop();
    }
    tmp.deleteSync(recursive: true);
  });

  FolderConnections make({Directory? at, void Function()? onChanged, Duration debounce = const Duration(milliseconds: 30), List<String>? log}) {
    final c = FolderConnections(
      support: at ?? support,
      store: dev.store,
      clock: () => fixed,
      debounce: debounce,
      every: const Duration(hours: 1),
      changedNotebooks: onChanged,
      log: log?.add,
    );
    made.add(c);
    return c;
  }

  /// The one Markdown file of the Journal notebook in the folder (its name has the date and the title).
  File noteOf(Directory d, String title) => d.listSync(recursive: true).whereType<File>().singleWhere((f) => f.path.endsWith('.md') && f.readAsStringSync().contains('title: $title'));

  Future<Notebook> book() => dev.book('Journal');

  Future<String?> connect(FolderConnections c, SyncKind k, Directory d) async {
    final err = await c.connect(k, d.path);
    await c.syncAll();
    return err;
  }

  group('connecting a folder', () {
    test('Obsidian: the notebooks go out as Markdown files with the phone\'s status line, and what the person wrote in the folder comes in', () async {
      final b = await book();
      final e = await dev.entry(b, 'Water cache restocked', body: 'Swapped six jugs at the shed.');
      final c = make();
      expect(await connect(c, SyncKind.obsidian, vault), isNull);
      final f = noteOf(vault, 'Water cache restocked');
      expect(f.readAsStringSync(), contains('cache_id: ${e.id}'));
      expect(c.status('obsidian'), 'Synced 5:02 PM');
      expect(c.targets.single.path, vault.path);
      // changed in the folder (Obsidian): read into the core
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('six', 'eight'));
      await c.syncAll();
      expect((await dev.store.entry(e.id))!.body, 'Swapped eight jugs at the shed.');
      // changed in the core (a browser): the file follows
      await dev.store.saveEntry(id: e.id, notebookId: b.id, occurredAt: e.occurredAt, title: e.title, body: 'Swapped eight jugs at the barn.');
      await c.syncAll();
      expect(f.readAsStringSync(), endsWith('Swapped eight jugs at the barn.\n'));
      // a new entry in the core gets its own file; nothing is written twice
      await dev.entry(b, 'Second');
      await c.syncAll();
      expect(noteOf(vault, 'Second').existsSync(), isTrue);
      expect(vault.listSync(recursive: true).whereType<File>().where((x) => x.path.endsWith('.md')).length, 2);
    });

    test('changes to different words are combined and told; the same words changed on both sides keep one version and make the other an extra entry', () async {
      final b = await book();
      final e = await dev.entry(b, 'Water', body: 'Swapped six jugs at the shed.');
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      final f = noteOf(vault, 'Water');
      // different words: combined
      await dev.store.saveEntry(id: e.id, notebookId: b.id, occurredAt: e.occurredAt, title: 'Water', body: 'Swapped ten jugs at the shed.');
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('shed', 'garage'));
      await c.syncAll();
      expect(c.merged('obsidian'), ['Water']);
      expect(c.keptAsTwo('obsidian'), isEmpty);
      expect((await dev.store.entry(e.id))!.body, 'Swapped ten jugs at the garage.');
      expect(f.readAsStringSync(), endsWith('Swapped ten jugs at the garage.\n'));
      // the same words: kept as two
      await dev.store.saveEntry(id: e.id, notebookId: b.id, occurredAt: e.occurredAt, title: 'Water', body: 'Swapped eleven jugs at the garage.');
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('ten', 'twelve'));
      await c.syncAll();
      expect(c.keptAsTwo('obsidian'), ['Water']);
      expect(c.conflicts('obsidian'), isEmpty);
      expect(c.status('obsidian'), 'Synced 5:02 PM'); // nothing is asked
      final all = await dev.store.entries(b.id);
      expect(all.map((x) => x.title).toSet(), {'Water', 'Water (other version)'});
      expect(all.map((x) => x.body).toSet(), {'Swapped eleven jugs at the garage.', 'Swapped twelve jugs at the garage.'});
      expect(noteOf(vault, 'Water (other version)').existsSync(), isTrue);
      // and the state op carries both lists for the browser
      final s = c.stateJson()['targets'] as List;
      expect((s.single as Map)['kept_as_two'], ['Water']);
    });

    test('Logseq: a graph is connected, entries go to its journal pages; the Logseq kind is kept in the record', () async {
      final b = await book();
      await dev.entry(b, 'Restocked', body: 'six jugs');
      final c = make();
      expect(await connect(c, SyncKind.logseq, graph), isNull);
      expect(c.targets.single.id, 'logseq');
      final pages = Directory('${graph.path}/journals').listSync().whereType<File>().toList();
      expect(pages.single.readAsStringSync(), allOf(contains('cache-id::'), contains('Restocked')));
      expect(c.status('logseq'), 'Synced 5:02 PM');
    });

    test('a folder that is not there or not a folder is "Can\'t reach the folder."; an Org graph is refused in the phone\'s words; a relative path is bad_path; nothing is kept', () async {
      final c = make();
      expect(await c.connect(SyncKind.obsidian, '${tmp.path}/nope'), "Can't reach the folder.");
      File('${tmp.path}/file.txt').writeAsStringSync('x');
      expect(await c.connect(SyncKind.obsidian, '${tmp.path}/file.txt'), "Can't reach the folder.");
      File('${graph.path}/logseq/config.edn').writeAsStringSync('{:preferred-format "Org"}');
      expect(await c.connect(SyncKind.logseq, graph.path), 'Cache can write to Markdown graphs only.');
      await expectLater(c.connect(SyncKind.obsidian, 'Documents/Vault'), throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'bad_path')));
      expect(c.targets, isEmpty);
      expect(File('${support.path}/notebook-sync/folders.json').existsSync(), isFalse);
    });

    test('connecting again replaces the folder of that app (one Obsidian, one Logseq)', () async {
      final c = make();
      final other = Directory('${tmp.path}/Vault2')..createSync();
      await connect(c, SyncKind.obsidian, vault);
      await connect(c, SyncKind.obsidian, other);
      await connect(c, SyncKind.logseq, graph);
      expect([for (final t in c.targets) '${t.id}:${t.path}'], ['obsidian:${other.path}', 'logseq:${graph.path}']);
    });
  });

  group('pause, sync now and disconnect', () {
    test('a paused connection is left alone and says so; resuming syncs it', () async {
      final b = await book();
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      await c.setPaused('obsidian', true);
      expect(c.status('obsidian'), 'Paused.');
      await dev.entry(b, 'While paused');
      await c.syncAll();
      expect(vault.listSync(recursive: true).whereType<File>().where((f) => f.path.contains('While paused')), isEmpty);
      expect(c.status('obsidian'), 'Paused.');
      await c.setPaused('obsidian', false);
      await c.syncAll();
      expect(noteOf(vault, 'While paused').existsSync(), isTrue);
      expect(c.status('obsidian'), 'Synced 5:02 PM');
    });

    test('Sync now (nbfolders.sync) runs a pass and answers when it is done', () async {
      final b = await book();
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      final before = c.passes;
      await dev.entry(b, 'Later');
      await c.handle('nbfolders.sync', {});
      expect(c.passes, greaterThan(before));
      expect(noteOf(vault, 'Later').existsSync(), isTrue);
    });

    test('disconnecting stops the sync, forgets its record and leaves the files in the folder alone', () async {
      final b = await book();
      await dev.entry(b, 'Kept');
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      final record = File('${support.path}/notebook-sync/obsidian.json');
      expect(record.existsSync(), isTrue);
      await c.disconnect('obsidian');
      expect(c.targets, isEmpty);
      expect(c.status('obsidian'), isNull);
      expect(record.existsSync(), isFalse);
      expect(noteOf(vault, 'Kept').existsSync(), isTrue);
      await dev.entry(b, 'After');
      await c.syncAll();
      expect(vault.listSync(recursive: true).whereType<File>().where((f) => f.path.contains('After')), isEmpty);
      expect(jsonDecode(File('${support.path}/notebook-sync/folders.json').readAsStringSync())['targets'], isEmpty);
    });

    test('a folder that went away is "Can\'t reach the folder." and works again when it is back; nothing in the core is removed', () async {
      final b = await book();
      await dev.entry(b, 'Stays');
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      final moved = Directory('${tmp.path}/Vault-away');
      vault.renameSync(moved.path);
      await c.syncAll();
      expect(c.status('obsidian'), "Can't reach the folder.");
      expect(await dev.store.entries(b.id), hasLength(1));
      moved.renameSync(vault.path);
      await c.syncAll();
      expect(c.status('obsidian'), 'Synced 5:02 PM');
      expect(await dev.store.entries(b.id), hasLength(1));
    });

    test('an entry removed from the folder is written back (Cache is the source of truth); nothing needs a decision', () async {
      final b = await book();
      await dev.entry(b, 'Back again');
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      noteOf(vault, 'Back again').deleteSync();
      await c.syncAll();
      expect(noteOf(vault, 'Back again').existsSync(), isTrue);
      expect(await dev.store.entries(b.id), hasLength(1));
    });
  });

  group('what is kept across a restart', () {
    test('the connections, their pause and import tag are read again; the next pass carries on with no duplicate entries or files', () async {
      final b = await book();
      await dev.entry(b, 'Once');
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      await connect(c, SyncKind.logseq, graph);
      await c.setPaused('logseq', true);
      await c.setImportTag('obsidian', '#fromobsidian');
      await c.syncAll();
      c.stop();
      // a new run of the helper: the same support folder, nothing in memory
      final again = make();
      expect([for (final t in again.targets) t.id], ['obsidian', 'logseq']);
      expect(again.target('obsidian')!.path, vault.path);
      expect(again.target('obsidian')!.tag, '#fromobsidian');
      expect(again.target('logseq')!.paused, isTrue);
      expect(again.status('obsidian'), isNull); // nothing has run yet
      // an entry made in Cache while the helper was off goes out at the first pass
      await dev.entry(b, 'Added while off');
      await again.start();
      expect(again.status('obsidian'), 'Synced 5:02 PM');
      expect(again.status('logseq'), 'Paused.');
      expect(await dev.store.entries(b.id), hasLength(2));
      expect(vault.listSync(recursive: true).whereType<File>().where((x) => x.path.endsWith('.md')), hasLength(2));
      expect(noteOf(vault, 'Added while off').existsSync(), isTrue);
      // the default tag is not written as a custom one
      await again.setImportTag('obsidian', '#cachesync');
      expect(again.target('obsidian')!.importTag, isNull);
      expect(jsonDecode(File('${support.path}/notebook-sync/folders.json').readAsStringSync())['targets'][0].containsKey('import_tag'), isFalse);
    });

    test('a file of connections that is unreadable is logged and leaves none connected', () async {
      Directory('${support.path}/notebook-sync').createSync(recursive: true);
      File('${support.path}/notebook-sync/folders.json').writeAsStringSync('{nope');
      final log = <String>[];
      final c = make(log: log);
      expect(c.targets, isEmpty);
      expect(log.single, contains('unreadable'));
    });

    test('the share\'s own record (targets.json) is not touched by the folders', () async {
      Directory('${support.path}/notebook-sync').createSync(recursive: true);
      final t = File('${support.path}/notebook-sync/targets.json')..writeAsStringSync('{"targets":[],"private_included":["x"]}');
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      expect(t.readAsStringSync(), '{"targets":[],"private_included":["x"]}');
    });
  });

  group('triggers', () {
    test('a write to the notebooks makes a pass after a moment, several writes one pass; with nothing connected nothing runs', () async {
      final b = await book();
      final idle = make();
      idle.changed();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(idle.passes, 0);
      final c = make();
      await connect(c, SyncKind.obsidian, vault);
      final before = c.passes;
      await dev.entry(b, 'One');
      c.changed();
      await dev.entry(b, 'Two');
      c.changed();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await c.syncAll();
      expect(c.passes - before, lessThanOrEqualTo(2));
      expect(noteOf(vault, 'One').existsSync(), isTrue);
      expect(noteOf(vault, 'Two').existsSync(), isTrue);
    });

    test('a pass that brought a change in from the folder tells the notebook sync with linked devices (so it is exported); one that only wrote out does not', () async {
      final b = await book();
      await dev.entry(b, 'Told', body: 'six');
      var told = 0;
      final c = make(onChanged: () => told++);
      await connect(c, SyncKind.obsidian, vault);
      expect(told, 0); // the core's own entries only went out
      final f = noteOf(vault, 'Told');
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('six', 'seven'));
      await c.syncAll();
      expect(told, 1);
      await c.syncAll();
      expect(told, 1);
    });
  });

  group('the ops a browser calls', () {
    test('state, connect, pause, sync and disconnect, as the browser sends them', () async {
      final b = await book();
      await dev.entry(b, 'Via ops');
      final c = make();
      expect(c.handles('nbfolders.state'), isTrue);
      expect(c.handles('devfs.list'), isFalse);
      expect(await c.handle('nbfolders.state', {}), {'syncing': false, 'targets': isEmpty});
      expect(await c.handle('nbfolders.connect', {'kind': 'obsidian', 'path': '${tmp.path}/nope'}), {'error': "Can't reach the folder."});
      expect(await c.handle('nbfolders.connect', {'kind': 'obsidian', 'path': vault.path}), isEmpty);
      await c.syncAll();
      var s = ((await c.handle('nbfolders.state', {})) as Map)['targets'] as List;
      expect(s.single, containsPair('status', 'Synced 5:02 PM'));
      expect(s.single, containsPair('path', vault.path));
      expect(s.single, containsPair('synced_at', fixed.millisecondsSinceEpoch));
      expect(s.single, containsPair('tag', '#cachesync'));
      await c.handle('nbfolders.pause', {'id': 'obsidian', 'paused': true});
      s = ((await c.handle('nbfolders.state', {})) as Map)['targets'] as List;
      expect(s.single, allOf(containsPair('paused', true), containsPair('status', 'Paused.')));
      await c.handle('nbfolders.set_tag', {'id': 'obsidian', 'tag': '#mine'});
      expect(c.target('obsidian')!.tag, '#mine');
      await c.handle('nbfolders.disconnect', {'id': 'obsidian'});
      expect(((await c.handle('nbfolders.state', {})) as Map)['targets'], isEmpty);
      await expectLater(c.handle('nbfolders.connect', {'kind': 'nope', 'path': vault.path}), throwsA(isA<CacheSearchException>()));
      await expectLater(c.handle('nbfolders.pause', {}), throwsA(isA<CacheSearchException>()));
    });
  });
}

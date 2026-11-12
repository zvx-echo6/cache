// Import by tag (1.0.30): a note the person made in Obsidian or Logseq with the import tag and no Cache id is imported once;
// from then on Cache's id decides; deleting the entry or "Stop syncing this note" takes the id out and writes `cachesync: off`.
// These notes are the person's own: every test also checks that nothing of theirs is lost.

import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/folder.dart';
import 'package:cache/notebook/sync/formats.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/entry_editor.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

/// A folder in memory; [readOnly] paths refuse writes.
class _Mem implements SyncFolder {
  final Map<String, String> text = {};
  final Map<String, Uint8List> bytes = {};
  final Set<String> readOnly = {};
  bool up = true;

  @override
  String get display => 'Vault';

  @override
  Future<bool> reachable() async => up;

  @override
  Future<List<FolderFile>> list(String dir) async => [
        for (final p in ({...text.keys, ...bytes.keys}.toList()..sort()))
          if (dir.isEmpty || p.startsWith('$dir/')) FolderFile(p, 0, (text[p] ?? '').length),
      ];

  @override
  Future<String?> readText(String path) async => text[path];

  @override
  Future<Uint8List?> readBytes(String path) async => bytes[path];

  @override
  Future<void> writeText(String path, String t) async {
    if (readOnly.contains(path)) throw const FileSystemException('Read-only file system');
    text[path] = t;
  }

  @override
  Future<void> writeBytes(String path, Uint8List b) async => bytes[path] = b;

  @override
  Future<void> delete(String path) async {
    text.remove(path);
    bytes.remove(path);
  }

  @override
  Future<bool> exists(String path) async => text.containsKey(path) || bytes.containsKey(path);
}

class _Rig {
  _Rig(this.kind, {this.tag = kDefaultImportTag}) {
    nb = fakeNotebook(store);
  }

  final SyncKind kind;
  final String tag;
  final FakeNotebookBackend store = FakeNotebookBackend();
  late final NotebookState nb;
  final _Mem folder = _Mem();
  final File state = File('${Directory.systemTemp.createTempSync('cache-tagsync-').path}/state.json');

  NotebookSync get engine => NotebookSync(notebook: nb, kind: kind, folder: folder, stateFile: state, importTag: tag, clock: () => DateTime(2026, 10, 29, 17, 2));

  Future<Notebook> journal() async {
    await nb.start();
    return nb.journal!;
  }

  int get entryCount => store.entries.length;

  Future<NbEntry> edit(String id, {String? body, String? title}) async {
    final e = (await nb.entry(id))!;
    return nb.saveEntry(id: e.id, notebookId: e.notebookId, occurredAt: e.occurredAt, title: title ?? e.title, body: body ?? e.body, private: e.private);
  }
}

String _idIn(String text) => RegExp(r'cache[_-]id::? (\S+)').firstMatch(text)!.group(1)!;

void main() {
  group('the import tag and the note formats', () {
    test('a tag is # then letters, numbers, dash, underscore, slash; no spaces', () {
      expect(validImportTag('#cachesync'), isTrue);
      expect(validImportTag('#camp_2-go/x'), isTrue);
      expect(validImportTag('#Ünterwegs'), isTrue);
      expect(validImportTag('cachesync'), isFalse);
      expect(validImportTag('#cache sync'), isFalse);
      expect(validImportTag('#'), isFalse);
      expect(validImportTag(''), isFalse);
      expect(validImportTag('#cachesync/'), isFalse);
    });

    test('the tag and its notebook: case does not matter; the first matching tag wins', () {
      expect(importTagIn(['water', 'cachesync'], '#cachesync'), (notebook: null));
      expect(importTagIn(['CacheSync/Camping'], '#cachesync'), (notebook: 'Camping'));
      expect(importTagIn(['#cachesync/Camping trip'], '#cachesync'), (notebook: 'Camping trip'));
      expect(importTagIn(['[[cachesync/Gear]]'], '#cachesync'), (notebook: 'Gear'));
      expect(importTagIn(['cachesyncing', 'cache'], '#cachesync'), isNull);
      expect(importTagIn(['camp'], '#camp'), (notebook: null));
      expect(tagSlug('Camping trip'), tagSlug('camping-trip'));
    });

    test('Obsidian tags: the tags property (list or text) and #tags in the text, never in code or a heading', () {
      expect(obsidianTags('---\ntags:\n  - water\n  - cachesync\n---\nx\n'), containsAll(['water', 'cachesync']));
      expect(obsidianTags('---\ntags: [a, "#cachesync/Gear"]\n---\n'), contains('cachesync/Gear'));
      expect(obsidianTags('---\ntags: a, cachesync\n---\n'), contains('cachesync'));
      expect(obsidianTags('Pack it #cachesync today.\n'), ['cachesync']);
      expect(obsidianTags('# cachesync\n'), isEmpty, reason: 'a heading');
      expect(obsidianTags('```\n#cachesync\n```\nand `#cachesync`\n'), isEmpty, reason: 'code');
      expect(obsidianTags('mail me@x#cachesync\n'), isEmpty);
    });

    test('the id goes in as the first property and out as cachesync: off; nothing else changes', () {
      const plain = 'Buy matches. #cachesync\n';
      expect(withCacheId(plain, 'abc'), '---\ncache_id: abc\n---\nBuy matches. #cachesync\n');
      const props = '---\ntags:\n  - cachesync\nrating: 5\n---\n\nBody\n\n';
      final withId = withCacheId(props, 'abc')!;
      expect(withId, '---\ncache_id: abc\ntags:\n  - cachesync\nrating: 5\n---\n\nBody\n\n');
      expect(releasedObsidian(withId), '---\ncachesync: off\ntags:\n  - cachesync\nrating: 5\n---\n\nBody\n\n');
      expect(withCacheId('---\nbroken\n---\nx', 'abc'), isNull, reason: 'unreadable properties are left alone');
      expect(obsidianSyncOff(releasedObsidian(withId)!), isTrue);
      expect(obsidianSyncOff(withId), isFalse);
    });

    test('Logseq: tags:: values, inline #tags and #[[two words]]; cachesync:: off', () {
      expect(lsTagValues('water, [[cachesync/Camping trip]], #gear'), containsAll(['water', 'cachesync/Camping trip', 'gear']));
      final b = lsBlockOf('- Pack list #[[cachesync/Camping trip]]\n  rating:: 5\n\t- water #other\n');
      expect(importTagIn(lsBlockTags(b), '#cachesync'), (notebook: 'Camping trip'));
      expect(lsBlockTags(lsBlockOf('- Plain\n\t- child #cachesync\n')), isEmpty, reason: "a child block's tag is the child's");
      final withId = lsBlockWithId(b, 'abc');
      expect(withId, '- Pack list #[[cachesync/Camping trip]]\n  rating:: 5\n  cache-id:: abc\n\t- water #other\n');
      expect(lsBlockReleased(lsBlockOf(withId)), '- Pack list #[[cachesync/Camping trip]]\n  rating:: 5\n  cachesync:: off\n\t- water #other\n');
      expect(lsPageReleased('cache-id:: abc\ntags:: cachesync\n\n- a\n'), 'cachesync:: off\ntags:: cachesync\n\n- a\n');
    });
  });

  group('Obsidian: import by tag', () {
    test('a tagged note is imported once and its id written in; edits go both ways; the tag never matters again', () async {
      final r = _Rig(SyncKind.obsidian);
      final j = await r.journal();
      await r.engine.run();
      const path = 'Trips/Camping list.md';
      const note = '---\ntags:\n  - cachesync\nrating: 5\n---\nPack the water filter.\n';
      r.folder.text[path] = note;
      final before = r.entryCount;
      var rep = await r.engine.run();
      expect(rep.imported, ['Camping list']);
      expect(r.entryCount, before + 1);
      final text = r.folder.text[path]!;
      final id = _idIn(text);
      // Cache's id is the first property; everything else is as the person wrote it.
      expect(text, '---\ncache_id: $id\ntags:\n  - cachesync\nrating: 5\n---\nPack the water filter.\n');
      var e = (await r.nb.entry(id))!;
      expect((e.title, e.body, e.notebookId, e.private), ('Camping list', 'Pack the water filter.', j.id, false));
      // imported once: the next sync changes nothing
      rep = await r.engine.run();
      expect((rep.imported.length, rep.read, rep.written), (0, 0, 0));
      expect(r.entryCount, before + 1);
      expect(r.folder.text[path], text);
      // an edit in Obsidian comes back
      r.folder.text[path] = text.replaceFirst('water filter', 'gravity filter');
      rep = await r.engine.run();
      expect(rep.read, 1);
      expect((await r.nb.entry(id))!.body, 'Pack the gravity filter.');
      // an edit in Cache goes out, into the same file, with the person's properties kept
      await r.edit(id, body: 'Pack the gravity filter and matches.');
      rep = await r.engine.run();
      expect(rep.written, 1);
      expect(r.folder.text[path], '---\ncache_id: $id\ntags:\n  - cachesync\nrating: 5\n---\nPack the gravity filter and matches.\n');
      expect(r.folder.text.keys.where((k) => k.endsWith('.md') && k != path), isEmpty, reason: 'no second file');
      // the tag removed: nothing changes in Cache (the id decides)
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('tags:\n  - cachesync\n', '');
      await r.engine.run();
      e = (await r.nb.entry(id))!;
      expect((e.title, e.body), ('Camping list', 'Pack the gravity filter and matches.'));
      expect(r.entryCount, before + 1);
      expect(r.folder.text[path], startsWith('---\ncache_id: $id\n'));
      // the tag added again (inline this time): no duplicate
      r.folder.text[path] = '${r.folder.text[path]!}#cachesync\n';
      rep = await r.engine.run();
      expect(rep.imported, isEmpty);
      expect(r.entryCount, before + 1);
      expect((await r.nb.entry(id))!.body, 'Pack the gravity filter and matches.\n#cachesync');
    });

    test('a note without properties, an inline tag; untagged notes, tags in code and cachesync: off are never imported', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.text['Inbox/Water.md'] = 'Rotate the jugs in April. #cachesync\n';
      r.folder.text['Inbox/Shopping.md'] = 'Buy matches.\n';
      r.folder.text['Inbox/Code.md'] = '```\n#cachesync\n```\n';
      const off = '---\ncachesync: off\ntags: [cachesync]\n---\nNot this one.\n';
      r.folder.text['Inbox/Off.md'] = off;
      const broken = '---\ntags: cachesync\nnot a property\n---\nbody #cachesync\n';
      r.folder.text['Inbox/Broken.md'] = broken;
      final before = r.entryCount;
      final rep = await r.engine.run();
      expect(rep.imported, ['Water']);
      expect(r.entryCount, before + 1);
      final id = _idIn(r.folder.text['Inbox/Water.md']!);
      expect(r.folder.text['Inbox/Water.md'], '---\ncache_id: $id\n---\nRotate the jugs in April. #cachesync\n');
      expect((await r.nb.entry(id))!.body, 'Rotate the jugs in April. #cachesync', reason: 'the inline tag stays in the text');
      expect(r.folder.text['Inbox/Shopping.md'], 'Buy matches.\n');
      expect(r.folder.text['Inbox/Code.md'], '```\n#cachesync\n```\n');
      expect(r.folder.text['Inbox/Off.md'], off);
      expect(r.folder.text['Inbox/Broken.md'], broken);
      // deleting the cachesync: off line by hand makes the note importable again
      r.folder.text['Inbox/Off.md'] = off.replaceFirst('cachesync: off\n', '');
      expect((await r.engine.run()).imported, ['Off']);
    });

    test('#cachesync/<notebook> picks the notebook by name or slug, makes it when there is none; the plain tag is the Journal', () async {
      final r = _Rig(SyncKind.obsidian);
      final j = await r.journal();
      final camping = await r.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Camping trip', fields: [], sort: NotebookSort.recent));
      r.folder.text['a.md'] = 'Tent stakes #cachesync/camping-trip\n';
      r.folder.text['b.md'] = '---\ntags: [cachesync/Gear]\n---\nStove\n';
      r.folder.text['c.md'] = 'Plain one #CacheSync\n';
      r.folder.text['d.md'] = 'By name #cachesync/Camping_trip\n';
      final rep = await r.engine.run();
      expect(rep.imported.length, 4);
      Future<String> bookOf(String path) async => (await r.nb.entry(_idIn(r.folder.text[path]!)))!.notebookId;
      expect(await bookOf('a.md'), camping.id);
      expect(await bookOf('d.md'), camping.id);
      expect(await bookOf('c.md'), j.id);
      final gear = r.nb.notebooks.where((n) => n.name == 'Gear').single;
      expect(await bookOf('b.md'), gear.id);
      // Cache writes nothing of its own for the imported entries (they live in their notes)
      expect(r.folder.text.keys.where((k) => k.startsWith('Gear/') || k.startsWith('Camping trip/')), isEmpty);
    });

    test('private: true makes the entry private', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.text['Med.md'] = '---\nprivate: true\ntags: cachesync\n---\nAllergies\n';
      await r.engine.run();
      final text = r.folder.text['Med.md']!;
      expect((await r.nb.entry(_idIn(text)))!.private, isTrue);
      expect(text, '---\ncache_id: ${_idIn(text)}\nprivate: true\ntags: cachesync\n---\nAllergies\n');
    });

    test("the person's properties that share Cache's names are kept as they are through edits on both sides", () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      const path = 'Ideas.md';
      r.folder.text[path] = '---\ntitle: Ideas\ndate: Oct 3, maybe\nnotebook: Work\nphotos: none\nplace: home\n---\nOne #cachesync\n';
      await r.engine.run();
      final id = _idIn(r.folder.text[path]!);
      expect((await r.nb.entry(id))!.title, 'Ideas');
      await r.edit(id, body: 'One and two #cachesync');
      await r.engine.run();
      expect(r.folder.text[path], '---\ncache_id: $id\ntitle: Ideas\ndate: Oct 3, maybe\nnotebook: Work\nphotos: none\nplace: home\n---\nOne and two #cachesync\n');
      // a Cache title change goes out as the title property; the file's name stays
      await r.edit(id, title: 'Better ideas');
      await r.engine.run();
      expect(r.folder.text[path], contains('title: Better ideas\n'));
      expect(r.folder.text[path], contains('notebook: Work\n'));
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('One and two', 'Three');
      await r.engine.run();
      final e = (await r.nb.entry(id))!;
      expect((e.title, e.body), ('Better ideas', 'Three #cachesync'));
    });

    test('deleting the entry: the id goes out, cachesync: off goes in, the note stays; nothing is written back or imported again', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      const path = 'Trips/List.md';
      const note = '---\ntags:\n  - cachesync\n---\nWater\n\nMatches\n';
      r.folder.text[path] = note;
      await r.engine.run();
      final id = _idIn(r.folder.text[path]!);
      // edited in Obsidian just before: the edit is kept in the note
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('Matches', 'Matches and a lighter');
      await r.nb.deleteEntry(id);
      final before = r.entryCount;
      var rep = await r.engine.run();
      expect(rep.released, 1);
      expect(r.folder.text[path], '---\ncachesync: off\ntags:\n  - cachesync\n---\nWater\n\nMatches and a lighter\n');
      expect(await r.nb.entry(id), isNull, reason: 'the entry stays deleted');
      for (var i = 0; i < 2; i++) {
        rep = await r.engine.run();
        expect((rep.imported.length, rep.written, rep.read, rep.released), (0, 0, 0, 0));
      }
      expect(r.entryCount, before);
      expect(r.folder.text[path], '---\ncachesync: off\ntags:\n  - cachesync\n---\nWater\n\nMatches and a lighter\n');
      expect(r.folder.text.keys.where((k) => k.endsWith('.md')), [path], reason: 'nothing written back');
    });

    test('"Stop syncing this note": the id goes out, the entry stays in Cache, and neither changes the other again', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      const path = 'Gear.md';
      r.folder.text[path] = 'Stove #cachesync\n';
      await r.engine.run();
      final id = _idIn(r.folder.text[path]!);
      // the folder cannot be reached: nothing is changed
      r.folder.up = false;
      expect(await r.engine.stopSyncing(id), isFalse);
      r.folder.up = true;
      expect(r.folder.text[path], contains('cache_id: $id'));
      expect(await r.engine.stopSyncing(id), isTrue);
      expect(r.folder.text[path], '---\ncachesync: off\n---\nStove #cachesync\n');
      expect((await r.nb.entry(id))!.body, 'Stove #cachesync');
      final links = await NotebookSync.links(r.state);
      expect(links.stopped, {id});
      expect(links.imported, isEmpty);
      // a change in Cache stays in Cache; a change in the note stays in the note; no new file and no import
      await r.edit(id, body: 'Stove and fuel');
      r.folder.text[path] = '${r.folder.text[path]!}more\n';
      final before = r.entryCount;
      final rep = await r.engine.run();
      expect((rep.written, rep.read, rep.imported.length), (0, 0, 0));
      expect(r.folder.text[path], '---\ncachesync: off\n---\nStove #cachesync\nmore\n');
      expect(r.folder.text.keys.where((k) => k.endsWith('.md')), [path]);
      expect(r.entryCount, before);
      expect((await r.nb.entry(id))!.body, 'Stove and fuel');
    });

    test('a note whose id points to no entry Cache knows is left alone, tag or not', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      const stale = '---\ncache_id: 0b6a1f0e-1111-4222-a333-444455556666\ntags: cachesync\n---\nFrom another phone.\n';
      r.folder.text['Stale.md'] = stale;
      final before = r.entryCount;
      final rep = await r.engine.run();
      expect((rep.imported.length, rep.read), (0, 0));
      expect(r.entryCount, before);
      expect(r.folder.text['Stale.md'], stale);
    });

    test('a note moved or renamed in Obsidian is followed; a note deleted there is written back', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.text['A.md'] = 'One #cachesync\n';
      await r.engine.run();
      final text = r.folder.text.remove('A.md')!;
      final id = _idIn(text);
      r.folder.text['Moved/B.md'] = text;
      await r.engine.run();
      await r.edit(id, body: 'Two #cachesync');
      await r.engine.run();
      expect(r.folder.text.keys.where((k) => k.endsWith('.md')), ['Moved/B.md']);
      expect(r.folder.text['Moved/B.md'], endsWith('Two #cachesync\n'));
      r.folder.text.remove('Moved/B.md');
      await r.engine.run();
      expect(r.folder.text['Moved/B.md'], contains('cache_id: $id'));
    });

    test('Obsidian: the id taken out by hand, the tag kept: no duplicate; cachesync: off; the entry stops; deleting that line imports it anew', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.text['A.md'] = '---\ntags: [cachesync]\n---\nOne #cachesync\n';
      await r.engine.run();
      final id = _idIn(r.folder.text['A.md']!);
      final before = r.entryCount;
      // (a) only the id line removed: the tags stay
      r.folder.text['A.md'] = '---\ntags: [cachesync]\n---\nOne, edited #cachesync\n';
      var rep = await r.engine.run();
      expect((rep.imported.length, rep.written, rep.read), (0, 0, 0));
      expect(r.entryCount, before, reason: 'no duplicate');
      expect(r.folder.text['A.md'], '---\ncachesync: off\ntags: [cachesync]\n---\nOne, edited #cachesync\n');
      expect((await NotebookSync.links(r.state)).stopped, {id});
      expect((await r.nb.entry(id))!.body, 'One #cachesync', reason: 'the entry stays as it was');
      // stopped: a change in Cache stays in Cache; the next syncs change nothing
      await r.edit(id, body: 'Changed in Cache');
      rep = await r.engine.run();
      expect((rep.imported.length, rep.written), (0, 0));
      expect(r.folder.text['A.md'], '---\ncachesync: off\ntags: [cachesync]\n---\nOne, edited #cachesync\n');
      // (c) the person deletes cachesync: off with the tag there: imported once, as a new entry
      r.folder.text['A.md'] = '---\ntags: [cachesync]\n---\nOne, edited #cachesync\n';
      rep = await r.engine.run();
      expect(rep.imported, ['A']);
      expect(r.entryCount, before + 1);
      final again = _idIn(r.folder.text['A.md']!);
      expect(again, isNot(id));
      expect((await r.engine.run()).imported.length, 0);
      expect(r.entryCount, before + 1);
    });

    test('Obsidian: the id and the tag both taken out by hand (no properties left): cachesync: off all the same; the text stays', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.text['A.md'] = 'One #cachesync\n';
      await r.engine.run();
      final id = _idIn(r.folder.text['A.md']!);
      r.folder.text['A.md'] = 'One, my own now\n';
      await r.engine.run();
      expect(r.folder.text['A.md'], '---\ncachesync: off\n---\nOne, my own now\n');
      expect((await NotebookSync.links(r.state)).stopped, {id});
      await r.edit(id, body: 'Changed in Cache');
      await r.engine.run();
      expect(r.folder.text['A.md'], '---\ncachesync: off\n---\nOne, my own now\n');
      // the tag added back with the line still there: never imported
      r.folder.text['A.md'] = '---\ncachesync: off\n---\nOne, my own now #cachesync\n';
      expect((await r.engine.run()).imported.length, 0);
    });

    test('a read-only note is not added (nothing is made in Cache) and is left as it is', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.text['Locked.md'] = 'Keep #cachesync\n';
      r.folder.readOnly.add('Locked.md');
      final before = r.entryCount;
      final rep = await r.engine.run();
      expect((rep.notAdded, rep.imported.length), (1, 0));
      expect(r.entryCount, before);
      expect(r.folder.text['Locked.md'], 'Keep #cachesync\n');
    });

    test('the import tag is settable: #camp imports, #cachesync then does not', () async {
      final r = _Rig(SyncKind.obsidian, tag: '#camp');
      await r.journal();
      r.folder.text['a.md'] = 'One #camp\n';
      r.folder.text['b.md'] = 'Two #cachesync\n';
      final rep = await r.engine.run();
      expect(rep.imported, ['a']);
      expect(r.folder.text['b.md'], 'Two #cachesync\n');
    });
  });

  group('Logseq: import by tag', () {
    test('a page with tags:: cachesync: imported once, edits both ways, it stays on its page', () async {
      final r = _Rig(SyncKind.logseq);
      await r.journal();
      const path = 'pages/Gear list.md';
      r.folder.text[path] = 'tags:: cachesync\n\n- Water filter\n- Stove\n';
      final before = r.entryCount;
      var rep = await r.engine.run();
      expect(rep.imported, ['Gear list']);
      final text = r.folder.text[path]!;
      final id = _idIn(text);
      expect(text, 'cache-id:: $id\ntags:: cachesync\n\n- Water filter\n- Stove\n');
      expect((await r.nb.entry(id))!.body, '- Water filter\n- Stove');
      expect((await r.engine.run()).imported, isEmpty);
      expect(r.entryCount, before + 1);
      r.folder.text[path] = text.replaceFirst('Stove', 'Stove and fuel');
      expect((await r.engine.run()).read, 1);
      expect((await r.nb.entry(id))!.body, '- Water filter\n- Stove and fuel');
      await r.edit(id, body: '- Water filter\n- Stove and fuel\n- Matches');
      expect((await r.engine.run()).written, 1);
      expect(r.folder.text[path], 'cache-id:: $id\ntags:: cachesync\n\n- Water filter\n- Stove and fuel\n- Matches\n');
      expect(r.folder.text.keys.where((k) => k.startsWith('journals/')), isEmpty, reason: 'not moved to a journal page');
      // the tag removed: no change; deleted in Cache: cachesync:: off, the page stays
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('tags:: cachesync\n', '');
      await r.engine.run();
      expect(r.entryCount, before + 1);
      await r.nb.deleteEntry(id);
      expect((await r.engine.run()).released, 1);
      expect(r.folder.text[path], 'cachesync:: off\n\n- Water filter\n- Stove and fuel\n- Matches\n');
      r.folder.text[path] = 'tags:: cachesync\n${r.folder.text[path]!}';
      final rep2 = await r.engine.run();
      expect((rep2.imported.length, rep2.written), (0, 0), reason: 'cachesync:: off: never imported again');
    });

    test('a block with an inline #cachesync on a journal page: imported in place; the other blocks byte for byte', () async {
      final r = _Rig(SyncKind.logseq);
      await r.journal();
      const page = 'journals/2026_10_29.md';
      const mine = '- My own note\n\t- child\n';
      const after = '- Another of mine\n';
      r.folder.text[page] = '$mine- Pack list #cachesync\n\t- water\n\t\t- two jugs\n\t- matches\n$after';
      var rep = await r.engine.run();
      expect(rep.imported, ['Pack list #cachesync']);
      final id = _idIn(r.folder.text[page]!);
      expect(r.folder.text[page], '$mine- Pack list #cachesync\n  cache-id:: $id\n\t- water\n\t\t- two jugs\n\t- matches\n$after');
      final e = (await r.nb.entry(id))!;
      expect((e.title, e.body, e.occurredAt.substring(0, 16)), ('Pack list #cachesync', '- water\n\t- two jugs\n- matches', '2026-10-29T17:02'));
      // edit in Logseq comes back; edit in Cache goes out, in place
      r.folder.text[page] = r.folder.text[page]!.replaceFirst('matches', 'matches and a lighter');
      expect((await r.engine.run()).read, 1);
      await r.edit(id, body: '- water\n\t- two jugs\n- matches and a lighter\n- stove');
      rep = await r.engine.run();
      expect(rep.written, 1);
      expect(r.folder.text[page], '$mine- Pack list #cachesync\n  cache-id:: $id\n\t- water\n\t\t- two jugs\n\t- matches and a lighter\n\t- stove\n$after');
      // stop syncing: cachesync:: off in the block; the entry stays
      expect(await r.engine.stopSyncing(id), isTrue);
      expect(r.folder.text[page], '$mine- Pack list #cachesync\n  cachesync:: off\n\t- water\n\t\t- two jugs\n\t- matches and a lighter\n\t- stove\n$after');
      await r.edit(id, body: 'only in Cache');
      final before = r.entryCount;
      rep = await r.engine.run();
      expect((rep.written, rep.imported.length), (0, 0));
      expect(r.entryCount, before);
      expect(r.folder.text[page], contains('\t- stove\n$after'));
      expect((await r.nb.entry(id))!.body, 'only in Cache');
    });

    test('Logseq: #[[cachesync/Camping trip]] routes; private:: true; cachesync:: off pages are never imported; a block deleted in Cache keeps its text', () async {
      final r = _Rig(SyncKind.logseq);
      await r.journal();
      r.folder.text['pages/Trip.md'] = '- Tent #[[cachesync/Camping trip]]\n  private:: true\n\t- stakes\n';
      const off = 'tags:: cachesync\ncachesync:: off\n\n- no\n';
      r.folder.text['pages/Off.md'] = off;
      final rep = await r.engine.run();
      expect(rep.imported, ['Tent #[[cachesync/Camping trip]]']);
      expect(r.folder.text['pages/Off.md'], off);
      final id = _idIn(r.folder.text['pages/Trip.md']!);
      final e = (await r.nb.entry(id))!;
      expect(r.nb.notebook(e.notebookId)!.name, 'Camping trip');
      expect(e.private, isTrue);
      await r.nb.deleteEntry(id);
      await r.engine.run();
      expect(r.folder.text['pages/Trip.md'], '- Tent #[[cachesync/Camping trip]]\n  private:: true\n  cachesync:: off\n\t- stakes\n');
      expect((await r.engine.run()).imported, isEmpty);
    });

    test('Logseq: a block\'s id taken out by hand, tag kept or not: no duplicate; cachesync:: off; deleting it imports anew', () async {
      final r = _Rig(SyncKind.logseq);
      await r.journal();
      const page = 'journals/2026_10_29.md';
      const mine = '- My own note\n';
      r.folder.text[page] = '$mine- Pack list #cachesync\n\t- water\n- Tent #cachesync\n\t- stakes\n';
      await r.engine.run();
      final ids = RegExp(r'cache-id:: (\S+)').allMatches(r.folder.text[page]!).map((m) => m.group(1)!).toList();
      expect(ids.length, 2);
      final before = r.entryCount;
      // (a) the first block's id line removed, its tag kept; (b) the second's id line and tag removed
      r.folder.text[page] = '$mine- Pack list #cachesync\n\t- water\n- Tent\n\t- stakes\n';
      var rep = await r.engine.run();
      expect((rep.imported.length, rep.written), (0, 0));
      expect(r.entryCount, before);
      expect(r.folder.text[page], '$mine- Pack list #cachesync\n  cachesync:: off\n\t- water\n- Tent\n  cachesync:: off\n\t- stakes\n');
      final links = await NotebookSync.links(r.state);
      expect(links.stopped, {...ids});
      expect((await r.engine.run()).imported.length, 0);
      // (c) cachesync:: off deleted with the tag there: imported once, as new
      r.folder.text[page] = '$mine- Pack list #cachesync\n\t- water\n- Tent\n  cachesync:: off\n\t- stakes\n';
      rep = await r.engine.run();
      expect(rep.imported, ['Pack list #cachesync']);
      expect(r.entryCount, before + 1);
      expect((await r.engine.run()).imported.length, 0);
    });

    test('Logseq: a page\'s id taken out by hand, tag kept: no duplicate; cachesync:: off; deleting it imports anew', () async {
      final r = _Rig(SyncKind.logseq);
      await r.journal();
      const path = 'pages/Gear list.md';
      r.folder.text[path] = 'tags:: cachesync\n\n- Stove\n';
      await r.engine.run();
      final id = _idIn(r.folder.text[path]!);
      final before = r.entryCount;
      r.folder.text[path] = 'tags:: cachesync\n\n- Stove\n';
      var rep = await r.engine.run();
      expect((rep.imported.length, rep.written), (0, 0));
      expect(r.entryCount, before);
      expect(r.folder.text[path], 'cachesync:: off\ntags:: cachesync\n\n- Stove\n');
      expect((await NotebookSync.links(r.state)).stopped, {id});
      // (b) tag gone as well: the line stays, nothing else is written
      r.folder.text[path] = 'cachesync:: off\n\n- Stove\n';
      expect((await r.engine.run()).written, 0);
      expect(r.folder.text[path], 'cachesync:: off\n\n- Stove\n');
      // (c)
      r.folder.text[path] = 'tags:: cachesync\n\n- Stove\n';
      rep = await r.engine.run();
      expect(rep.imported, ['Gear list']);
      expect(r.entryCount, before + 1);
    });

    test('Logseq 2 (export only) never imports', () async {
      final r = _Rig(SyncKind.logseqExport);
      await r.journal();
      r.folder.text['pages/A.md'] = 'tags:: cachesync\n\n- a\n';
      expect((await r.engine.run()).imported, isEmpty);
      expect(r.folder.text['pages/A.md'], 'tags:: cachesync\n\n- a\n');
    });
  });

  group('screens', () {
    Future<(NotebookConnections, _Mem, NotebookState)> connected(WidgetTester tester, {String note = 'Stove #cachesync\n'}) async {
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store);
      final mem = _Mem()..text['Gear.md'] = note;
      final dir = Directory.systemTemp.createTempSync('cache-tagsync-conn-');
      final c = NotebookConnections(notebook: nb, dir: () async => dir, folderFor: (_) => mem);
      await tester.runAsync(() async {
        await nb.start();
        await c.init();
        await c.connect(SyncKind.obsidian, '/vault', display: 'Vault');
        await c.syncAll();
        while (c.syncing) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      return (c, mem, nb);
    }

    testWidgets('Connections: the import tag row and its sheet; an invalid tag says why and cannot be saved', (tester) async {
      final (c, _, _) = await connected(tester);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: ConnectionsScreen(connections: c, pickFolder: () async => null)));
      expect(find.byKey(const ValueKey('import-tag-obsidian')), findsOneWidget);
      expect(find.text('#cachesync'), findsOneWidget);
      expect(find.text('Notes with this tag are added to Cache.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-tag-obsidian')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('import-tag-field')), '#camp trip');
      await tester.pump();
      expect(find.text('Use a tag like #cachesync. No spaces.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-tag-save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('import-tag-field')), '#camping');
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('import-tag-save')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      // the tag is saved to disk before the snack bar: give the file write its time
      for (var i = 0; i < 10 && find.text('Import tag is #camping.').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.target(SyncKind.obsidian)!.tag, '#camping');
      expect(find.text('Import tag is #camping.'), findsOneWidget);
      expect(find.text('Notes already in Cache keep syncing.'), findsOneWidget);
    });

    testWidgets('on phones the Obsidian section says Obsidian syncs only while it is open; not on a computer', (tester) async {
      final (c, _, _) = await connected(tester);
      for (final phone in [true, false]) {
        await tester.pumpWidget(MaterialApp(
            key: UniqueKey(), theme: buildTheme(CacheThemeId.dark), home: ConnectionsScreen(connections: c, pickFolder: () async => null, phone: phone)));
        expect(find.text('On phones, Obsidian sends and receives changes only while the Obsidian app is open. Open it to sync.'), phone ? findsOneWidget : findsNothing);
      }
    });

    testWidgets('an imported entry offers "Stop syncing this note"; afterwards it shows the sync-off mark', (tester) async {
      final (c, mem, nb) = await connected(tester);
      final id = _idIn(mem.text['Gear.md']!);
      expect(c.importedFrom(id), 'Obsidian');
      final e = (await tester.runAsync(() => nb.entry(id)))!;
      final book = nb.notebook(e.notebookId)!;
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(CacheThemeId.dark), home: EntryEditor(notebook: nb, book: book, places: PlaceChoices.none, entry: e, connections: c)));
      expect(find.byKey(const ValueKey('sync-off')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop syncing this note'));
      await tester.pumpAndSettle();
      expect(find.text('Stop syncing this note?'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('stop-sync-confirm'))));
      // stopping writes the note to disk before the snack bar: wait for the snack bar itself (bounded),
      // short pumps so it is not dismissed before the check
      for (var i = 0; i < 200 && find.text('Stopped syncing. The note stays in both.').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Stopped syncing. The note stays in both.'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(mem.text['Gear.md'], '---\ncachesync: off\n---\nStove #cachesync\n');
      expect(c.stoppedWith(id), 'Obsidian');
      expect(find.bySemanticsLabel('Not syncing with Obsidian'), findsOneWidget);
    });

    testWidgets('deleting an imported entry says what happens to the note', (tester) async {
      final (c, mem, nb) = await connected(tester);
      final id = _idIn(mem.text['Gear.md']!);
      final e = (await tester.runAsync(() => nb.entry(id)))!;
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(CacheThemeId.dark),
          home: EntryEditor(notebook: nb, book: nb.notebook(e.notebookId)!, places: PlaceChoices.none, entry: e, connections: c)));
      await tester.tap(find.byKey(const ValueKey('editor-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-imported')), findsOneWidget);
      expect(find.textContaining('The note in Obsidian stays and loses its Cache ID.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryEditor), findsOneWidget, reason: 'cancel keeps the entry open');
    });
  });
}

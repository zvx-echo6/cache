import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/folder.dart';
import 'package:cache/notebook/sync/folder_access.dart';
import 'package:cache/notebook/sync/formats.dart';
import 'package:cache/notebook/sync/merge.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/pin_screen.dart';
import 'package:cache/settings/app_pin.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:cache/video/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

/// A folder in memory.
class MemFolder implements SyncFolder {
  final Map<String, String> text = {};
  final Map<String, Uint8List> bytes = {};
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
  Future<void> writeText(String path, String t) async => text[path] = t;

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

/// The share between two devices, as cache_sync keeps it: every file but the hidden ones, a change on one side goes to the other
/// (deletes too), and when both changed a file the side with the lesser content keeps its file as a conflict copy and takes the
/// other's (the copy then goes across as a file of its own).
class _Link {
  _Link(this.a, this.b);

  final MemFolder a;
  final MemFolder b;
  Map<String, String> last = {};

  /// Paths the share does not carry yet (a slow transfer): left as they are on both sides.
  bool Function(String path)? block;

  void sync() {
    final next = <String, String>{};
    final paths = {...a.text.keys, ...b.text.keys, ...last.keys}.where((p) => !p.split('/').any((s) => s.startsWith('.')));
    for (final p in paths.toList()..sort()) {
      final l = last[p], x = a.text[p], y = b.text[p];
      if (block?.call(p) ?? false) {
        if (l != null) next[p] = l;
        continue;
      }
      var win = x;
      if (x != y) {
        final xc = x != l, yc = y != l;
        if (xc && !yc) {
          win = x;
        } else if (yc && !xc) {
          win = y;
        } else if (x != null && y != null) {
          win = x.compareTo(y) >= 0 ? x : y;
          final loser = identical(win, x) ? b : a;
          final lost = identical(win, x) ? y : x;
          final dot = p.lastIndexOf('.');
          loser.text['${p.substring(0, dot)} (conflict, ${identical(win, x) ? 'Field tablet' : 'Home phone'}, 2026-11-10 0900)${p.substring(dot)}'] = lost;
        } else {
          win = x ?? y;
        }
        for (final f in [a, b]) {
          if (win == null) {
            f.text.remove(p);
          } else {
            f.text[p] = win;
          }
        }
      }
      if (win != null) next[p] = win;
    }
    last = next;
  }
}

/// A notebook sync that does not apply a remote notebook delete (what the per-peer switch will do).
class _KeepEngine extends NotebookSync {
  _KeepEngine(_Rig r) : super(notebook: r.nb, kind: SyncKind.share, folder: r.folder, stateFile: r.state, includePrivate: false);

  @override
  bool appliesRemoteNotebookDelete(Notebook n) => false;
}

class _Rig {
  _Rig(this.kind, {this.includePrivate = true}) {
    nb = fakeNotebook(store);
    nb.reidJournal = reidFile;
  }

  final File reidFile = File('${Directory.systemTemp.createTempSync('cache-reid-').path}/reid-journal.json');

  final SyncKind kind;
  final bool includePrivate;
  final FakeNotebookBackend store = FakeNotebookBackend();
  late final NotebookState nb;
  final MemFolder folder = MemFolder();
  final File state = File('${Directory.systemTemp.createTempSync('cache-nbsync-').path}/state.json');

  NotebookSync get engine => NotebookSync(notebook: nb, kind: kind, folder: folder, stateFile: state, includePrivate: includePrivate, clock: () => DateTime(2026, 10, 29, 17, 2));

  Future<Notebook> journal() async {
    await nb.start();
    return nb.journal!;
  }
}

void main() {
  group('three-way merge, word by word', () {
    test('changes to different words are both kept; the same words changed on both sides are a conflict', () {
      const base = 'Swapped six jugs at the shed. Next rotation in April.';
      final m = merge3(base, 'Swapped eight jugs at the shed. Next rotation in April.', 'Swapped six jugs at the barn. Next rotation in May.');
      expect(m.clean, isTrue);
      expect(m.text, 'Swapped eight jugs at the barn. Next rotation in May.');
      final c = merge3(base, 'Swapped eight jugs at the shed. Next rotation in April.', 'Swapped ten jugs at the shed. Next rotation in April.');
      expect(c.conflicts, 1);
      expect(merge3(base, base, 'x').text, 'x');
      expect(merge3(base, 'y', base).text, 'y');
      expect(merge3('', 'same', 'same').clean, isTrue);
      expect(tokens('a, b').join(), 'a, b');
    });
  });

  group('Obsidian files', () {
    test('an entry as properties and text, read back as it was; the person\'s own properties are kept in order', () {
      final d = EntryDoc(
        id: '7d3c2a8e-5b1f-4c3e-9f0a-1b2c3d4e5f60',
        notebook: 'Journal',
        when: '2026-10-27T16:12:00',
        title: 'Water cache restocked',
        body: 'Swapped six 5-gallon jugs at the shed.',
        place: const NbPlace(lat: 43.615, lon: -116.202, label: 'Home'),
        photos: const ['0b9e1f2a'],
        extra: const ['tags:', '  - water', 'rating: 5'],
      );
      final text = renderObsidian(d);
      expect(text, '---\n'
          'cache_id: 7d3c2a8e-5b1f-4c3e-9f0a-1b2c3d4e5f60\n'
          'notebook: Journal\n'
          'title: Water cache restocked\n'
          'date: 2026-10-27\n'
          'time: 2026-10-27T16:12:00\n'
          'place: Home\n'
          'lat: 43.615\n'
          'lon: -116.202\n'
          'photos:\n'
          '  - "[[cache-0b9e1f2a.jpg]]"\n'
          'tags:\n'
          '  - water\n'
          'rating: 5\n'
          '---\n'
          'Swapped six 5-gallon jugs at the shed.\n');
      final back = parseObsidian(text, fallbackId: '', fallbackNotebook: '', fieldProps: const {})!;
      expect((back.id, back.notebook, back.when, back.title, back.body), (d.id, 'Journal', d.when, d.title, d.body));
      expect(back.photos, ['0b9e1f2a']);
      expect(back.place, d.place);
      expect(back.extra, ['tags:', '  - water', 'rating: 5']);
      expect(renderObsidian(back), text);
    });

    test('values are quoted when they would read as something else; field names follow the rules', () {
      expect(yamlText('Home'), 'Home');
      expect(yamlText('12'), '"12"');
      expect(yamlText('yes'), '"yes"');
      expect(yamlText('a: b'), '"a: b"');
      expect(yamlText('#tag'), '"#tag"');
      expect(yamlText('[[Water plan]]'), '"[[Water plan]]"');
      expect(yamlText(' padded'), '" padded"');
      expect(yamlText('2026-10-27'), '"2026-10-27"');
      expect(yamlValue('"a: \\"b\\""'), 'a: "b"');
      expect(propName('Run time'), 'run_time');
      expect(propName('Tags'), 'tags_field');
      expect(propName('Place'), 'place_field');
      expect(propName('%'), 'field');
      expect(propName('Run time', taken: ['run_time']), 'run_time_2');
      expect(noteFileName(EntryDoc(id: 'x', notebook: 'J', when: '2026-10-27T16:12:00', title: 'Gate: code #2?')), '2026-10-27 Gate code 2');
      expect(noteFileName(EntryDoc(id: 'x', notebook: 'J', when: '2026-10-27T16:12:00')), '2026-10-27 1612');
      expect(splitFrontMatter('---\ntitle: x\nbroken line without colon\n---\nbody'), isNull);
    });

    test('log fields are properties by name, typed', () {
      final d = EntryDoc(id: 'e1', notebook: 'Generator test', when: '2026-10-25T16:12:00', fields: const {'run_time': 20, 'under_load': true, 'fuel_level': 'Full'}, body: 'Oil fine.');
      final t = renderObsidian(d);
      expect(t, contains('run_time: 20\nunder_load: true\nfuel_level: Full\n'));
      final back = parseObsidian(t, fallbackId: '', fallbackNotebook: '', fieldProps: const {'run_time': FieldType.number, 'under_load': FieldType.yesNo, 'fuel_level': FieldType.choice})!;
      expect(back.fields, {'run_time': 20, 'under_load': true, 'fuel_level': 'Full'});
    });
  });

  group('Logseq blocks', () {
    test('a block on a journal page, read back; the other blocks of the page stay byte for byte', () {
      final d = EntryDoc(id: 'abc-1', notebook: 'Journal', when: '2026-10-27T16:12:00', title: 'Water cache restocked', body: 'Swapped six jugs.\nNext rotation in April.', place: const NbPlace(lat: 43.615, lon: -116.202, label: 'Home'));
      final block = renderLogseq(d);
      expect(block, '- 16:12 Water cache restocked\n  cache-id:: abc-1\n  notebook:: Journal\n  place:: Home\n  lat:: 43.615\n  lon:: -116.202\n\t- Swapped six jugs.\n\t- Next rotation in April.\n');
      const mine = 'title:: my day\n\n- My own note\n\t- with a child\n';
      final page = splitPage('$mine$block- Later note\n');
      expect(page.head, 'title:: my day\n\n');
      expect(page.blocks.length, 3);
      expect(page.blocks[1].cacheId, 'abc-1');
      expect(page.head + page.blocks.map((b) => b.text).join(), '$mine$block- Later note\n');
      final back = parseLogseq(page.blocks[1], day: '2026-10-27', fallbackNotebook: '', fieldProps: const {});
      expect((back.id, back.title, back.body, back.when, back.place), ('abc-1', 'Water cache restocked', d.body, d.when, d.place));
    });

    test('config.edn: the journal file names and folder; an Org graph is refused', () {
      final c = readLogseqConfig('{:journal/file-name-format "yyyy-MM-dd" :journals-directory "daily" :preferred-format "Markdown"}');
      expect((c.format, c.dir, c.org), ('yyyy-MM-dd', 'daily', false));
      expect(readLogseqConfig(null).format, 'yyyy_MM_dd');
      expect(readLogseqConfig('{:preferred-format "Org"}').org, isTrue);
      expect(journalFileName('2026-10-27'), '2026_10_27.md');
      expect(dayOfJournal('2026-10-27.md', format: 'yyyy-MM-dd'), '2026-10-27');
      expect(dayOfJournal('notes.md'), isNull);
    });
  });

  group('syncing with an Obsidian folder', () {
    test('every rule of the table, entry by entry', () async {
      final r = _Rig(SyncKind.obsidian);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Water cache restocked', body: 'Swapped six jugs at the shed.');
      final p = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T17:00:00-06:00', title: 'Private one', body: 'secret', private: true);
      // Cache only: written (private items too: decided 2026-10-29)
      var rep = await r.engine.run();
      expect(rep.written, 2);
      const path = 'Journal/2026-10-27 Water cache restocked.md';
      expect(r.folder.text[path], contains('cache_id: ${a.id}'));
      expect(r.folder.text.keys, contains('Journal/2026-10-27 Private one.md'));
      expect(r.folder.text['.cache/notebooks.json'], contains('"cache-notebooks"'));
      // nothing changed: nothing happens
      rep = await r.engine.run();
      expect((rep.written, rep.read, rep.conflicts), (0, 0, 0));
      // changed in the file only: read into Cache
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('six', 'eight');
      rep = await r.engine.run();
      expect(rep.read, 1);
      expect((await r.nb.entry(a.id))!.body, 'Swapped eight jugs at the shed.');
      // changed in Cache only: the file follows
      var e = (await r.nb.entry(a.id))!;
      await r.nb.saveEntry(id: e.id, notebookId: j.id, occurredAt: e.occurredAt, title: e.title, body: 'Swapped eight jugs at the barn.');
      rep = await r.engine.run();
      expect(rep.written, 1);
      expect(r.folder.text[path], endsWith('Swapped eight jugs at the barn.\n'));
      // changed in both, different words: merged, and the person is told
      e = (await r.nb.entry(a.id))!;
      await r.nb.saveEntry(id: e.id, notebookId: j.id, occurredAt: e.occurredAt, title: e.title, body: 'Swapped ten jugs at the barn.');
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('barn', 'garage');
      rep = await r.engine.run();
      expect(rep.merged, ['Water cache restocked']);
      expect((await r.nb.entry(a.id))!.body, 'Swapped ten jugs at the garage.');
      expect(r.folder.text[path], endsWith('Swapped ten jugs at the garage.\n'));
      // changed in both, the same words: Cache asks
      e = (await r.nb.entry(a.id))!;
      await r.nb.saveEntry(id: e.id, notebookId: j.id, occurredAt: e.occurredAt, title: e.title, body: 'Swapped eleven jugs at the garage.');
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('ten', 'twelve');
      final eng = r.engine;
      rep = await eng.run();
      expect(rep.conflicts, 1);
      final c = eng.conflicts.single;
      expect(c.kind, ConflictKind.bothChanged);
      // keep the file's: Cache takes it, Cache's version is kept as a copy
      await eng.resolve(c, keepCache: false);
      expect((await r.nb.entry(a.id))!.body, 'Swapped twelve jugs at the garage.');
      expect(r.folder.text.keys.where((k) => k.startsWith('Conflicts/')).single, startsWith('Conflicts/2026-10-29 1702 Water cache restocked'));
      expect((await r.engine.run()).conflicts, 0);
      // deleted in Cache, file unchanged: the file goes
      await r.nb.deleteEntry(p.id);
      rep = await r.engine.run();
      expect(rep.deleted, 1);
      expect(r.folder.text.keys, isNot(contains('Journal/2026-10-27 Private one.md')));
      // removed in the folder: Cache is the source of truth, so its file is written back and the entry stays
      r.folder.text.remove(path);
      rep = await r.engine.run();
      expect((rep.conflicts, rep.written, rep.deleted), (0, 1, 0));
      expect(r.folder.text[path], contains('cache_id: ${a.id}'));
      expect(await r.nb.entry(a.id), isNotNull);
      // a new note in the Journal folder: never read (Cache syncs its own files only), and left exactly as it is
      final before = r.store.entries.length;
      r.folder.text['Journal/Shopping.md'] = 'Buy matches.\n';
      rep = await r.engine.run();
      expect((rep.read, rep.conflicts), (0, 0));
      expect(r.store.entries.length, before);
      expect(r.folder.text['Journal/Shopping.md'], 'Buy matches.\n');
      // a note of the person's own with broken properties: not Cache's, so not a question either
      const broken = '---\ntitle: x\nnot a property\n---\nbody\n';
      r.folder.text['Journal/Broken.md'] = broken;
      expect((await r.engine.run()).conflicts, 0);
      expect(r.folder.text['Journal/Broken.md'], broken);
      // Cache's own file made unreadable: left alone, and Cache asks
      final good = r.folder.text[path]!;
      r.folder.text[path] = broken;
      final eng3 = r.engine;
      expect((await eng3.run()).conflicts, 1);
      expect(eng3.conflicts.single.kind, ConflictKind.unreadable);
      expect(r.folder.text[path], broken);
      await eng3.resolve(eng3.conflicts.single, keepCache: true);
      expect((await r.engine.run()).conflicts, 0, reason: 'ignored from now on');
      expect(good, contains('cache_id: ${a.id}'));
    });

    test('Obsidian: a Cache file deleted in the vault comes back; a question kept from an older build is dropped', () async {
      final r = _Rig(SyncKind.obsidian);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Note', body: 'one');
      await r.engine.run();
      const path = 'Journal/2026-10-27 Note.md';
      final text = r.folder.text[path]!;
      // an older build asked "Removed in the folder" and kept the question in its state
      final st = jsonDecode(r.state.readAsStringSync()) as Map<String, dynamic>;
      st['conflicts'] = [
        {'entry': a.id, 'kind': 'removedOutside', 'title': 'Note', 'path': path},
      ];
      r.state.writeAsStringSync(jsonEncode(st));
      r.folder.text.remove(path);
      final eng = r.engine;
      final rep = await eng.run();
      expect((rep.conflicts, rep.written), (0, 1));
      expect(eng.conflicts, isEmpty);
      expect(r.folder.text[path], text);
      expect((await r.nb.entry(a.id))!.body, 'one');
    });

    test('Obsidian: a file with an id Cache has no record of is not read', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      await r.engine.run();
      const stray = '---\ncache_id: 0b6a1f0e-1111-4222-a333-444455556666\nnotebook: Journal\nwhen: 2026-10-27 16:12\n---\nCopied from somewhere.\n';
      r.folder.text['Journal/Stray.md'] = stray;
      final rep = await r.engine.run();
      expect(rep.read, 0);
      expect(await r.nb.entry('0b6a1f0e-1111-4222-a333-444455556666'), isNull);
      expect(r.folder.text['Journal/Stray.md'], stray);
    });

    test('deleted in Cache but changed in the folder: the folder wins', () async {
      final r = _Rig(SyncKind.obsidian);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Note', body: 'one');
      await r.engine.run();
      await r.nb.deleteEntry(a.id);
      const path = 'Journal/2026-10-27 Note.md';
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('one', 'two');
      final rep = await r.engine.run();
      expect(rep.read, 1);
      expect((await r.nb.entry(a.id))!.body, 'two');
    });

    test('a folder that cannot be reached is an error and changes nothing', () async {
      final r = _Rig(SyncKind.obsidian);
      await r.journal();
      r.folder.up = false;
      await expectLater(r.engine.run(), throwsA(isA<FileSystemException>()));
    });
  });

  group('syncing with a Logseq graph', () {
    test('blocks go on their day\'s page after the person\'s own; edits come back; a new day moves the block', () async {
      final r = _Rig(SyncKind.logseq);
      final j = await r.journal();
      const mine = '- My own note\n\t- child\n';
      r.folder.text['journals/2026_10_27.md'] = mine;
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Restocked', body: 'six jugs');
      await r.engine.run();
      final page = r.folder.text['journals/2026_10_27.md']!;
      expect(page, startsWith(mine));
      expect(page, contains('- 16:12 Restocked\n  cache-id:: ${a.id}\n'));
      r.folder.text['journals/2026_10_27.md'] = page.replaceFirst('six jugs', 'eight jugs');
      expect((await r.engine.run()).read, 1);
      expect((await r.nb.entry(a.id))!.body, 'eight jugs');
      expect(r.folder.text['journals/2026_10_27.md'], startsWith(mine));
      final e = (await r.nb.entry(a.id))!;
      await r.nb.saveEntry(id: e.id, notebookId: j.id, occurredAt: '2026-10-28T09:00:00-06:00', title: e.title, body: e.body);
      await r.engine.run();
      expect(r.folder.text['journals/2026_10_27.md'], mine);
      expect(r.folder.text['journals/2026_10_28.md'], contains('cache-id:: ${a.id}'));
    });

    test('Logseq: a block deleted in the graph comes back; a block the person wrote is never read', () async {
      final r = _Rig(SyncKind.logseq);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Restocked', body: 'six jugs');
      await r.engine.run();
      const page = 'journals/2026_10_27.md';
      final withBlock = r.folder.text[page]!;
      expect(withBlock, contains('cache-id:: ${a.id}'));
      // the person deletes Cache's block: it is written back, and the entry stays
      r.folder.text[page] = '';
      var rep = await r.engine.run();
      expect((rep.conflicts, rep.written, rep.deleted), (0, 1, 0));
      expect(r.folder.text[page], contains('cache-id:: ${a.id}'));
      expect((await r.nb.entry(a.id))!.body, 'six jugs');
      // a block of the person's own, even one naming a Cache notebook: left alone, never an entry
      final before = r.store.entries.length;
      final mine = '${r.folder.text[page]}- My own note\n  notebook:: Journal\n';
      r.folder.text[page] = mine;
      rep = await r.engine.run();
      expect(rep.read, 0);
      expect(r.store.entries.length, before);
      expect(r.folder.text[page], mine);
    });

    test('Logseq 2: written for import, never read back', () async {
      final r = _Rig(SyncKind.logseqExport);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Restocked', body: 'six jugs');
      await r.engine.run();
      final page = r.folder.text['journals/2026_10_27.md']!;
      r.folder.text['journals/2026_10_27.md'] = page.replaceFirst('six', 'eight');
      final rep = await r.engine.run();
      expect(rep.read, 0);
      expect((await r.nb.entry(a.id))!.body, 'six jugs');
    });
  });

  group('notebook sync between devices', () {
    test('private notebooks stay home unless included; a second device makes the notebook and its entries', () async {
      final one = _Rig(SyncKind.share, includePrivate: false);
      await one.journal();
      final log = await one.nb.saveNotebook(
          template: 'log',
          def: const NotebookDef(name: 'Generator test', fields: [LogField(label: 'Run time', type: FieldType.number, unit: 'min')], quickAdd: true, sort: NotebookSort.recent));
      await one.nb.saveEntry(notebookId: log.id, occurredAt: '2026-10-25T16:12:00-06:00', values: {'f1': 20}, body: 'Oil fine.');
      final meds = await one.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Medical', fields: [], sort: NotebookSort.recent), private: true);
      await one.nb.saveEntry(notebookId: meds.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Private', body: 'x');
      await one.engine.run();
      expect(one.folder.text.keys.where((k) => k.endsWith('.md')).length, 1);
      final books = jsonDecode(one.folder.text['.cache/notebooks.json']!) as Map;
      final names = [for (final n in books['notebooks'] as List) (n as Map)['def']['name']];
      expect(names, containsAll(['Journal', 'Generator test']));
      expect(names, isNot(contains('Medical')));
      // the other device, with this folder
      final two = _Rig(SyncKind.share, includePrivate: false);
      await two.nb.start();
      two.folder.text.addAll({for (final e in one.folder.text.entries) if (!e.key.split('/').any((s) => s.startsWith('.'))) e.key: e.value});
      final rep = await two.engine.run();
      expect(rep.read, 1);
      final made = two.nb.notebooks.firstWhere((n) => n.name == 'Generator test');
      expect(made.id, log.id);
      final e = (await two.nb.entries(made.id)).single;
      expect(e.values, {'f1': 20});
      expect(e.body, 'Oil fine.');
      // a private notebook with "Include in sync and sharing" goes too
      final again = NotebookSync(notebook: one.nb, kind: SyncKind.share, folder: one.folder, stateFile: one.state, includePrivate: false, privateBooks: {meds.id});
      await again.run();
      expect(one.folder.text.keys.where((k) => k.endsWith('.md')).length, 2);
    });
  });

  group('notebook ids between linked devices', () {
    const hikes = NotebookDef(name: 'Hikes', fields: [], sort: NotebookSort.recent);

    Future<_Rig> device(String id, {String entry = '', String name = 'Hikes', Set<String>? priv}) async {
      final r = _Rig(SyncKind.share, includePrivate: false);
      await r.nb.start();
      final n = await r.nb.saveNotebook(id: id, template: 'notes', def: hikes.copyWith(name: name));
      if (entry.isNotEmpty) await r.nb.saveEntry(id: entry, notebookId: n.id, occurredAt: '2026-11-01T09:00:00-07:00', title: '$name $entry', body: 'Body $entry');
      return r;
    }

    // The sync of linked devices, in turns: both devices run, the share carries, both run again.
    Future<void> rounds(List<_Rig> devices, List<_Link> links, {int n = 3}) async {
      for (var i = 0; i < n; i++) {
        for (final d in devices) {
          await d.engine.run();
        }
        for (final l in links) {
          l.sync();
        }
      }
      for (final d in devices) {
        await d.engine.run();
      }
    }

    List<String> ids(_Rig d, String name) => [for (final n in d.nb.notebooks) if (n.name == name) n.id];
    Future<Set<String>> entryIds(_Rig d, String nbId) async => {for (final e in await d.nb.entries(nbId)) e.id};

    test('a notebook made on one device arrives on the other with the same id and its definition', () async {
      final a = await device('hikes-from-a', entry: 'ea1');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      await rounds([a, b], [_Link(a.folder, b.folder)], n: 2);
      expect(ids(b, 'Hikes'), ['hikes-from-a']);
      expect(await entryIds(b, 'hikes-from-a'), {'ea1'});
      expect(b.folder.text.keys.where((k) => k.contains('conflict')), isEmpty);
    });

    test('the notebook arrives before its id file: the device settles on the id once it comes', () async {
      final a = await device('aaa-hikes', entry: 'ea1');
      await a.engine.run();
      final idText = a.folder.text.remove('Hikes/notebook.json')!;
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      link.sync();
      await b.engine.run();
      expect(ids(b, 'Hikes').single, isNot('aaa-hikes'));
      a.folder.text['Hikes/notebook.json'] = idText;
      await rounds([a, b], [link], n: 2);
      expect(ids(b, 'Hikes'), ['aaa-hikes']);
      expect(await entryIds(b, 'aaa-hikes'), {'ea1'});
      expect(b.reidFile.existsSync(), isFalse);
    });

    test('only a conflict copy of the id file, no notebook.json: the lowest id still wins', () async {
      final a = await device('bbb-hikes', entry: 'ea1');
      await a.engine.run();
      a.folder.text.remove('Hikes/notebook.json');
      a.folder.text['Hikes/notebook (conflict, Field tablet, 2026-11-10 0900).json'] = '{"id":"aaa-hikes"}\n';
      await a.engine.run();
      expect(ids(a, 'Hikes'), ['aaa-hikes']);
      expect(a.folder.text['Hikes/notebook.json'], contains('aaa-hikes'));
      expect(a.folder.text.keys.where((k) => k.contains('conflict')), isEmpty);
      expect(await entryIds(a, 'aaa-hikes'), {'ea1'});
    });

    test('two devices with different ids for one folder converge on the lowest, with entries and references', () async {
      final a = await device('bbb-hikes', entry: 'ea1');
      final b = await device('aaa-hikes', entry: 'eb1');
      final shared = _Included()..ids.add('bbb-hikes');
      a.nb.privateSharing = shared;
      final moves = <String>[];
      a.nb.reids.listen((r) => moves.add('${r.oldId}>${r.newId}'));
      final priv = {'bbb-hikes'};
      final eng = NotebookSync(notebook: a.nb, kind: SyncKind.share, folder: a.folder, stateFile: a.state, includePrivate: false, privateBooks: priv);
      final link = _Link(a.folder, b.folder);
      await eng.run();
      await b.engine.run();
      link.sync();
      await eng.run();
      await b.engine.run();
      link.sync();
      await eng.run();
      await b.engine.run();
      link.sync();
      await eng.run();
      for (final d in [a, b]) {
        expect(ids(d, 'Hikes'), ['aaa-hikes']);
        expect(await entryIds(d, 'aaa-hikes'), {'ea1', 'eb1'});
        expect(d.folder.text.keys.where((k) => k.contains('conflict')), isEmpty);
      }
      expect(moves, ['bbb-hikes>aaa-hikes']);
      expect(shared.ids, {'aaa-hikes'});
      expect(priv, {'aaa-hikes'});
      expect(a.reidFile.existsSync(), isFalse);
      // another round changes nothing
      final idFile = a.folder.text['Hikes/notebook.json'];
      await rounds([a, b], [link], n: 1);
      expect(a.folder.text['Hikes/notebook.json'], idFile);
      expect(ids(a, 'Hikes'), ['aaa-hikes']);
    });

    test('a late joiner with a lower id: every device moves to it', () async {
      final a = await device('mmm-hikes', entry: 'ea1');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final ab = _Link(a.folder, b.folder);
      await rounds([a, b], [ab], n: 2);
      expect(ids(b, 'Hikes'), ['mmm-hikes']);
      final c = await device('aaa-hikes', entry: 'ec1');
      final ac = _Link(a.folder, c.folder);
      await rounds([a, c], [ac], n: 3);
      await rounds([a, b], [ab], n: 3);
      for (final d in [a, b, c]) {
        expect(ids(d, 'Hikes'), ['aaa-hikes']);
      }
      await rounds([a, b, c], [ab, ac], n: 2);
      for (final d in [a, b, c]) {
        expect(await entryIds(d, 'aaa-hikes'), {'ea1', 'ec1'});
      }
    });

    test('concurrent edits on both devices keep one notebook', () async {
      final a = await device('aaa-hikes', entry: 'ea1');
      final b = await device('aaa-hikes', entry: 'eb1');
      final link = _Link(a.folder, b.folder);
      await rounds([a, b], [link]);
      await a.nb.saveEntry(id: 'ea2', notebookId: 'aaa-hikes', occurredAt: '2026-11-02T09:00:00-07:00', title: 'A again');
      await b.nb.saveEntry(id: 'eb2', notebookId: 'aaa-hikes', occurredAt: '2026-11-02T10:00:00-07:00', title: 'B again');
      await rounds([a, b], [link]);
      for (final d in [a, b]) {
        expect(ids(d, 'Hikes'), ['aaa-hikes']);
        expect(await entryIds(d, 'aaa-hikes'), {'ea1', 'eb1', 'ea2', 'eb2'});
      }
    });

    test('a winner held by another notebook here: the device keeps its id and the file is not rewritten back and forth', () async {
      final a = await device('aaa-hikes', entry: 'ea1');
      final b = await device('aaa-hikes', entry: 'eb1');
      // b's Trips folder carries an id that b's own Hikes holds: it cannot be taken
      await b.nb.saveNotebook(id: 'ttt-trips', template: 'notes', def: hikes.copyWith(name: 'Trips'));
      b.folder.text['Trips/notebook.json'] = '{"id":"aaa-hikes"}\n';
      final link = _Link(a.folder, b.folder);
      await rounds([a, b], [link], n: 3);
      final seen = <String>[];
      for (var i = 0; i < 3; i++) {
        await a.engine.run();
        await b.engine.run();
        link.sync();
        seen.add('${b.folder.text['Trips/notebook.json']}|${a.folder.text['Trips/notebook.json']}|${b.folder.text['Hikes/notebook.json']}');
      }
      expect(seen.toSet().length, 1, reason: 'the id files stop changing');
      expect(ids(b, 'Trips'), ['ttt-trips']);
      expect(ids(b, 'Hikes'), ['aaa-hikes']);
      expect(b.folder.text['Trips/notebook.json'], contains('aaa-hikes'), reason: 'never rewritten to a higher id');
    });

    test('names that make one folder get their own folders, and another device reads each notebook from its own folder', () async {
      final a = await device('aaa-one', name: 'Trip: 2026', entry: 'ea1');
      await a.nb.saveNotebook(id: 'bbb-two', template: 'notes', def: hikes.copyWith(name: 'Trip 2026'));
      await a.nb.saveEntry(id: 'ea2', notebookId: 'bbb-two', occurredAt: '2026-11-01T09:00:00-07:00', title: 'Second', body: 'x');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      await a.engine.run();
      final dirs = {for (final k in a.folder.text.keys.where((k) => k.endsWith('notebook.json') && k.startsWith('Trip'))) k.split('/').first};
      expect(dirs.length, 2, reason: 'no two notebooks share a folder');
      await rounds([a, b], [link], n: 3);
      expect(ids(b, 'Trip: 2026'), ['aaa-one']);
      expect(ids(b, 'Trip 2026'), ['bbb-two']);
      expect(await entryIds(b, 'aaa-one'), {'ea1'});
      expect(await entryIds(b, 'bbb-two'), {'ea2'});
    });

    test('a rename carries the id and the files: the other device ends with one notebook, every entry in the new folder, nothing in the old', () async {
      final a = await device('hikes-id', entry: 'ea1');
      await a.nb.saveEntry(id: 'ea2', notebookId: 'hikes-id', occurredAt: '2026-11-02T09:00:00-07:00', title: 'Second hike', body: 'y');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      await rounds([a, b], [link], n: 2);
      expect(ids(b, 'Hikes'), ['hikes-id']);
      expect(await entryIds(b, 'hikes-id'), {'ea1', 'ea2'});
      await a.nb.saveNotebook(id: 'hikes-id', def: hikes.copyWith(name: 'Trips'));
      await a.engine.run();
      expect(a.folder.text['Trips/notebook.json'], contains('hikes-id'));
      expect(a.folder.text.keys.where((k) => k.startsWith('Hikes/')), isEmpty, reason: 'the files moved, the old folder is empty');
      expect(a.folder.text.keys.where((k) => k.startsWith('Trips/') && k.endsWith('.md')).length, 2);
      link.sync();
      final rep = await b.engine.run();
      expect(rep.deleted, 0);
      await rounds([a, b], [link], n: 2);
      for (final d in [a, b]) {
        expect(d.nb.notebooks.where((n) => n.name == 'Hikes' || n.name == 'Trips').map((n) => '${n.name}:${n.id}'), ['Trips:hikes-id']);
        expect(await entryIds(d, 'hikes-id'), {'ea1', 'ea2'});
        expect(d.folder.text.keys.where((k) => k.startsWith('Hikes/')), isEmpty);
        expect(d.folder.text.keys.where((k) => k.startsWith('Trips/') && k.endsWith('.md')).length, 2);
        expect(jsonDecode(d.folder.text['Trips/notebook.json']!)['deleted'], isNull);
      }
      // the next sync is stable: nothing changes on either side
      final before = [{...a.folder.text}, {...b.folder.text}];
      await rounds([a, b], [link], n: 2);
      expect(a.folder.text, before[0]);
      expect(b.folder.text, before[1]);
      expect(ids(b, 'Trips'), ['hikes-id']);
    });

    test('a rename whose new files come many runs late loses no entry on the other device', () async {
      final a = await device('hikes-id', entry: 'ea1');
      await a.nb.saveEntry(id: 'ea2', notebookId: 'hikes-id', occurredAt: '2026-11-02T09:00:00-07:00', title: 'Second hike', body: 'y');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      await rounds([a, b], [link], n: 2);
      await a.nb.saveNotebook(id: 'hikes-id', def: hikes.copyWith(name: 'Trips'));
      await a.engine.run();
      // the old folder's deletes and the new id file come; the new entry files do not
      link.block = (p) => p.startsWith('Trips/') && p.endsWith('.md');
      for (var i = 0; i < 7; i++) {
        link.sync();
        await b.engine.run();
        await a.engine.run();
        expect(await entryIds(b, 'hikes-id'), {'ea1', 'ea2'}, reason: 'run ${i + 1}: kept, not deleted');
        expect(ids(b, 'Trips'), ['hikes-id']);
      }
      expect(a.folder.text.keys.where((k) => k.startsWith('Hikes/')), isEmpty);
      // the files arrive at last: the same entries, one notebook, the old folder empty, stable
      link.block = null;
      await rounds([a, b], [link], n: 2);
      for (final d in [a, b]) {
        expect(d.nb.notebooks.where((n) => n.name == 'Hikes' || n.name == 'Trips').map((n) => n.name), ['Trips']);
        expect(await entryIds(d, 'hikes-id'), {'ea1', 'ea2'});
        expect(d.folder.text.keys.where((k) => k.startsWith('Hikes/')), isEmpty);
        expect(d.folder.text.keys.where((k) => k.startsWith('Trips/') && k.endsWith('.md')).length, 2);
      }
      final before = [{...a.folder.text}, {...b.folder.text}];
      await rounds([a, b], [link], n: 2);
      expect(a.folder.text, before[0]);
      expect(b.folder.text, before[1]);
      // and a delete after that is still a delete
      await a.nb.deleteEntry('ea2');
      await rounds([a, b], [link], n: 3);
      expect(await entryIds(b, 'hikes-id'), {'ea1'});
    });

    test('devices that made the same colliding names with other ids agree on the folders, and converge without a duplicate or a delete', () async {
      Future<_Rig> make(String one, String two, String e1, String e2) async {
        final r = await device(one, name: 'Trip: 2026', entry: e1);
        await r.nb.saveNotebook(id: two, template: 'notes', def: hikes.copyWith(name: 'Trip 2026'));
        await r.nb.saveEntry(id: e2, notebookId: two, occurredAt: '2026-11-01T09:00:00-07:00', title: 'Other $e2', body: 'x');
        return r;
      }

      final a = await make('aaa-one', 'bbb-two', 'ea1', 'ea2');
      final c = await make('ccc-one', 'ddd-two', 'ec1', 'ec2');
      Set<String> dirs(_Rig r) => {for (final k in r.folder.text.keys.where((k) => k.endsWith('notebook.json') && k.startsWith('Trip'))) k.split('/').first};
      await a.engine.run();
      await c.engine.run();
      expect(dirs(a), dirs(c), reason: 'the folders come from the names alone');
      expect(dirs(a).length, 2);
      final link = _Link(a.folder, c.folder);
      await rounds([a, c], [link], n: 4);
      for (final d in [a, c]) {
        expect(d.nb.notebooks.where((n) => n.name.startsWith('Trip')).length, 2);
        expect(ids(d, 'Trip: 2026'), ['aaa-one']);
        expect(ids(d, 'Trip 2026'), ['bbb-two']);
        expect(await entryIds(d, 'aaa-one'), {'ea1', 'ec1'});
        expect(await entryIds(d, 'bbb-two'), {'ea2', 'ec2'});
      }
    });

    test('a deleted notebook leaves a tombstone, kept for a while; the peer deletes its unchanged copy', () async {
      final a = await device('hikes-id', entry: 'ea1');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      await rounds([a, b], [link], n: 2);
      await a.nb.deleteNotebook('hikes-id');
      await a.engine.run();
      final t = jsonDecode(a.folder.text['Hikes/notebook.json']!) as Map;
      expect((t['id'], t['deleted'], t['at']), ('hikes-id', true, DateTime(2026, 10, 29, 17, 2).millisecondsSinceEpoch));
      link.sync();
      await b.engine.run();
      expect(jsonDecode(b.folder.text['Hikes/notebook.json']!)['deleted'], true, reason: 'the peer does not write its own file over the tombstone');
      expect(ids(b, 'Hikes'), isEmpty, reason: 'the tombstone deletes the notebook on the peer, which had not changed it');
      // the tombstone goes after a month
      final later = NotebookSync(notebook: a.nb, kind: SyncKind.share, folder: a.folder, stateFile: a.state, includePrivate: false, clock: () => DateTime(2026, 12, 5));
      await later.run();
      expect(a.folder.text.containsKey('Hikes/notebook.json'), isFalse);
    });

    test('turning a notebook off removes its id file without a tombstone; the other device keeps its copy', () async {
      final a = _Rig(SyncKind.share, includePrivate: false);
      await a.nb.start();
      await a.nb.saveNotebook(id: 'zzz-meds', template: 'notes', def: const NotebookDef(name: 'Medical', fields: [], sort: NotebookSort.recent), private: true);
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      final on = NotebookSync(notebook: a.nb, kind: SyncKind.share, folder: a.folder, stateFile: a.state, includePrivate: false, privateBooks: {'zzz-meds'});
      await on.run();
      link.sync();
      await b.engine.run();
      expect(ids(b, 'Medical'), isEmpty, reason: 'a notebook with no entries is not made by the id file');
      expect(a.folder.text['Medical/notebook.json'], contains('zzz-meds'));
      await a.engine.run();
      expect(a.folder.text.containsKey('Medical/notebook.json'), isFalse);
      expect(ids(a, 'Medical'), ['zzz-meds'], reason: 'the notebook stays here');
      link.sync();
      expect(b.folder.text.containsKey('Medical/notebook.json'), isFalse);
    });

    Future<(_Rig, _Rig, _Link)> linked() async {
      final a = await device('hikes-id', entry: 'ea1');
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      final link = _Link(a.folder, b.folder);
      await rounds([a, b], [link], n: 2);
      expect(ids(b, 'Hikes'), ['hikes-id']);
      return (a, b, link);
    }

    test('delete: a tombstone removes the notebook, with its entries, from the peer; nothing comes back', () async {
      final (a, b, link) = await linked();
      await a.nb.deleteNotebook('hikes-id');
      await rounds([a, b], [link]);
      expect(ids(b, 'Hikes'), isEmpty);
      expect(ids(a, 'Hikes'), isEmpty);
      expect(jsonDecode(a.folder.text['Hikes/notebook.json']!)['deleted'], true);
      expect(jsonDecode(b.folder.text['Hikes/notebook.json']!)['deleted'], true);
      expect(b.folder.text.keys.where((k) => k.startsWith('Hikes/') && k.endsWith('.md')), isEmpty);
    });

    test('delete: a file of the deleted notebook that arrives late does not make it again', () async {
      final (a, b, link) = await linked();
      final path = b.folder.text.keys.firstWhere((k) => k.startsWith('Hikes/') && k.endsWith('.md'));
      final text = b.folder.text[path]!;
      await a.nb.deleteNotebook('hikes-id');
      await rounds([a, b], [link]);
      b.folder.text[path] = text;
      await b.engine.run();
      await b.engine.run();
      expect(ids(b, 'Hikes'), isEmpty);
    });

    test('delete: a notebook changed on the peer wins over the tombstone; it is kept, the folder written again, and it comes back', () async {
      final (a, b, link) = await linked();
      await a.nb.deleteNotebook('hikes-id');
      await a.engine.run();
      await b.nb.saveEntry(id: 'eb2', notebookId: 'hikes-id', occurredAt: '2026-11-02T09:00:00-07:00', title: 'B only');
      link.sync();
      await b.engine.run();
      expect(ids(b, 'Hikes'), ['hikes-id']);
      expect(await entryIds(b, 'hikes-id'), {'ea1', 'eb2'});
      expect(jsonDecode(b.folder.text['Hikes/notebook.json']!)['deleted'], isNot(true));
      await rounds([a, b], [link]);
      expect(await entryIds(a, 'hikes-id'), {'ea1', 'eb2'});
      expect(await entryIds(b, 'hikes-id'), {'ea1', 'eb2'});
    });

    test('delete: a private notebook that is not included is never deleted by a tombstone', () async {
      final b = _Rig(SyncKind.share, includePrivate: false);
      await b.nb.start();
      await b.nb.saveNotebook(id: 'zzz-meds', template: 'notes', def: const NotebookDef(name: 'Medical', fields: [], sort: NotebookSort.recent), private: true);
      await b.nb.saveEntry(id: 'em1', notebookId: 'zzz-meds', occurredAt: '2026-11-01T09:00:00-07:00', title: 'Private', body: 'x');
      await NotebookSync(notebook: b.nb, kind: SyncKind.share, folder: b.folder, stateFile: b.state, includePrivate: false, privateBooks: {'zzz-meds'}).run();
      b.folder.text.removeWhere((k, _) => k.startsWith('Medical/'));
      b.folder.text['Medical/notebook.json'] = '{"id":"zzz-meds","deleted":true,"at":1794290000000}\n';
      await b.engine.run();
      await b.engine.run();
      expect(ids(b, 'Medical'), ['zzz-meds']);
      expect(await entryIds(b, 'zzz-meds'), {'em1'});
    });

    test('unshare: the id file gone with no tombstone keeps the notebook and its entries on the peer', () async {
      final (a, b, link) = await linked();
      b.folder.text.removeWhere((k, _) => k.startsWith('Hikes/'));
      final rep = await b.engine.run();
      expect(rep.deleted, 0);
      expect(ids(b, 'Hikes'), ['hikes-id']);
      expect(await entryIds(b, 'hikes-id'), {'ea1'});
      await b.engine.run();
      expect(await entryIds(b, 'hikes-id'), {'ea1'});
      expect(a.nb.notebooks.any((n) => n.id == 'hikes-id'), isTrue);
      expect(link.a, a.folder);
    });

    test('rename: the same id in a new folder moves the notebook on the peer, with no delete and no copy', () async {
      final (a, b, link) = await linked();
      await a.nb.saveNotebook(id: 'hikes-id', def: hikes.copyWith(name: 'Trails'));
      await rounds([a, b], [link]);
      for (final d in [a, b]) {
        expect(d.nb.notebooks.where((n) => n.id == 'hikes-id').map((n) => n.name), ['Trails']);
        expect(ids(d, 'Hikes'), isEmpty);
        expect(await entryIds(d, 'hikes-id'), {'ea1'});
        expect(d.folder.text.keys.where((k) => k.startsWith('Hikes/') && k.endsWith('.md')), isEmpty);
      }
    });

    test('delete, then the same name made again: a new notebook, not the old one back', () async {
      final (a, b, link) = await linked();
      await a.nb.deleteNotebook('hikes-id');
      await rounds([a, b], [link]);
      await a.nb.saveNotebook(id: 'bbb-hikes', template: 'notes', def: hikes);
      await a.nb.saveEntry(id: 'ea9', notebookId: 'bbb-hikes', occurredAt: '2026-11-05T09:00:00-07:00', title: 'Hikes ea9');
      await rounds([a, b], [link]);
      for (final d in [a, b]) {
        expect(ids(d, 'Hikes'), ['bbb-hikes']);
        expect(await entryIds(d, 'bbb-hikes'), {'ea9'});
      }
    });

    test('delete: the decision point can keep a notebook that was deleted elsewhere', () async {
      final (a, b, link) = await linked();
      await a.nb.deleteNotebook('hikes-id');
      await a.engine.run();
      link.sync();
      await _KeepEngine(b).run();
      expect(ids(b, 'Hikes'), ['hikes-id']);
      expect(await entryIds(b, 'hikes-id'), {'ea1'});
    });

    test('a private notebook that is not included keeps its id and writes nothing', () async {
      final a = _Rig(SyncKind.share, includePrivate: false);
      await a.nb.start();
      final meds = await a.nb.saveNotebook(id: 'zzz-meds', template: 'notes', def: const NotebookDef(name: 'Medical', fields: [], sort: NotebookSort.recent), private: true);
      await a.nb.saveEntry(id: 'em1', notebookId: meds.id, occurredAt: '2026-11-01T09:00:00-07:00', title: 'Private', body: 'x');
      a.folder.text['Medical/notebook.json'] = '{"id":"aaa-meds"}\n';
      await a.engine.run();
      expect(ids(a, 'Medical'), ['zzz-meds']);
      expect(a.folder.text['Medical/notebook.json'], contains('aaa-meds'));
      expect(a.folder.text.keys.where((k) => k.endsWith('.md') && k.startsWith('Medical/')), isEmpty);
      final again = NotebookSync(notebook: a.nb, kind: SyncKind.share, folder: a.folder, stateFile: a.state, includePrivate: false, privateBooks: {'zzz-meds'});
      await again.run();
      expect(ids(a, 'Medical'), ['aaa-meds']);
      expect(await entryIds(a, 'aaa-meds'), {'em1'});
    });
  });

  group('a notebook id change is a journaled, resumable job', () {
    const hikes = NotebookDef(name: 'Hikes', fields: [LogField(label: 'Distance', type: FieldType.number, unit: 'mi')], sort: NotebookSort.recent);

    // A device with a Hikes notebook (id 'bbb-hikes'), a field-name state file for the share and for an Obsidian folder, a
    // shortcut and a private-sharing choice, all under the old id; and a share that carries 'aaa-hikes' for it.
    Future<({_Rig rig, _Included shared, List<String> shortcuts, File obsidian, int Function() calls})> build(Set<int> failAt) async {
      final r = _Rig(SyncKind.share, includePrivate: false);
      await r.nb.start();
      await r.nb.saveNotebook(id: 'bbb-hikes', template: 'log', def: hikes);
      await r.nb.saveEntry(id: 'e1', notebookId: 'bbb-hikes', occurredAt: '2026-11-01T09:00:00-07:00', values: {'f1': 4});
      final shared = _Included()..ids.add('bbb-hikes');
      r.nb.privateSharing = shared;
      final shortcuts = <String>['bbb-hikes'];
      final obsidian = File('${r.state.parent.path}/obsidian.json')..writeAsStringSync(jsonEncode({'props': {'bbb-hikes': {'f1': 'distance'}}}));
      r.state.writeAsStringSync(jsonEncode({'props': {'bbb-hikes': {'f1': 'distance'}}}));
      var n = 0;
      Future<void> step(String name, Future<void> Function(String, String) f) async {
        r.nb.reidSteps[name] = (o, w) async {
          if (failAt.contains(++n)) throw StateError('killed in $name');
          await f(o, w);
        };
      }

      await step('shortcuts', (o, w) async => shortcuts.replaceRange(0, shortcuts.length, [for (final x in shortcuts) x == o ? w : x]));
      await step('field names', (o, w) async {
        await NotebookSync.moveProps(r.state, o, w);
        await NotebookSync.moveProps(obsidian, o, w);
      });
      return (rig: r, shared: shared, shortcuts: shortcuts, obsidian: obsidian, calls: () => n);
    }

    for (final kill in [0, 1, 2, 3]) {
      test('killed at step ${kill + 1} (${['shortcuts', 'field names', 'before any step', 'private sharing'][kill]}), a fresh start replays the journal and finishes it with everything intact', () async {
        final d = await build(kill >= 2 ? {} : {kill + 1});
        if (kill == 2) d.rig.store.failNext = 'io';
        if (kill == 3) d.rig.nb.privateSharing = _Flaky(d.shared);
        await expectLater(d.rig.nb.reidNotebook('bbb-hikes', 'aaa-hikes'), throwsA(anything));
        expect(d.rig.reidFile.existsSync(), isTrue, reason: 'the journal stays until every step saved');
        final j = jsonDecode(d.rig.reidFile.readAsStringSync()) as Map;
        expect((j['old'], j['new']), ('bbb-hikes', 'aaa-hikes'));
        // the next start: a new NotebookState on the same core and journal replays it before anything syncs
        final again = fakeNotebook(d.rig.store)..reidJournal = d.rig.reidFile;
        again.privateSharing = d.shared;
        again.reidSteps.addAll(d.rig.nb.reidSteps);
        await again.start();
        await again.replayReid();
        expect(d.rig.reidFile.existsSync(), isFalse);
        expect(again.notebooks.where((n) => n.name == 'Hikes').map((n) => n.id), ['aaa-hikes']);
        expect((await again.entries('aaa-hikes')).map((e) => e.id), ['e1']);
        expect(d.shared.ids, {'aaa-hikes'});
        expect(d.shortcuts, ['aaa-hikes']);
        for (final f in [d.rig.state, d.obsidian]) {
          final props = (jsonDecode(f.readAsStringSync()) as Map)['props'] as Map;
          expect(props.keys, ['aaa-hikes'], reason: f.path);
          expect(props['aaa-hikes'], {'f1': 'distance'});
        }
        // a second replay does nothing
        await again.replayReid();
        expect(again.notebooks.where((n) => n.name == 'Hikes').length, 1);
      });
    }

    test('a field with a renamed label still reads and writes under the same property name after a re-id', () async {
      final d = await build({});
      await d.rig.nb.reidNotebook('bbb-hikes', 'aaa-hikes');
      // the label is renamed after the re-id; the property name the file already uses stays
      final book = d.rig.nb.notebook('aaa-hikes')!;
      final f = book.def.fields.first;
      await d.rig.nb.saveNotebook(id: 'aaa-hikes', def: book.def.copyWith(fields: [LogField(fid: f.fid, label: 'Miles walked', type: f.type, unit: f.unit)]));
      final eng = NotebookSync(notebook: d.rig.nb, kind: SyncKind.share, folder: d.rig.folder, stateFile: d.rig.state, includePrivate: false);
      await eng.run();
      final file = d.rig.folder.text.entries.firstWhere((e) => e.key.endsWith('.md')).value;
      expect(file, contains('distance: 4'), reason: 'written under the name the state file kept, not "miles_walked"');
      expect(file, isNot(contains('miles_walked')));
    });

    test('Obsidian and Logseq connections keep their field names across a re-id', () async {
      final d = await build({});
      final logseq = File('${d.rig.state.parent.path}/logseq.json')..writeAsStringSync(jsonEncode({'props': {'bbb-hikes': {'f1': 'distance'}, 'other': {'f9': 'x'}}}));
      d.rig.nb.reidSteps['logseq'] = (o, w) => NotebookSync.moveProps(logseq, o, w);
      await d.rig.nb.reidNotebook('bbb-hikes', 'aaa-hikes');
      final props = (jsonDecode(logseq.readAsStringSync()) as Map)['props'] as Map;
      expect(props['aaa-hikes'], {'f1': 'distance'});
      expect(props['other'], {'f9': 'x'});
      expect(props.containsKey('bbb-hikes'), isFalse);
    });

    test('Home shortcuts follow a notebook to its new id', () async {
      final dir = Directory.systemTemp.createTempSync('cache-layout-');
      final layout = LayoutState(settingsDirOverride: dir);
      await layout.init();
      layout.addShortcut(Shortcut.notebook(id: 'bbb-hikes', name: 'Hikes'));
      layout.addShortcut(Shortcut.notebook(id: 'ccc-other', name: 'Other'));
      layout.renameNotebook('bbb-hikes', 'aaa-hikes');
      expect([for (final s in layout.shortcuts) s.notebookId], ['aaa-hikes', 'ccc-other']);
      final again = LayoutState(settingsDirOverride: dir);
      await again.init();
      expect([for (final s in again.shortcuts) s.notebookId], ['aaa-hikes', 'ccc-other'], reason: 'saved');
    });

    test('the saved-places notebook keeps its link when its id changes', () async {
      final r = _Rig(SyncKind.share);
      await r.nb.start();
      final sp = await r.nb.ensureSavedPlaces();
      await r.nb.reidNotebook(sp.id, 'aaa-places');
      expect(r.nb.savedPlaces?.id, 'aaa-places');
    });
  });

  group('the app PIN', () {
    test('set, checked, five wrong tries wait, removed; only a salted hash is stored', () async {
      var now = DateTime(2026, 10, 30, 9);
      final store = MemoryTokenStore();
      final pin = AppPin(store, iterations: 50, clock: () => now);
      await pin.init();
      expect((pin.isSet, pin.locked), (false, false));
      expect(AppPin.valid('12'), isFalse);
      expect(AppPin.valid('123456789'), isFalse);
      await pin.set('2468');
      expect(store.values['app.pin'], isNot(contains('2468')));
      final again = AppPin(store, iterations: 50, clock: () => now);
      await again.init();
      expect(again.locked, isTrue);
      expect(await again.check('1111'), isFalse);
      expect(again.locked, isTrue);
      expect(await again.check('2468'), isTrue);
      expect(again.locked, isFalse);
      for (var i = 0; i < AppPin.triesBeforeWait; i++) {
        await again.check('0000');
      }
      expect(again.waitLeft, isNotNull);
      expect(await again.check('2468'), isFalse, reason: 'waiting');
      now = now.add(AppPin.wait + const Duration(seconds: 1));
      expect(await again.check('2468'), isTrue);
      await again.remove();
      expect(store.values, isEmpty);
    });
  });

  group('screens', () {
    testWidgets('Connections: Obsidian and Logseq only where folders can be kept; a connected folder shows its status', (tester) async {
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store);
      final mem = MemFolder();
      final dir = Directory.systemTemp.createTempSync('cache-conn-');
      final c = NotebookConnections(notebook: nb, dir: () async => dir, folderFor: (_) => mem);
      await tester.runAsync(c.init);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: ConnectionsScreen(connections: c, folders: false)));
      expect(find.text('Obsidian'), findsNothing);
      expect(find.text('Your other devices'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(CacheThemeId.dark), home: ConnectionsScreen(connections: c, pickFolder: () async => (path: 'content://tree/primary%3ADocuments%2FVault', display: 'Vault'))));
      expect(find.text('Obsidian'), findsOneWidget);
      expect(find.text('Logseq'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(c.target(SyncKind.obsidian)?.path, 'content://tree/primary%3ADocuments%2FVault');
      expect(find.text('Vault'), findsOneWidget);
      expect(find.byKey(const ValueKey('status-obsidian')), findsOneWidget);
      expect(SafFolder.treeName('content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FVault'), 'Vault');
    });

    testWidgets('a private notebook\'s edit page offers "Include in sync and sharing", off by default', (tester) async {
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store)..privateSharing = _Included();
      await tester.runAsync(nb.start);
      final notes = await tester.runAsync(() => nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Medical', fields: [], sort: NotebookSort.recent)));
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: NotebookEditor(notebook: nb, existing: notes)));
      expect(find.byKey(const ValueKey('notebook-include')), findsNothing, reason: 'not private');
      await tester.tap(find.byKey(const ValueKey('notebook-private')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('notebook-include'))).value, isFalse);
      await tester.tap(find.byKey(const ValueKey('notebook-include')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('notebook-save')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect((nb.privateSharing! as _Included).ids, {notes!.id});
    });

    testWidgets('1.0 asks for no PIN: a PIN stored by an earlier build is treated as off, and Notebooks offers no App PIN', (tester) async {
      final store = MemoryTokenStore();
      final pin = AppPin(store, iterations: 10);
      await tester.runAsync(() async {
        await pin.set('2468');
        await pin.init();
      });
      expect(kAppLockEnabled, isFalse);
      expect(appLockAsked(pin), isFalse, reason: 'a stored PIN is off in 1.0');
      final nb = fakeNotebook(FakeNotebookBackend());
      await tester.runAsync(nb.start);
      final deps = NotebookDeps(notebook: nb, places: PlaceChoices.none, pin: kAppLockEnabled ? pin : null);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: NotebooksScreen(deps: deps)));
      await tester.pump();
      expect(find.byType(PinLockScreen), findsNothing);
      expect(find.byKey(const ValueKey('notebooks-menu')), findsNothing);
      expect(find.text('App PIN'), findsNothing);
    });

    testWidgets('the lock screen: the right PIN opens Cache, a wrong one says so', (tester) async {
      final store = MemoryTokenStore();
      final pin = AppPin(store, iterations: 10);
      await tester.runAsync(() async {
        await pin.set('2468');
        await pin.init();
      });
      expect(pin.locked, isTrue);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: PinLockScreen(pin: pin)));
      Future<void> type(String digits) async {
        for (final d in digits.split('')) {
          await tester.tap(find.byKey(ValueKey('pin-$d')));
        }
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('pin-ok')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();
      }

      await type('1111');
      expect(find.text('Wrong PIN'), findsOneWidget);
      await type('2468');
      expect(pin.locked, isFalse);
    });
  });
}

/// Private sharing that fails once when told of a notebook id change (the app killed there).
class _Flaky implements PrivateSharing {
  _Flaky(this.inner);

  final _Included inner;
  bool failed = false;

  @override
  bool included(String notebookId) => inner.included(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) => inner.setIncluded(notebookId, on);

  @override
  Future<void> notebookReid(String oldId, String newId) async {
    if (!failed) {
      failed = true;
      throw StateError('killed in private sharing');
    }
    await inner.notebookReid(oldId, newId);
  }
}

class _Included implements PrivateSharing {
  final Set<String> ids = {};

  @override
  Future<void> notebookReid(String oldId, String newId) async {
    if (ids.remove(oldId)) ids.add(newId);
  }

  @override
  bool included(String notebookId) => ids.contains(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) async {
    if (on) {
      ids.add(notebookId);
    } else {
      ids.remove(notebookId);
    }
  }
}

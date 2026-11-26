import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/templates.dart';
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

/// The templates and starter logs the app ships (the engine loads them from the asset bundle; a test reads the files).
Templates builtInTemplates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

class _Rig {
  _Rig(this.kind, {this.includePrivate = true, bool ownMedia = false}) : media = ownMedia ? Directory.systemTemp.createTempSync('cache-nbsync-media-') : null {
    nb = fakeNotebook(store, media: media);
  }

  /// This device's own photo files (the fake does what the core does with them); null: the folder every test shares.
  final Directory? media;

  final SyncKind kind;
  final bool includePrivate;
  final FakeNotebookBackend store = FakeNotebookBackend();
  late final NotebookState nb;
  final MemFolder folder = MemFolder();
  final File state = File('${Directory.systemTemp.createTempSync('cache-nbsync-').path}/state.json');

  NotebookSync get engine => NotebookSync(
      notebook: nb, kind: kind, folder: folder, stateFile: state, includePrivate: includePrivate, clock: () => DateTime(2026, 10, 29, 17, 2), templates: () async => builtInTemplates());

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
      // changed in both, the same words: the other version is kept as a new entry (nothing is asked, nothing goes to Conflicts/)
      e = (await r.nb.entry(a.id))!;
      await r.nb.saveEntry(id: e.id, notebookId: j.id, occurredAt: e.occurredAt, title: e.title, body: 'Swapped eleven jugs at the garage.');
      r.folder.text[path] = r.folder.text[path]!.replaceFirst('ten', 'twelve');
      final eng = r.engine;
      rep = await eng.run();
      expect(rep.conflicts, 0);
      expect(rep.keptAsTwo, ['Water cache restocked']);
      expect(eng.conflicts, isEmpty);
      final two = [for (final x in await r.nb.entries(j.id)) if ((x.title ?? '').startsWith('Water cache restocked')) x];
      expect(two.map((x) => x.title).toSet(), {'Water cache restocked', 'Water cache restocked (other version)'});
      expect(two.map((x) => x.body).toSet(), {'Swapped eleven jugs at the garage.', 'Swapped twelve jugs at the garage.'});
      final copyFile = r.folder.text.entries.where((x) => x.value.contains('title: Water cache restocked (other version)')).single;
      expect(copyFile.value, contains('cache_id: ${two.firstWhere((x) => x.id != a.id).id}'));
      expect(r.folder.text.keys.where((k) => k.startsWith('Conflicts/')), isEmpty);
      expect((await r.engine.run()).conflicts, 0);
      expect((await r.engine.run()).written, 0);
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

    test('Logseq: the same words changed in both places keeps the other version as a new entry on its day\'s page; nothing goes to Cache conflicts', () async {
      final r = _Rig(SyncKind.logseq);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Restocked', body: 'six jugs');
      await r.engine.run();
      const page = 'journals/2026_10_27.md';
      final e = (await r.nb.entry(a.id))!;
      await r.nb.saveEntry(id: e.id, notebookId: j.id, occurredAt: e.occurredAt, title: e.title, body: 'eight jugs');
      r.folder.text[page] = r.folder.text[page]!.replaceFirst('six jugs', 'ten jugs');
      final eng = r.engine;
      final rep = await eng.run();
      expect(rep.conflicts, 0);
      expect(rep.keptAsTwo, ['Restocked']);
      expect(eng.conflicts, isEmpty);
      final all = await r.nb.entries(j.id);
      expect(all.map((x) => x.title).toSet(), {'Restocked', 'Restocked (other version)'});
      expect(all.map((x) => x.body).toSet(), {'eight jugs', 'ten jugs'});
      final copy = all.firstWhere((x) => x.id != a.id);
      expect(r.folder.text[page], allOf(contains('cache-id:: ${a.id}'), contains('cache-id:: ${copy.id}'), contains('Restocked (other version)')));
      expect(r.folder.text.keys, isNot(contains('pages/Cache conflicts.md')));
      final again = await r.engine.run();
      expect((again.written, again.read, again.conflicts), (0, 0, 0));
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
      two.folder.text.addAll(one.folder.text);
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

  group('a pass never takes a share file out just because its entry is not included on this device', () {
    // Devices of one share folder: each has its own store and state, all see the same folder.
    final folder = MemFolder();
    Future<SyncReport> pass(_Rig r, {Set<String> privateBooks = const {}}) =>
        NotebookSync(notebook: r.nb, kind: SyncKind.share, folder: folder, stateFile: r.state, includePrivate: false, privateBooks: privateBooks, clock: () => DateTime(2026, 10, 29, 17, 2), templates: () async => builtInTemplates())
            .run();
    int mdFiles() => folder.text.keys.where((k) => k.endsWith('.md')).length;

    setUp(() {
      folder.text.clear();
      folder.bytes.clear();
    });

    test('a private notebook that a phone switched on stays in the share and on the phone: a server-like device that has it not included does not take its entry back out', () async {
      final phone = _Rig(SyncKind.share, includePrivate: false);
      await phone.journal();
      final health = await phone.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Health', fields: [], sort: NotebookSort.recent), private: true);
      final bp = await phone.nb.saveEntry(notebookId: health.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Blood pressure', body: '120 over 80', private: true);
      await pass(phone, privateBooks: {health.id});
      expect(mdFiles(), 1, reason: 'the phone sent it');
      final server = _Rig(SyncKind.share, includePrivate: false);
      await server.nb.start();
      await pass(server);
      expect(server.nb.notebooks.map((n) => n.name), contains('Health'));
      expect(mdFiles(), 1, reason: 'the server\'s pass left the file in the share');
      await pass(server);
      await pass(server);
      expect(mdFiles(), 1);
      await pass(phone, privateBooks: {health.id});
      expect((await phone.nb.entries(health.id)).map((e) => e.id), [bp.id], reason: 'the phone still has its entry');
    });

    test('phone to phone: a second phone that has not switched the private notebook on does not remove its file either', () async {
      final a = _Rig(SyncKind.share, includePrivate: false);
      final b = _Rig(SyncKind.share, includePrivate: false);
      await a.journal();
      await b.journal();
      final health = await a.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Health', fields: [], sort: NotebookSort.recent), private: true);
      final e = await a.nb.saveEntry(notebookId: health.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Blood pressure', body: '120 over 80', private: true);
      await pass(a, privateBooks: {health.id});
      await pass(b);
      await pass(b);
      expect(mdFiles(), 1, reason: 'b did not take the file out');
      await pass(a, privateBooks: {health.id});
      expect((await a.nb.entries(health.id)).map((x) => x.id), [e.id]);
    });

    test('a real delete still propagates, for a public entry and for an included private notebook', () async {
      final a = _Rig(SyncKind.share, includePrivate: false);
      final b = _Rig(SyncKind.share, includePrivate: false);
      final ja = await a.journal();
      await b.journal();
      final health = await a.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Health', fields: [], sort: NotebookSort.recent), private: true);
      final pub = await a.nb.saveEntry(notebookId: ja.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Public', body: 'x');
      final priv = await a.nb.saveEntry(notebookId: health.id, occurredAt: '2026-10-27T17:12:00-06:00', title: 'Private', body: 'y', private: true);
      final both = {health.id};
      await pass(a, privateBooks: both);
      await pass(b, privateBooks: both);
      expect(await b.nb.entry(pub.id), isNotNull);
      expect(await b.nb.entry(priv.id), isNotNull);
      await pass(a, privateBooks: both);
      await a.nb.deleteEntry(pub.id);
      await a.nb.deleteEntry(priv.id);
      await pass(a, privateBooks: both);
      expect(mdFiles(), 0, reason: 'the deletes took the files out');
      await pass(b, privateBooks: both);
      expect(await b.nb.entry(pub.id), isNull);
      expect(await b.nb.entry(priv.id), isNull);
    });
  });

  group('an emptied share folder never deletes entries from the store', () {
    // The share folder is emptied (or removed and made again) while the engine's state file is kept: the entries are still
    // here, so the next pass writes them back; it must never read the missing files as "deleted on the other device".
    Future<(_Rig, String, String)> sent() async {
      final r = _Rig(SyncKind.share);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'First', body: 'one');
      final b = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T17:12:00-06:00', title: 'Second', body: 'two');
      await r.engine.run();
      expect(r.folder.text.keys.where((k) => k.endsWith('.md')).length, 2, reason: 'the first pass wrote both files');
      expect(r.state.existsSync(), isTrue, reason: 'the state file is kept');
      return (r, a.id, b.id);
    }

    test('every file taken out of the share folder, state file kept: both entries stay in the store', () async {
      final (r, a, b) = await sent();
      r.folder.text.clear();
      r.folder.bytes.clear();
      await r.engine.run();
      expect(await r.nb.entry(a), isNotNull, reason: 'First is still in the store');
      expect(await r.nb.entry(b), isNotNull, reason: 'Second is still in the store');
    });

    test('the share folder deleted and made again empty, state file kept: both entries stay in the store', () async {
      final (r, a, b) = await sent();
      final fresh = MemFolder();
      await NotebookSync(notebook: r.nb, kind: SyncKind.share, folder: fresh, stateFile: r.state, includePrivate: true, clock: () => DateTime(2026, 10, 29, 17, 2), templates: () async => builtInTemplates()).run();
      expect(await r.nb.entry(a), isNotNull, reason: 'First is still in the store');
      expect(await r.nb.entry(b), isNotNull, reason: 'Second is still in the store');
    });
  });

  group('a file going missing never deletes an entry; only a delete made in Cache does, by a marker that travels', () {
    bool hidden(String p) => p.split('/').any((c) => c.startsWith('.'));

    /// What the share sync does: the other folder becomes this one's files (files taken away here are taken away there).
    void mirror(_Rig from, _Rig to) {
      to.folder.text.removeWhere((k, _) => !hidden(k) && !from.folder.text.containsKey(k));
      to.folder.bytes.removeWhere((k, _) => !hidden(k) && !from.folder.bytes.containsKey(k));
      for (final e in from.folder.text.entries) {
        if (!hidden(e.key)) to.folder.text[e.key] = e.value;
      }
      for (final e in from.folder.bytes.entries) {
        if (!hidden(e.key)) to.folder.bytes[e.key] = e.value;
      }
    }

    List<String> mds(_Rig r) => [for (final k in r.folder.text.keys) if (k.endsWith('.md')) k]..sort();
    List<String> marks(_Rig r) => [for (final k in r.folder.text.keys) if (k.startsWith('_deleted/')) k]..sort();

    /// Both devices have the entries, synced both ways.
    Future<(_Rig, _Rig, String, List<String>)> pair({int n = 2}) async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      final ja = await a.journal();
      await b.journal();
      final ids = <String>[];
      for (var i = 0; i < n; i++) {
        ids.add((await a.nb.saveEntry(notebookId: ja.id, occurredAt: '2026-10-27T1$i:12:00-06:00', title: 'Entry $i', body: 'body $i')).id);
      }
      await a.engine.run();
      mirror(a, b);
      await b.engine.run();
      mirror(b, a);
      await a.engine.run();
      for (final id in ids) {
        expect(await b.nb.entry(id), isNotNull, reason: 'the entry reached the other device');
      }
      return (a, b, ja.id, ids);
    }

    test('one file missing, no marker: it is written again from the store, nothing is deleted', () async {
      final r = _Rig(SyncKind.share);
      final j = await r.journal();
      final a = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'First', body: 'one');
      final b = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T17:12:00-06:00', title: 'Second', body: 'two');
      await r.engine.run();
      final gone = mds(r).first;
      r.folder.text.remove(gone);
      final rep = await r.engine.run();
      expect(rep.deleted, 0);
      expect(rep.written, 1);
      expect(mds(r), hasLength(2), reason: 'the file is written again');
      expect(r.folder.text.containsKey(gone), isTrue);
      expect(await r.nb.entry(a.id), isNotNull);
      expect(await r.nb.entry(b.id), isNotNull);
      expect(marks(r), isEmpty);
    });

    test('an emptied folder: both files are written again and both entries stay', () async {
      final r = _Rig(SyncKind.share);
      final j = await r.journal();
      await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'First', body: 'one');
      await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T17:12:00-06:00', title: 'Second', body: 'two');
      await r.engine.run();
      r.folder.text.clear();
      r.folder.bytes.clear();
      final rep = await r.engine.run();
      expect(rep.deleted, 0);
      expect(mds(r), hasLength(2));
      expect(await r.nb.entries(j.id), hasLength(2));
    });

    test('a delete made in Cache writes the marker and removes the file; the other device deletes the entry, and it stays deleted', () async {
      final (a, b, nb, ids) = await pair();
      await a.nb.deleteEntry(ids[0]);
      await a.engine.run();
      expect(marks(a), ['_deleted/${ids[0]}.json']);
      final m = jsonDecode(a.folder.text['_deleted/${ids[0]}.json']!) as Map;
      expect(m['id'], ids[0]);
      expect(m['at'], isA<int>());
      expect(mds(a), hasLength(1), reason: 'the entry\'s file is removed');
      mirror(a, b);
      final rb = await b.engine.run();
      expect(rb.deleted, 1);
      expect(await b.nb.entry(ids[0]), isNull);
      expect(await b.nb.entry(ids[1]), isNotNull);
      for (var i = 0; i < 3; i++) {
        mirror(b, a);
        await a.engine.run();
        mirror(a, b);
        await b.engine.run();
      }
      for (final r in [a, b]) {
        expect(await r.nb.entry(ids[0]), isNull, reason: 'stays deleted');
        expect(await r.nb.entries(nb).then((l) => l.length), 1);
        expect(mds(r), hasLength(1));
        expect(marks(r), ['_deleted/${ids[0]}.json'], reason: 'markers are kept');
      }
    });

    test('a wipe that also removes _deleted/: nothing is deleted on either device', () async {
      final (a, b, nb, ids) = await pair(n: 3);
      await a.nb.deleteEntry(ids[2]);
      await a.engine.run();
      mirror(a, b);
      await b.engine.run();
      expect(await b.nb.entry(ids[2]), isNull);
      a.folder.text.clear();
      a.folder.bytes.clear();
      final ra = await a.engine.run();
      expect(ra.deleted, 0);
      mirror(a, b);
      final rb = await b.engine.run();
      expect(rb.deleted, 0);
      mirror(b, a);
      await a.engine.run();
      for (final r in [a, b]) {
        expect(await r.nb.entries(nb).then((l) => l.map((e) => e.id).toSet()), {ids[0], ids[1]});
        expect(mds(r), hasLength(2));
      }
    });

    test('one device edits while the other deletes: the file wins, the entry is on both, and the marker is removed', () async {
      final (a, b, nb, ids) = await pair(n: 1);
      await a.nb.deleteEntry(ids[0]);
      await a.engine.run();
      // the other device's file was edited (it arrives changed) and the marker reaches it
      final path = mds(b).firstWhere((k) => b.folder.text[k]!.contains('body 0'));
      a.folder.text[path] = b.folder.text[path] = b.folder.text[path]!.replaceFirst('body 0', 'edited on B');
      b.folder.text['_deleted/${ids[0]}.json'] = a.folder.text['_deleted/${ids[0]}.json']!;
      await a.engine.run();
      await b.engine.run();
      mirror(b, a);
      await a.engine.run();
      for (final r in [a, b]) {
        expect((await r.nb.entry(ids[0]))?.body, 'edited on B');
        expect(marks(r), isEmpty, reason: 'the marker is removed');
      }
    });

    test('i: the marker reaches the other device before the file removal: the entry is deleted there, the marker stays, and X is gone on both after more passes', () async {
      final (a, b, nb, ids) = await pair();
      final mk = '_deleted/${ids[0]}.json';
      await a.nb.deleteEntry(ids[0]);
      await a.engine.run();
      // only the marker has arrived on B; X's file is still there
      b.folder.text[mk] = a.folder.text[mk]!;
      expect(mds(b), hasLength(2));
      final rb = await b.engine.run();
      expect(rb.deleted, 1);
      expect(await b.nb.entry(ids[0]), isNull, reason: 'the marker is the pending delete');
      expect(marks(b), [mk], reason: 'the marker stays');
      mirror(b, a);
      await a.engine.run();
      mirror(a, b); // the file removal arrives as well
      for (var k = 0; k < 3; k++) {
        await b.engine.run();
        mirror(b, a);
        await a.engine.run();
        mirror(a, b);
      }
      for (final r in [a, b]) {
        expect(await r.nb.entry(ids[0]), isNull, reason: 'X is gone');
        expect(await r.nb.entry(ids[1]), isNotNull);
        expect(mds(r), hasLength(1));
        expect(marks(r), [mk], reason: 'the marker is still in _deleted/');
      }
    });

    test('j: same order, but the other device edited X before the marker arrived: X is kept on both, the marker is removed, and the file holds the edit', () async {
      final (a, b, nb, ids) = await pair();
      final mk = '_deleted/${ids[0]}.json';
      await a.nb.deleteEntry(ids[0]);
      await a.engine.run();
      final e = (await b.nb.entry(ids[0]))!;
      await b.nb.saveEntry(id: ids[0], notebookId: nb, occurredAt: e.occurredAt, title: e.title, body: 'edited on B');
      b.folder.text[mk] = a.folder.text[mk]!;
      await b.engine.run();
      expect((await b.nb.entry(ids[0]))?.body, 'edited on B');
      expect(marks(b), isEmpty, reason: 'the marker is removed');
      mirror(b, a);
      for (var k = 0; k < 3; k++) {
        await a.engine.run();
        mirror(a, b);
        await b.engine.run();
        mirror(b, a);
      }
      for (final r in [a, b]) {
        expect((await r.nb.entry(ids[0]))?.body, 'edited on B');
        expect(marks(r), isEmpty);
        expect(mds(r), hasLength(2));
        expect(r.folder.text.values.any((t) => t.contains('edited on B')), isTrue, reason: 'the file holds the edit');
      }
    });

    test('an old-build peer removes a file with no marker: the new device writes it back, and the old device gets the entry back', () async {
      final (a, b, nb, ids) = await pair();
      // the old device: the delete leaves no marker
      await a.nb.deleteEntry(ids[0]);
      await a.engine.run();
      a.folder.text.removeWhere((k, _) => k.startsWith('_deleted/'));
      mirror(a, b);
      final rb = await b.engine.run();
      expect(rb.deleted, 0);
      expect(rb.written, 1);
      expect(await b.nb.entry(ids[0]), isNotNull, reason: 'the new device keeps the entry');
      expect(mds(b), hasLength(2));
      mirror(b, a);
      await a.engine.run();
      expect(await a.nb.entry(ids[0]), isNotNull, reason: 'the old-style delete comes back');
    });

    test('upgrade: a delete already applied stays deleted (no file written); one in flight (record, missing file, no marker) is written back once', () async {
      final r = _Rig(SyncKind.share);
      final j = await r.journal();
      final x = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Applied', body: 'x');
      final z = await r.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T17:12:00-06:00', title: 'Flight', body: 'z');
      await r.engine.run();
      // the old build applied a delete of X: no store copy, no record, no file, no marker
      await r.nb.deleteEntry(x.id);
      final st = jsonDecode(r.state.readAsStringSync()) as Map;
      (st['items'] as Map).remove(x.id);
      r.state.writeAsStringSync(jsonEncode(st));
      final keep = mds(r).firstWhere((k) => r.folder.text[k]!.contains(z.id));
      r.folder.text.removeWhere((k, _) => k != keep && k.endsWith('.md'));
      // Z: file gone, record kept, no marker
      r.folder.text.remove(keep);
      final rep = await r.engine.run();
      expect(rep.deleted, 0);
      expect(rep.written, 1, reason: 'only Z is written');
      expect(mds(r), hasLength(1));
      expect(r.folder.text[mds(r).single]!.contains(z.id), isTrue);
      expect(await r.nb.entry(x.id), isNull);
      expect(await r.nb.entry(z.id), isNotNull);
      final again = await r.engine.run();
      expect(again.written, 0, reason: 'once');
      expect(marks(r), isEmpty);
    });

    // A whole notebook deleted on one device removed its entries on the other (their markers) but left an empty notebook there
    // (2026-11-25, Linux and a phone): a notebook travels only as its entries' files, so nothing said the notebook was gone.
    Notebook? named(_Rig r, String name) => r.nb.notebooks.where((n) => n.name == name).firstOrNull;
    List<String> nbMarks(_Rig r) => [for (final k in marks(r)) if (k.startsWith('_deleted/notebook-')) k];

    /// Runs the devices in a ring until the folders settle: each one syncs, and the next gets its folder.
    Future<void> rounds(List<_Rig> rs, {int n = 3}) async {
      for (var i = 0; i < n; i++) {
        for (var k = 0; k < rs.length; k++) {
          await rs[k].engine.run();
          mirror(rs[k], rs[(k + 1) % rs.length]);
        }
      }
    }

    /// Two devices with the notebook Trip and two entries in it, synced both ways.
    Future<(_Rig, _Rig, List<String>)> tripPair() async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final trip = await a.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Trip', fields: [], sort: NotebookSort.recent));
      final ids = [
        for (var i = 0; i < 2; i++) (await a.nb.saveEntry(notebookId: trip.id, occurredAt: '2026-10-27T1$i:12:00-06:00', title: 'Leg $i', body: 'leg $i')).id,
      ];
      await rounds([a, b]);
      expect(named(b, 'Trip'), isNotNull, reason: 'Trip reached the other device');
      expect(await b.nb.entries(named(b, 'Trip')!.id), hasLength(2));
      return (a, b, ids);
    }

    test('a notebook deleted in Cache: the other device removes it and its entries, a device linked later never gets it, and a new one of that name travels', () async {
      final (a, b, ids) = await tripPair();
      final tripA = named(a, 'Trip')!;
      await a.nb.deleteNotebook(tripA.id);
      await rounds([a, b]);
      for (final r in [a, b]) {
        expect(named(r, 'Trip'), isNull, reason: 'no empty Trip is left behind');
        for (final id in ids) {
          expect(await r.nb.entry(id), isNull);
        }
        expect(nbMarks(r), ['_deleted/notebook-${tripA.id}.json'], reason: 'the notebook marker travels and is kept');
      }
      final m = jsonDecode(a.folder.text['_deleted/notebook-${tripA.id}.json']!) as Map;
      expect(m['name'], 'Trip');
      expect(m['at'], isA<int>());
      // a third device linked later
      final c = _Rig(SyncKind.share);
      await c.journal();
      mirror(b, c);
      await rounds([c, a, b]);
      for (final r in [a, b, c]) {
        expect(named(r, 'Trip'), isNull, reason: 'Trip does not come back');
      }
      // made again with the same name: a new notebook, and it travels
      final again = await a.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Trip', fields: [], sort: NotebookSort.recent));
      expect(again.id, isNot(tripA.id));
      final e = await a.nb.saveEntry(notebookId: again.id, occurredAt: '2026-10-28T09:00:00-06:00', title: 'New leg', body: 'new');
      await rounds([a, b, c]);
      for (final r in [a, b, c]) {
        final t = named(r, 'Trip');
        expect(t, isNotNull, reason: 'the new Trip is on every device');
        expect([for (final x in await r.nb.entries(t!.id)) x.id], [e.id]);
      }
    });

    test('one device edits an entry of a notebook while the other deletes the notebook: the later action wins, as for entries: the notebook stays on both with that entry', () async {
      final (a, b, ids) = await tripPair();
      await a.nb.deleteNotebook(named(a, 'Trip')!.id);
      final tripB = named(b, 'Trip')!;
      final e0 = (await b.nb.entry(ids[0]))!;
      await b.nb.saveEntry(id: e0.id, notebookId: tripB.id, occurredAt: e0.occurredAt, title: e0.title, body: 'edited on B');
      await rounds([a, b]);
      for (final r in [a, b]) {
        final t = named(r, 'Trip');
        expect(t, isNotNull, reason: 'the edit keeps the notebook');
        expect([for (final x in await r.nb.entries(t!.id)) x.body], ['edited on B']);
        expect(await r.nb.entry(ids[1]), isNull, reason: 'the entry nobody edited is deleted');
      }
    });

    test('a wiped share folder (no files, no markers) never deletes a notebook', () async {
      final (a, b, ids) = await tripPair();
      b.folder.text.clear();
      b.folder.bytes.clear();
      await rounds([b, a]);
      for (final r in [a, b]) {
        final t = named(r, 'Trip');
        expect(t, isNotNull);
        expect({for (final x in await r.nb.entries(t!.id)) x.id}, ids.toSet());
        expect(nbMarks(r), isEmpty);
      }
    });

    test('a notebook marker is kept for good, but a notebook of that name made after the delete is never removed by it, empty or not', () async {
      final (a, b, _) = await tripPair();
      await a.nb.deleteNotebook(named(a, 'Trip')!.id);
      await rounds([a, b]);
      expect(named(b, 'Trip'), isNull);
      // the person makes an empty Trip on B later (the store's time is after the delete)
      final fresh = await b.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Trip', fields: [], sort: NotebookSort.recent));
      b.store.notebooks.firstWhere((n) => n['id'] == fresh.id)['created'] = DateTime(2026, 10, 30).millisecondsSinceEpoch;
      await b.nb.reload();
      await rounds([a, b]);
      expect(named(b, 'Trip')?.id, fresh.id, reason: 'made after the delete: kept');
      expect(nbMarks(b), hasLength(1));
    });

    // R1 (build 57): a delete made in Cache came back on every device. The delete writes the marker and then removes the
    // file; the share sync's scan listed the removal at once but held the just-written marker back as still settling, so a
    // device that fetched in between got the removal alone and wrote the file back. Since the fix the share sync never
    // delivers the removal ahead of the marker (cache_sync tests/delete_after_marker.rs): the two come together, or the
    // removal after. This models that sync per path (each change gets a version, and a fetch takes every path that is newer
    // on the other device), so a scan can hold the removal back a round, and pins the end state for both orders.
    Future<void> r1Delete({required bool removalAfterMarker}) async {
      final (a, b, nb, ids) = await pair();
      final mk = '_deleted/${ids[0]}.json';
      var ver = 0;
      final index = {a: <String, (String?, int)>{}, b: <String, (String?, int)>{}};
      void scan(_Rig r, {bool holdDeletes = false}) {
        final idx = index[r]!;
        for (final e in r.folder.text.entries) {
          if (hidden(e.key)) continue;
          if (idx[e.key]?.$1 != e.value) idx[e.key] = (e.value, ++ver);
        }
        if (holdDeletes) return;
        for (final p in [for (final x in idx.entries) if (x.value.$1 != null && !r.folder.text.containsKey(x.key)) x.key]) {
          idx[p] = (null, ++ver);
        }
      }

      void fetch(_Rig to, _Rig from) {
        for (final e in index[from]!.entries) {
          if ((index[to]![e.key]?.$2 ?? 0) >= e.value.$2) continue;
          index[to]![e.key] = e.value;
          if (e.value.$1 == null) {
            to.folder.text.remove(e.key);
          } else {
            to.folder.text[e.key] = e.value.$1!;
          }
        }
      }

      scan(a);
      fetch(b, a);
      scan(b);
      // A deletes X: marker written, then the file removed; A's next scan lists both, or the marker and not yet the removal.
      await a.nb.deleteEntry(ids[0]);
      await a.engine.run();
      expect(marks(a), [mk]);
      expect(mds(a), hasLength(1));
      scan(a, holdDeletes: removalAfterMarker);
      // B fetches in between and runs its pass; then A's next scan lists the rest.
      fetch(b, a);
      await b.engine.run();
      scan(b);
      scan(a);
      for (var k = 0; k < 5; k++) {
        fetch(a, b);
        fetch(b, a);
        await a.engine.run();
        await b.engine.run();
        scan(a);
        scan(b);
      }
      Future<String> state(String name, _Rig r) async =>
          '$name: X ${await r.nb.entry(ids[0]) == null ? 'deleted' : 'BACK'}, other ${await r.nb.entry(ids[1]) == null ? 'gone' : 'kept'}, '
          'marker ${marks(r).contains(mk) ? 'kept' : 'GONE'}, ${mds(r).length} file(s)';
      expect([await state('A', a), await state('B', b)],
          ['A: X deleted, other kept, marker kept, 1 file(s)', 'B: X deleted, other kept, marker kept, 1 file(s)'],
          reason: 'R1: the delete stays done on both devices and the marker stays');
    }

    test('R1-delete control: the file removal and the marker go out in the same scan: X stays deleted on both', () async {
      await r1Delete(removalAfterMarker: false);
    });

    test('R1-delete: the marker goes out one scan ahead of the file removal and the other device fetches in between: X stays deleted on both and the marker stays', () async {
      await r1Delete(removalAfterMarker: true);
    });

    // Seen on two emulators 2026-11-25 (cache-status/verification/notebook-delete-travels-2026-11-25, steps 3, 3b and 7): B is
    // offline and edits X; A deletes X (or X's notebook). On a phone, saving the edit runs B's own pass within about 2 s, offline
    // too, so B's file holds the edit and B's record is up to date before the marker arrives. The edit then looked unchanged
    // since the last sync, and the marker deleted it, whichever came later. The rule: the later action wins, and an edit within
    // the clock-skew bound of the delete (10 seconds) counts as later (a lost edit is worse than a deleted entry coming back).
    // Each device has its own clock here (the edit's pass runs at the edit's time, the delete's pass at the delete's time), and
    // the share sync is modelled per path with versions in the order things happened (as in R1 above).
    // [editAfterDelete] is the edit's time minus the delete's (negative: the edit came first). [oldRecord]: B's record has no
    // change time (written before the fix). [oldMarker]: the marker has no `at` (written before build 57's format had one).
    Future<void> offlineEditVsDelete({required Duration editAfterDelete, required bool kept, bool notebook = false, bool oldRecord = false, bool oldMarker = false}) async {
      final _Rig a, b;
      final List<String> ids;
      if (notebook) {
        (a, b, ids) = await tripPair();
      } else {
        final p = await pair();
        (a, b, ids) = (p.$1, p.$2, p.$4);
      }
      final x = ids[0];
      final mk = '_deleted/$x.json';
      final tDelete = DateTime(2026, 11, 25, 16, 58, 5);
      final tEdit = tDelete.add(editAfterDelete);
      final now = {a: tDelete, b: tEdit};
      NotebookSync engine(_Rig r) => NotebookSync(
          notebook: r.nb, kind: SyncKind.share, folder: r.folder, stateFile: r.state, includePrivate: true, clock: () => now[r]!, templates: () async => builtInTemplates());

      var ver = 0;
      final index = {a: <String, (String?, int)>{}, b: <String, (String?, int)>{}};
      void scan(_Rig r) {
        final idx = index[r]!;
        for (final e in r.folder.text.entries) {
          if (hidden(e.key)) continue;
          if (idx[e.key]?.$1 != e.value) idx[e.key] = (e.value, ++ver);
        }
        for (final p in [for (final x in idx.entries) if (x.value.$1 != null && !r.folder.text.containsKey(x.key)) x.key]) {
          idx[p] = (null, ++ver);
        }
      }

      void fetch(_Rig to, _Rig from) {
        for (final e in index[from]!.entries) {
          if ((index[to]![e.key]?.$2 ?? 0) >= e.value.$2) continue;
          index[to]![e.key] = e.value;
          if (e.value.$1 == null) {
            to.folder.text.remove(e.key);
          } else {
            to.folder.text[e.key] = e.value.$1!;
          }
        }
      }

      scan(a);
      fetch(b, a);
      scan(b);

      // B, offline: the edit, then B's own pass at once (as on a phone), and B's share lists the changed file.
      Future<void> editOnB() async {
        final e = (await b.nb.entry(x))!;
        await b.nb.saveEntry(id: x, notebookId: e.notebookId, occurredAt: e.occurredAt, title: e.title, body: 'edited on B');
        await engine(b).run();
        scan(b);
        expect(b.folder.text.values.any((t) => t.contains('edited on B')), isTrue, reason: 'B\'s own pass wrote the edit to its share file');
      }

      // A: the delete (of X, or of X's notebook), A's pass (marker written, file removed), and A's share lists both.
      Future<void> deleteOnA() async {
        if (notebook) {
          await a.nb.deleteNotebook(named(a, 'Trip')!.id);
        } else {
          await a.nb.deleteEntry(x);
        }
        await engine(a).run();
        scan(a);
        expect(marks(a), contains(mk));
        expect((jsonDecode(a.folder.text[mk]!) as Map)['at'], tDelete.millisecondsSinceEpoch);
      }

      if (editAfterDelete > Duration.zero) {
        await deleteOnA();
        await editOnB();
      } else {
        await editOnB();
        await deleteOnA();
      }
      if (oldRecord) {
        final st = jsonDecode(b.state.readAsStringSync()) as Map;
        ((st['items'] as Map)[x] as Map).remove('ch');
        b.state.writeAsStringSync(jsonEncode(st));
      }
      if (oldMarker) {
        a.folder.text[mk] = jsonEncode({'id': x});
        scan(a);
      }

      // B reconnects: both ways, a few rounds, both clocks after both actions.
      final later = (tEdit.isAfter(tDelete) ? tEdit : tDelete).add(const Duration(minutes: 1));
      for (var k = 0; k < 4; k++) {
        now[a] = now[b] = later.add(Duration(minutes: k));
        fetch(b, a);
        fetch(a, b);
        await engine(b).run();
        scan(b);
        fetch(a, b);
        await engine(a).run();
        scan(a);
      }

      Future<String> state(String name, _Rig r) async {
        final e = await r.nb.entry(x);
        final trip = notebook ? (named(r, 'Trip') == null ? ', Trip gone' : ', Trip there${e != null && e.notebookId == named(r, 'Trip')!.id ? ' with X' : ''}') : '';
        return '$name: X ${e == null ? 'gone' : 'kept (${e.body})'}, other ${await r.nb.entry(ids[1]) == null ? 'gone' : 'kept'}, '
            'marker ${marks(r).contains(mk) ? 'there' : 'removed'}$trip';
      }

      // A notebook delete removes the other entry too (nobody edited it).
      final other = notebook ? 'gone' : 'kept';
      final trip = notebook ? (kept ? ', Trip there with X' : ', Trip gone') : '';
      expect(
          [await state('A', a), await state('B', b)],
          kept
              ? ['A: X kept (edited on B), other $other, marker removed$trip', 'B: X kept (edited on B), other $other, marker removed$trip']
              : ['A: X gone, other $other, marker there$trip', 'B: X gone, other $other, marker there$trip'],
          reason: 'the later action wins: edit ${editAfterDelete.inSeconds} s after the delete${oldRecord ? ', old record' : ''}${oldMarker ? ', old marker' : ''}');
    }

    // Failed before the fix (2026-11-25): the marker deleted B's later edit (the device symptom, X gone on both).
    test('offline edit vs delete, the edit is later (step 3b, 46 s): B\'s edit, already in its own share file, survives on both and the marker is removed', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: 46), kept: true);
    });

    test('offline edit vs delete, the edit is later by 30 s: kept on both and the marker is removed', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: 30), kept: true);
    });

    test('offline edit vs delete, the delete is later by 30 s (more than the 10 s skew bound): X is gone on both and the marker stays', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -30), kept: false);
    });

    test('offline edit vs delete, the device timings: the edit 23 s (step 3) or 42 s (step 7) before the delete: the later delete wins', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -23), kept: false);
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -42), kept: false);
    });

    test('offline edit vs delete, near-tie: the delete 5 s after the edit is within the 10 s skew bound and the edit is kept', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -5), kept: true);
    });

    test('offline edit vs delete, skew bound: 9 s before the delete is kept, 11 s before is deleted', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -9), kept: true);
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -11), kept: false);
    });

    test('offline edit vs delete, old record without a change time: deleted as before the fix, even when the edit is later', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: 46), kept: false, oldRecord: true);
    });

    test('offline edit vs delete, old marker without `at` (read as 0): a recorded local change keeps the entry, even 30 s before the delete', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -30), kept: true, oldMarker: true);
    });

    test('offline edit vs notebook delete, the edit is later: the entry AND its notebook stay on both, the other entry is gone', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: 46), kept: true, notebook: true);
    });

    test('offline edit vs notebook delete, the delete is later by 30 s: the notebook and both entries are gone on both', () async {
      await offlineEditVsDelete(editAfterDelete: const Duration(seconds: -30), kept: false, notebook: true);
    });
  });

  group('both devices changed the same words: the other version is kept as a new entry, nothing is asked', () {
    // Two devices of one share, each with its own folder (what cache_sync carries: every file but hidden ones).
    void carry(_Rig from, _Rig to) {
      bool hidden(String p) => p.split('/').any((c) => c.startsWith('.'));
      for (final e in from.folder.text.entries) {
        if (!hidden(e.key)) to.folder.text[e.key] = e.value;
      }
      for (final e in from.folder.bytes.entries) {
        if (!hidden(e.key)) to.folder.bytes[e.key] = e.value;
      }
    }

    Future<SyncReport> go(_Rig from, _Rig to) async {
      final rep = await from.engine.run();
      carry(from, to);
      return rep;
    }

    const first = 'Swapped six jugs at the shed. Next rotation in April.';

    /// Both devices have one Journal entry, synced.
    Future<(_Rig, _Rig, String, String)> synced({_Rig? a, _Rig? b}) async {
      a ??= _Rig(SyncKind.share);
      b ??= _Rig(SyncKind.share);
      final ja = await a.journal();
      final jb = await b.journal();
      final e = await a.nb.saveEntry(notebookId: ja.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Water cache restocked', body: first);
      await go(a, b);
      await b.engine.run();
      expect((await b.nb.entries(jb.id)).single.body, first);
      return (a, b, ja.id, e.id);
    }

    Future<void> edit(_Rig r, String nb, String id, String body) async {
      final e = (await r.nb.entry(id))!;
      await r.nb.saveEntry(id: id, notebookId: nb, occurredAt: e.occurredAt, title: e.title, body: body, photos: e.photos);
    }

    Future<List<(String, String?, String?)>> view(_Rig r, String nb) async => [for (final e in await r.nb.entries(nb)) (e.id, e.title, e.body)]..sort((x, y) => '${x.$2}'.compareTo('${y.$2}'));

    test('A: this device and the other changed the same words; the file of the other lands first; both end with the original and an "(other version)", no question, and later edits travel', () async {
      final (a, b, nb, id) = await synced();
      await edit(a, nb, id, 'Swapped eight jugs at the shed. Next rotation in April.');
      await edit(b, nb, id, 'Swapped ten jugs at the shed. Next rotation in April.');
      await go(b, a); // the other device's file is in the shared folder before this device runs
      final ra = await a.engine.run();
      expect(ra.keptAsTwo, ['Water cache restocked']);
      expect(ra.conflicts, 0);
      carry(a, b);
      final rb = await b.engine.run();
      expect(rb.conflicts, 0);
      carry(b, a);
      final rc = await a.engine.run();
      expect(rc.conflicts, 0);
      final ea = a.engine, eb = b.engine;
      await ea.run();
      await eb.run();
      expect(ea.conflicts, isEmpty);
      expect(eb.conflicts, isEmpty);
      final va = await view(a, nb), vb = await view(b, nb);
      expect(va, vb);
      expect(va.map((x) => x.$2), ['Water cache restocked', 'Water cache restocked (other version)']);
      expect(va.map((x) => x.$3).toSet(), {'Swapped eight jugs at the shed. Next rotation in April.', 'Swapped ten jugs at the shed. Next rotation in April.'});
      expect(va.first.$1, id);
      // a later edit on each device reaches the other
      await edit(a, nb, va[0].$1, 'Original, edited on A.');
      await edit(b, nb, va[1].$1, 'Copy, edited on B.');
      for (var i = 0; i < 2; i++) {
        await go(a, b);
        await b.engine.run();
        await go(b, a);
        await a.engine.run();
      }
      final wa = await view(a, nb), wb = await view(b, nb);
      expect(wa, wb);
      expect(wa.map((x) => x.$3), ['Original, edited on A.', 'Copy, edited on B.']);
    });

    test('B: different words changed on both: one entry, combined, no copy, and the run says it combined them', () async {
      final (a, b, nb, id) = await synced();
      await edit(a, nb, id, 'Swapped eight jugs at the shed. Next rotation in April.');
      await edit(b, nb, id, 'Swapped six jugs at the shed. Next rotation in May.');
      await go(b, a);
      final ra = await a.engine.run();
      expect(ra.merged, ['Water cache restocked']);
      expect(ra.keptAsTwo, isEmpty);
      expect(ra.conflicts, 0);
      carry(a, b);
      await b.engine.run();
      for (final r in [a, b]) {
        final v = await view(r, nb);
        expect(v.map((x) => x.$3), ['Swapped eight jugs at the shed. Next rotation in May.']);
      }
    });

    test('C: both devices meet the conflict in the same round: they still end with the same two entries, and no third', () async {
      final (a, b, nb, id) = await synced();
      await edit(a, nb, id, 'Swapped eight jugs at the shed. Next rotation in April.');
      await edit(b, nb, id, 'Swapped ten jugs at the shed. Next rotation in April.');
      // each sees the other's file before writing its own
      final path = a.folder.text.keys.firstWhere((k) => k.endsWith('.md'));
      final fileA = a.folder.text[path]!.replaceFirst('six', 'eight');
      final fileB = b.folder.text[path]!.replaceFirst('six', 'ten');
      a.folder.text[path] = fileB;
      b.folder.text[path] = fileA;
      final ra = await a.engine.run();
      final rb = await b.engine.run();
      expect([ra.keptAsTwo.length, rb.keptAsTwo.length, ra.conflicts, rb.conflicts], [1, 1, 0, 0]);
      for (var i = 0; i < 2; i++) {
        await go(a, b);
        await b.engine.run();
        await go(b, a);
        await a.engine.run();
      }
      final va = await view(a, nb), vb = await view(b, nb);
      expect(va, vb);
      expect(va, hasLength(2));
      expect(va.map((x) => x.$3).toSet(), {'Swapped eight jugs at the shed. Next rotation in April.', 'Swapped ten jugs at the shed. Next rotation in April.'});
      expect(a.engine.conflicts, isEmpty);
      expect(b.engine.conflicts, isEmpty);
    });

    test('D: a question an older build stored (both changed) is dropped on the next run, and the entry is handled by the new rule', () async {
      final (a, b, nb, id) = await synced();
      await edit(a, nb, id, 'Swapped eight jugs at the shed. Next rotation in April.');
      final path = a.folder.text.keys.firstWhere((k) => k.endsWith('.md'));
      final fileB = a.folder.text[path]!.replaceFirst('six', 'ten');
      // the state an older build left: the entry skipped for good, with its question
      final st = jsonDecode(a.state.readAsStringSync()) as Map<String, dynamic>;
      st['conflicts'] = [
        {'entry': id, 'kind': 'bothChanged', 'title': 'Water cache restocked', 'path': path, 'cache': 'x', 'file': fileB},
      ];
      a.state.writeAsStringSync(jsonEncode(st));
      a.folder.text[path] = fileB;
      final eng = a.engine;
      final rep = await eng.run();
      expect(rep.conflicts, 0);
      expect(eng.conflicts, isEmpty);
      expect(rep.keptAsTwo, ['Water cache restocked']);
      expect(await view(a, nb), hasLength(2));
      expect(((jsonDecode(a.state.readAsStringSync()) as Map)['conflicts'] as List), isEmpty);
    });

    test('E: both devices edited, the share file sync kept one text in the entry\'s file and renamed the other "(conflict, ...)": both end with the same two entries', () async {
      for (final swap in [false, true]) {
        final (a, b, nb, id) = await synced();
        await edit(a, nb, id, 'Swapped ${swap ? 'ten' : 'eight'} jugs at the shed. Next rotation in April.');
        await edit(b, nb, id, 'Swapped ${swap ? 'eight' : 'ten'} jugs at the shed. Next rotation in April.');
        await a.engine.run();
        // B's file is what B would have written; B itself has not synced yet (its record and folder stay as they were)
        final stateBefore = b.state.readAsStringSync(), folderBefore = Map.of(b.folder.text), bytesBefore = Map.of(b.folder.bytes);
        await b.engine.run();
        final path = a.folder.text.keys.firstWhere((k) => k.endsWith('.md'));
        final ta = a.folder.text[path]!, tb = b.folder.text[path]!;
        b.state.writeAsStringSync(stateBefore);
        b.folder.text..clear()..addAll(folderBefore);
        b.folder.bytes..clear()..addAll(bytesBefore);
        expect(ta, isNot(tb));
        final conflict = '${path.substring(0, path.length - 3)} (conflict, B, 2026-11-24 0543 UTC).md';
        for (final r in [a, b]) {
          r.folder.text[path] = ta;
          r.folder.text[conflict] = tb;
        }
        for (var i = 0; i < 4; i++) {
          await a.engine.run();
          carry(a, b);
          await b.engine.run();
          carry(b, a);
        }
        final va = await view(a, nb), vb = await view(b, nb);
        expect(va, vb);
        expect(va.map((x) => x.$2), ['Water cache restocked', 'Water cache restocked (other version)']);
        expect(va.map((x) => x.$3).toSet(), {'Swapped eight jugs at the shed. Next rotation in April.', 'Swapped ten jugs at the shed. Next rotation in April.'});
      }
    });

    test('an entry with photos: the other version gets photos of its own, and deleting either entry leaves the other\'s photo files', () async {
      for (final deleteOriginal in [true, false]) {
        final a = _Rig(SyncKind.share, ownMedia: true);
        final j = await a.journal();
        final media = a.media!;
        const p = '5b1c0d2e-7a3f-4c11-8e45-0123456789ab';
        for (final d in ['photos', 'thumbs']) {
          File('${media.path}/$d/$p.jpg')
            ..createSync(recursive: true)
            ..writeAsBytesSync([1, 2, 3]);
        }
        final e = await a.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Ridge', body: first, photos: [const NbPhoto(id: p)]);
        await a.engine.run();
        final path = a.folder.text.keys.firstWhere((k) => k.endsWith('.md'));
        expect(a.folder.text[path], contains('cache-$p.jpg'));
        await edit(a, j.id, e.id, 'Swapped eight jugs at the shed. Next rotation in April.');
        a.folder.text[path] = a.folder.text[path]!.replaceFirst('six', 'ten');
        final rep = await a.engine.run();
        expect(rep.keptAsTwo, ['Ridge']);
        expect(rep.photosLeftOut, 0);
        final all = await a.nb.entries(j.id);
        expect(all, hasLength(2));
        final orig = all.firstWhere((x) => x.id == e.id), copy = all.firstWhere((x) => x.id != e.id);
        expect(copy.title, 'Ridge (other version)');
        expect(orig.photos.map((x) => x.id), [p]);
        expect(copy.photos, hasLength(1));
        final q = copy.photos.single.id;
        expect(q, isNot(p));
        expect(q, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
        File ph(String d, String id) => File('${media.path}/$d/$id.jpg');
        expect([ph('photos', p).existsSync(), ph('thumbs', p).existsSync(), ph('photos', q).existsSync(), ph('thumbs', q).existsSync()], everyElement(isTrue));
        expect(ph('photos', q).readAsBytesSync(), [1, 2, 3]);
        await a.nb.deleteEntry(deleteOriginal ? orig.id : copy.id);
        final kept = deleteOriginal ? q : p, gone = deleteOriginal ? p : q;
        expect(ph('photos', kept).existsSync(), isTrue, reason: 'the other entry keeps its photo');
        expect(ph('thumbs', kept).existsSync(), isTrue);
        expect(ph('photos', gone).existsSync(), isFalse);
      }
    });

    test('a photo whose bytes are neither here nor in the folder is left out of the other version, and counted', () async {
      final a = _Rig(SyncKind.share, ownMedia: true);
      final j = await a.journal();
      const p = '5b1c0d2e-7a3f-4c11-8e45-0123456789ab';
      final e = await a.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Ridge', body: first, photos: [const NbPhoto(id: p)]);
      await a.engine.run();
      final path = a.folder.text.keys.firstWhere((k) => k.endsWith('.md'));
      await edit(a, j.id, e.id, 'Swapped eight jugs at the shed. Next rotation in April.');
      a.folder.text[path] = a.folder.text[path]!.replaceFirst('six', 'ten');
      final rep = await a.engine.run();
      expect(rep.photosLeftOut, 1);
      final copy = (await a.nb.entries(j.id)).firstWhere((x) => x.id != e.id);
      expect(copy.photos, isEmpty);
      expect(copy.body, anyOf(contains('eight'), contains('ten')));
    });

    test('a file the share file sync renamed "(conflict, ...)" is the other version: "<title> (other version)", a new id, its own photos, and the original stays', () async {
      final a = _Rig(SyncKind.share, ownMedia: true);
      final j = await a.journal();
      final media = a.media!;
      const p = '5b1c0d2e-7a3f-4c11-8e45-0123456789ab';
      for (final d in ['photos', 'thumbs']) {
        File('${media.path}/$d/$p.jpg')
          ..createSync(recursive: true)
          ..writeAsBytesSync([1, 2, 3]);
      }
      final e = await a.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Ridge', body: first, photos: [const NbPhoto(id: p)]);
      await a.engine.run();
      final path = a.folder.text.keys.firstWhere((k) => k.endsWith('.md'));
      final conflict = '${path.substring(0, path.length - 3)} (conflict, Android device, 2026-11-24 0543 UTC).md';
      a.folder.text[conflict] = a.folder.text[path]!.replaceFirst('six', 'ten');
      final rep = await a.engine.run();
      expect(rep.conflicts, 0);
      final all = await a.nb.entries(j.id);
      expect(all.map((x) => x.title).toList()..sort(), ['Ridge', 'Ridge (other version)']);
      final orig = all.firstWhere((x) => x.id == e.id), copy = all.firstWhere((x) => x.id != e.id);
      expect(orig.body, first);
      expect(copy.body, contains('ten'));
      expect(orig.photos.map((x) => x.id), [p]);
      expect(copy.photos, hasLength(1));
      expect(copy.photos.single.id, isNot(p));
      // another pass changes nothing: no third entry
      await a.engine.run();
      expect(await a.nb.entries(j.id), hasLength(2));
    });
  });

  group('a notebook\'s fields are fixed (1.1: the field editor is gone)', () {
    // Two devices of one share, each with its own folder. What cache_sync carries from one to the other: every file but hidden
    // ones (a name starting with "."), so `.cache/notebooks.json` stays on the device that wrote it.
    void carry(_Rig from, _Rig to) {
      bool hidden(String p) => p.split('/').any((c) => c.startsWith('.'));
      for (final e in from.folder.text.entries) {
        if (!hidden(e.key)) to.folder.text[e.key] = e.value;
      }
      for (final e in from.folder.bytes.entries) {
        if (!hidden(e.key)) to.folder.bytes[e.key] = e.value;
      }
    }

    Future<void> syncTo(_Rig from, _Rig to) async {
      await from.engine.run();
      carry(from, to);
      await to.engine.run();
    }

    const hikes = NotebookDef(
        name: 'Hikes', fields: [LogField(label: 'Trail', type: FieldType.text), LogField(label: 'Distance', type: FieldType.number, unit: 'mi')], quickAdd: true, sort: NotebookSort.recent);

    // "Hikes" (Trail, Distance) made on both devices (as from one starter log), two entries made on A and synced to B. Then B gets a
    // field A does not have, "Weather" (added before 1.1, as an earlier build could), with a value on Ridge, synced to A.
    Future<(_Rig, _Rig, String, String)> twoDevices() async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final la = await a.nb.saveNotebook(template: 'log', def: hikes);
      final lb = await b.nb.saveNotebook(template: 'log', def: hikes);
      await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-20T09:00:00-06:00', title: 'Ridge', body: 'Steep.', values: {'f1': 'Ridge loop', 'f2': 5});
      await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-21T09:00:00-06:00', title: 'Lake', body: 'Calm.', values: {'f1': 'Lake trail', 'f2': 3});
      await syncTo(a, b);
      expect([for (final e in await b.nb.entries(lb.id)) e.values['f1']]..sort(), ['Lake trail', 'Ridge loop']);
      final def = b.store.notebooks.firstWhere((n) => n['id'] == lb.id)['def'] as Map;
      (def['fields'] as List).add({'fid': 'f3', 'label': 'Weather', 'type': 'text'});
      await b.nb.reload();
      final ridge = (await b.nb.entries(lb.id)).firstWhere((e) => e.title == 'Ridge');
      await b.nb.saveEntry(id: ridge.id, notebookId: lb.id, occurredAt: ridge.occurredAt, title: 'Ridge', body: ridge.body, values: {...ridge.values, 'f3': 'Sunny'});
      await syncTo(b, a);
      return (a, b, la.id, lb.id);
    }

    String fileOf(_Rig r, String title) =>
        r.folder.text.entries.firstWhere((e) => e.key.endsWith('.md') && !e.key.startsWith('Conflicts/') && e.value.contains('\ntitle: $title\n')).value;

    Future<NbEntry> entryOf(_Rig r, String nb, String title) async => (await r.nb.entries(nb)).firstWhere((e) => e.title == title);

    test('R1: a notebook renamed on one device is renamed on the other, which keeps its fields and every value in its field', () async {
      final (a, b, ida, idb) = await twoDevices();
      final notebooksOnB = b.nb.notebooks.length;
      // A renames the notebook and edits Lake, so a file naming the new name reaches B.
      await a.nb.saveNotebook(id: ida, def: a.nb.notebook(ida)!.def.copyWith(name: 'Hikes 2024'));
      final lake = await entryOf(a, ida, 'Lake');
      await a.nb.saveEntry(id: lake.id, notebookId: ida, occurredAt: lake.occurredAt, title: 'Lake', body: 'Windy.', values: lake.values);
      await syncTo(a, b);
      await b.engine.run();
      expect(b.nb.notebooks.length, notebooksOnB, reason: 'no notebook is made for the new name');
      final book = b.nb.notebook(idb)!;
      expect(book.name, 'Hikes 2024', reason: 'the rename arrives');
      expect([for (final f in book.def.fields) (f.fid, f.label, f.hidden)], [('f1', 'Trail', false), ('f2', 'Distance', false), ('f3', 'Weather', false)],
          reason: 'no field is made again or hidden');
      expect((await entryOf(b, idb, 'Lake')).values, {'f1': 'Lake trail', 'f2': 3});
      expect((await entryOf(b, idb, 'Lake')).body, 'Windy.');
      expect((await entryOf(b, idb, 'Ridge')).values, {'f1': 'Ridge loop', 'f2': 5, 'f3': 'Sunny'});
      // B edits Ridge: its file keeps the keys both devices read.
      final ridge = await entryOf(b, idb, 'Ridge');
      await b.nb.saveEntry(id: ridge.id, notebookId: idb, occurredAt: ridge.occurredAt, title: 'Ridge', body: 'Steep and dry.', values: ridge.values);
      await syncTo(b, a);
      final text = fileOf(a, 'Ridge');
      expect(text, contains('notebook: Hikes 2024'));
      expect(text, contains('trail: Ridge loop'));
      expect(text, contains('distance: 5'));
      expect(text, contains('weather: Sunny'));
      expect((await entryOf(a, ida, 'Ridge')).values, {'f1': 'Ridge loop', 'f2': 5}, reason: 'A keeps its values in its fields');
      expect((await entryOf(a, ida, 'Ridge')).body, 'Steep and dry.');
      expect(a.nb.notebook(ida)!.def.fields.length, 2);
    });

    test('R1b: a notebook renamed on one device is renamed on the other with no entry touched: the rename travels with the notebook\'s files', () async {
      final (a, b, ida, idb) = await twoDevices();
      final notebooksOnB = b.nb.notebooks.length;
      await a.nb.saveNotebook(id: ida, def: a.nb.notebook(ida)!.def.copyWith(name: 'Hikes 2024'));
      await syncTo(a, b);
      await b.engine.run();
      expect(b.nb.notebooks.length, notebooksOnB, reason: 'no notebook is made for the new name');
      expect(b.nb.notebook(idb)!.name, 'Hikes 2024', reason: 'the rename arrives');
      expect((await entryOf(b, idb, 'Lake')).values, {'f1': 'Lake trail', 'f2': 3}, reason: 'every value stays in its field');
      expect(fileOf(a, 'Lake'), contains('notebook: Hikes 2024'));
    });

    test('R2: a value no field here holds stays in the file, line for line, through an edit, a merge and a same-words conflict', () async {
      final (a, b, id, idb) = await twoDevices();
      expect(fileOf(a, 'Ridge'), contains('weather: Sunny'));
      expect((await entryOf(a, id, 'Ridge')).values, {'f1': 'Ridge loop', 'f2': 5}, reason: 'A has no Weather field');
      Future<void> editA(String body) async {
        final e = await entryOf(a, id, 'Ridge');
        await a.nb.saveEntry(id: e.id, notebookId: id, occurredAt: e.occurredAt, title: e.title, body: body, values: e.values);
      }

      Future<void> editB({String? body, Map<String, dynamic>? values}) async {
        final e = await entryOf(b, idb, 'Ridge');
        await b.nb.saveEntry(id: e.id, notebookId: idb, occurredAt: e.occurredAt, title: e.title, body: body ?? e.body, values: values ?? e.values);
      }

      // an edit on A (A writes the file)
      await editA('Steep. Loose rock.');
      await syncTo(a, b);
      expect(fileOf(a, 'Ridge'), contains('weather: Sunny'));
      // a clean merge on A: A changes the text, B a value
      await editA('Steep. Loose rock near the top.');
      await editB(values: {'f1': 'Ridge loop', 'f2': 6, 'f3': 'Sunny'});
      await syncTo(b, a);
      expect((await entryOf(a, id, 'Ridge')).values['f2'], 6);
      expect(fileOf(a, 'Ridge'), contains('weather: Sunny'));
      await syncTo(a, b);
      // the same words changed on both: the other version is kept as a new entry (no question), and both keep the value
      await editA('Gentle.');
      await editB(body: 'Brutal.');
      await b.engine.run();
      carry(b, a);
      var ea = a.engine;
      await ea.run();
      expect(ea.conflicts, isEmpty);
      expect(fileOf(a, 'Ridge'), contains('weather: Sunny'));
      expect(fileOf(a, 'Ridge (other version)'), contains('weather: Sunny'));
      await syncTo(a, b);
      // again, then an edit here
      await editA('Rocky.');
      await editB(body: 'Muddy.');
      await b.engine.run();
      carry(b, a);
      ea = a.engine;
      await ea.run();
      expect(ea.conflicts, isEmpty);
      await editA('Muddy, then dry.');
      await syncTo(a, b);
      expect(fileOf(a, 'Ridge'), contains('weather: Sunny'));
      expect(fileOf(b, 'Ridge'), contains('weather: Sunny'));
      expect((await entryOf(b, idb, 'Ridge')).values, {'f1': 'Ridge loop', 'f2': 6, 'f3': 'Sunny'});
      expect((await entryOf(b, idb, 'Ridge')).body, 'Muddy, then dry.');
      // one more round changes nothing
      final ra = await a.engine.run();
      carry(a, b);
      final rb = await b.engine.run();
      expect([ra.written, ra.read, rb.written, rb.read], [0, 0, 0, 0]);
    });

    test('G1: saving a notebook that exists keeps its fields, hidden ones too; a new notebook gets the fields it is given', () async {
      final r = _Rig(SyncKind.share);
      await r.journal();
      final log = await r.nb.saveNotebook(
          template: 'log',
          def: const NotebookDef(
              name: 'Generator test',
              fields: [LogField(label: 'Run time', type: FieldType.number, unit: 'min'), LogField(label: 'Under load', type: FieldType.yesNo)],
              quickAdd: true,
              sort: NotebookSort.recent));
      expect([for (final f in log.def.fields) f.fid], ['f1', 'f2'], reason: 'a new notebook gets its fields');
      // a field taken out by an earlier build, hidden with its values
      final def = r.store.notebooks.firstWhere((n) => n['id'] == log.id)['def'] as Map;
      (def['fields'] as List).add({'fid': 'f3', 'label': 'Fuel', 'type': 'text', 'hidden': true});
      await r.nb.reload();
      final before = jsonEncode(r.nb.notebook(log.id)!.def.toJson()['fields']);
      final renamed = await r.nb.saveNotebook(
          id: log.id, def: r.nb.notebook(log.id)!.def.copyWith(name: 'Generator check', fields: const [LogField(label: 'Something new', type: FieldType.text)]));
      expect(renamed.name, 'Generator check');
      expect(jsonEncode(renamed.def.toJson()['fields']), before);
      final emptied = await r.nb.saveNotebook(id: log.id, def: renamed.def.copyWith(fields: const []), map: true);
      expect(jsonEncode(emptied.def.toJson()['fields']), before);
      expect(emptied.map, isTrue);
    });
  });

  group('a notebook of more than 1000 entries loses none to sync', () {
    void carry(_Rig from, _Rig to) {
      for (final e in from.folder.text.entries) {
        if (!e.key.split('/').any((c) => c.startsWith('.'))) to.folder.text[e.key] = e.value;
      }
      for (final e in from.folder.bytes.entries) {
        if (!e.key.split('/').any((c) => c.startsWith('.'))) to.folder.bytes[e.key] = e.value;
      }
    }

    int files(_Rig r) => r.folder.text.keys.where((k) => k.endsWith('.md')).length;

    Future<(_Rig, _Rig, String, String)> big(int n) async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      const def = NotebookDef(name: 'Repeaters', fields: [], sort: NotebookSort.distance);
      final la = await a.nb.saveNotebook(template: 'notes', def: def);
      final lb = await b.nb.saveNotebook(template: 'notes', def: def);
      for (var i = 0; i < n; i++) {
        await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-20T09:00:00-06:00', title: 'R$i', body: 'row $i');
      }
      return (a, b, la.id, lb.id);
    }

    test('1050 entries reach the other device and none is lost on later rounds, both ways', () async {
      const n = 1050; // just over the 1000 the bug lived at; a lighter notebook, the same boundary
      expect(n, greaterThan(1000));
      final (a, b, ida, idb) = await big(n);
      await a.engine.run();
      expect(files(a), n, reason: 'every entry is written, not the first 1000');
      carry(a, b);
      await b.engine.run();
      expect((await b.nb.entries(idb)).length, n);
      // a second round each way changes nothing
      await b.engine.run();
      carry(b, a);
      await a.engine.run();
      expect(files(a), n);
      expect((await a.nb.entries(ida)).length, n);
      expect((await b.nb.entries(idb)).length, n);
      // an edit to the last entry made on B comes back to A
      final last = (await b.nb.entries(idb)).firstWhere((e) => e.title == 'R${n - 1}');
      await b.nb.saveEntry(id: last.id, notebookId: idb, occurredAt: last.occurredAt, title: 'R${n - 1}', body: 'edited on B');
      await b.engine.run();
      carry(b, a);
      await a.engine.run();
      expect((await a.nb.entries(ida)).firstWhere((e) => e.title == 'R${n - 1}').body, 'edited on B');
      expect((await a.nb.entries(ida)).length, n);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('an entry the read did not return is never treated as deleted', () async {
      final (a, _, ida, _) = await big(300);
      await a.engine.run();
      expect(files(a), 300);
      // the read now stops short (whatever the reason): 100 of 300 come back
      a.store.entryCap = 100;
      final r = await a.engine.run();
      expect(r.deleted, 0);
      expect(files(a), 300, reason: 'no file is removed for an entry that was only not read');
      expect(a.store.entries.where((e) => e['notebook_id'] == ida).length, 300);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('a notebook made from a built-in template reaches the other phone with its fields', () {
    void carry(_Rig from, _Rig to) {
      for (final e in from.folder.text.entries) {
        if (!e.key.split('/').any((c) => c.startsWith('.'))) to.folder.text[e.key] = e.value;
      }
    }

    test('a starter log: phone 2 makes the Log with its fields, and every value is in its field', () async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final t = builtInTemplates().starters.firstWhere((s) => s.id == 'starter.generator_test');
      final la = await a.nb.saveNotebook(template: t.template, def: t.def, templateRef: t.ref, map: false);
      await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-25T16:12:00-06:00', body: 'Ran fine.', values: {'f1': 20, 'f2': true, 'f3': 'Half'});
      await a.engine.run();
      expect(a.folder.text.values.firstWhere((v) => v.contains('Ran fine.')), contains('cache_template: starters/starter.generator_test@1'));
      carry(a, b);
      await b.engine.run();
      final lb = b.nb.notebooks.firstWhere((n) => n.name == 'Generator test');
      expect((lb.template, lb.isLog, lb.def.dueEvery, lb.templateRef), ('log', true, 'month', 'starters/starter.generator_test@1'));
      expect([for (final f in lb.def.visible) (f.label, f.type)], [('Run time', FieldType.number), ('Under load', FieldType.yesNo), ('Fuel level', FieldType.choice)]);
      final eb = (await b.nb.entries(lb.id)).single;
      expect(eb.values, {'f1': 20, 'f2': true, 'f3': 'Half'}, reason: 'the values are in the template\'s fields, not left in the file');
      expect(eb.body, 'Ran fine.');
      // phone 2 changes the fuel level; phone 1 reads it into its field
      await b.nb.saveEntry(id: eb.id, notebookId: lb.id, occurredAt: eb.occurredAt, body: eb.body, values: {...eb.values, 'f3': 'Low'});
      await b.engine.run();
      carry(b, a);
      await a.engine.run();
      expect((await a.nb.entries(la.id)).single.values['f3'], 'Low');
    });

    test('a built-in template: phone 2 makes the notebook from it (shape, icon, colour, map switch)', () async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final t = builtInTemplates().byId('notes')!;
      final la = await a.nb.saveNotebook(template: t.template, def: t.def.copyWith(name: 'Family plan'), templateRef: t.ref, map: false);
      await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-25T16:12:00-06:00', title: 'Meeting spot', body: 'The old mill.');
      await a.engine.run();
      carry(a, b);
      await b.engine.run();
      final lb = b.nb.notebooks.firstWhere((n) => n.name == 'Family plan');
      expect((lb.template, lb.templateRef, lb.def.sort, lb.map), ('notes', t.ref, NotebookSort.recent, false));
    });

    test('a template this build does not have is made as before: a notes notebook that keeps every value', () async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final t = builtInTemplates().starters.firstWhere((s) => s.id == 'starter.generator_test');
      final la = await a.nb.saveNotebook(template: t.template, def: t.def, templateRef: t.ref, map: false);
      await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-25T16:12:00-06:00', body: 'Ran fine.', values: {'f1': 20, 'f2': true, 'f3': 'Half'});
      await a.engine.run();
      for (final e in a.folder.text.entries) {
        if (e.key.split('/').any((c) => c.startsWith('.'))) continue; // a hidden file never leaves the device
        b.folder.text[e.key] = e.value.replaceFirst('starters/starter.generator_test@1', 'starters/starter.from_the_future@3');
      }
      await b.engine.run();
      final lb = b.nb.notebooks.firstWhere((n) => n.name == 'Generator test');
      expect((lb.template, lb.isLog), ('notes', false));
      expect(lb.def.fields, isEmpty);
      final file = b.folder.text.values.firstWhere((v) => v.contains('Ran fine.'));
      expect(file, contains('run_time: 20'), reason: 'every value stays in the file');
      expect(file, contains('cache_template: starters/starter.from_the_future@3'), reason: 'and so does the line, for a build that knows it');
    });

    test('a notebook with its own fields (not from a template) arrives as before, and the person\'s own vault gets no template line', () async {
      final a = _Rig(SyncKind.share), vault = _Rig(SyncKind.obsidian);
      await a.journal();
      await vault.journal();
      const def = NotebookDef(name: 'Hikes', fields: [LogField(label: 'Trail', type: FieldType.text)], sort: NotebookSort.recent);
      final la = await a.nb.saveNotebook(template: 'log', def: def);
      await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-10-25T16:12:00-06:00', body: 'Dry.', values: {'f1': 'Ridge'});
      await a.engine.run();
      expect(a.folder.text.values.firstWhere((v) => v.contains('Dry.')), isNot(contains('cache_template')));
      final t = builtInTemplates().starters.firstWhere((s) => s.id == 'starter.generator_test');
      final lv = await vault.nb.saveNotebook(template: t.template, def: t.def, templateRef: t.ref, map: false);
      await vault.nb.saveEntry(notebookId: lv.id, occurredAt: '2026-10-25T16:12:00-06:00', body: 'Ran.', values: {'f1': 20});
      await vault.engine.run();
      expect(vault.folder.text.values.firstWhere((v) => v.contains('Ran.')), isNot(contains('cache_template')));
    });
  });

  group('a repeater list syncs as a notebook with one .md entry per repeater', () {
    test('its entries are files with the callsign, the settings and the position; another device reads them as a notebook and loses nothing', () async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final t = Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync()).byId('repeaters')!;
      // as the core makes one: the template's ref, so notebook sync names the template in every entry file
      final la = await a.nb.saveNotebook(template: t.template, def: t.def, map: true, templateRef: t.ref);
      await a.nb.saveEntry(
        notebookId: la.id,
        occurredAt: '2026-11-14T09:00:00-07:00',
        title: 'W0TST1',
        body: 'Checked on the 14th.',
        values: {'f1': '146.940 MHz', 'f2': '-600 kHz', 'f3': '151.4 Hz to transmit and receive', 'f5': 'Burley', 'f6': true},
        place: const NbPlace(lat: 42.54, lon: -113.8),
      );
      await a.engine.run();
      final md = a.folder.text.entries.firstWhere((e) => e.key.endsWith('.md') && e.value.contains('title: W0TST1')).value;
      expect(md, contains('notebook: Repeaters'));
      expect(md, contains('frequency: 146.940 MHz'));
      expect(md, contains('on_air: true'));
      expect(md, contains('lat: 42.54'));
      expect(md, contains('Checked on the 14th.'));
      // what cache_sync carries (never a hidden file) reaches B, which has no such notebook yet
      for (final e in a.folder.text.entries) {
        if (!e.key.split('/').any((c) => c.startsWith('.'))) b.folder.text[e.key] = e.value;
      }
      await b.engine.run();
      expect(md, contains('cache_template: templates/repeaters@1'));
      final nbB = b.nb.notebooks.firstWhere((n) => n.name == 'Repeaters');
      final eB = (await b.nb.entries(nbB.id)).single;
      expect((eB.title, eB.body, eB.place?.lat), ('W0TST1', 'Checked on the 14th.', 42.54));
      // phone 2 has the Repeaters template's fields, and every value is in its field
      expect((nbB.template, nbB.isRepeaters, nbB.def.sort, nbB.def.icon, nbB.def.color), ('repeaters', true, NotebookSort.distance, 'radio_tower', 'purple'));
      expect([for (final f in nbB.def.visible) (f.label, f.type)], [for (final f in la.def.visible) (f.label, f.type)]);
      expect(eB.values, {'f1': '146.940 MHz', 'f2': '-600 kHz', 'f3': '151.4 Hz to transmit and receive', 'f5': 'Burley', 'f6': true},
          reason: 'frequency, offset, tone, town and on air are in their fields on phone 2');
      // B writes it back unchanged: A's entry keeps every value
      await b.engine.run();
      for (final e in b.folder.text.entries) {
        if (!e.key.split('/').any((c) => c.startsWith('.'))) a.folder.text[e.key] = e.value;
      }
      await a.engine.run();
      final eA = (await a.nb.entries(la.id)).single;
      expect(eA.values, {'f1': '146.940 MHz', 'f2': '-600 kHz', 'f3': '151.4 Hz to transmit and receive', 'f5': 'Burley', 'f6': true});
    });
  });

  group('a repeater list that arrives all at once on a phone that has no such notebook', () {
    test('every repeater keeps its fields, not only the first (three rows with no position, as a CSV import makes them)', () async {
      final a = _Rig(SyncKind.share), b = _Rig(SyncKind.share);
      await a.journal();
      await b.journal();
      final t = Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync()).byId('repeaters')!;
      final la = await a.nb.saveNotebook(template: t.template, def: t.def, map: true, templateRef: t.ref);
      const rows = [
        ('R11 Boise', {'f1': '146.760 MHz', 'f2': '-600 kHz', 'f3': '100.0 Hz to transmit and receive', 'f4': 'FM'}),
        ('R11 Nampa', {'f1': '147.020 MHz', 'f2': '+600 kHz', 'f3': '107.2 Hz to transmit and receive', 'f4': 'FM'}),
        ('R11 Meridian', {'f1': '444.100 MHz', 'f2': '+5 MHz', 'f3': '123.0 Hz to transmit and receive', 'f4': 'FM'}),
      ];
      var minute = 0;
      for (final r in rows) {
        await a.nb.saveEntry(notebookId: la.id, occurredAt: '2026-11-15T09:0${minute++}:00-07:00', title: r.$1, body: '', values: r.$2);
      }
      await a.engine.run();
      for (final e in a.folder.text.entries) {
        if (!e.key.split('/').any((c) => c.startsWith('.'))) b.folder.text[e.key] = e.value;
      }
      // one round on the other phone brings all three: the first makes the notebook, the others must be read with its fields
      await b.engine.run();
      final nbB = b.nb.notebooks.firstWhere((n) => n.name == 'Repeaters');
      final got = {for (final e in await b.nb.entries(nbB.id)) e.title: e.values};
      expect(got, {for (final r in rows) r.$1: r.$2}, reason: 'every row has its frequency, offset, tone and mode on phone 2');
      // and it stays so after more rounds
      await b.engine.run();
      await b.engine.run();
      final again = {for (final e in await b.nb.entries(nbB.id)) e.title: e.values};
      expect(again, {for (final r in rows) r.$1: r.$2});
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

  group('Activity lines', () {
    test('notebook sync says, in a few words and with no ids or paths, what arrived, changed or was removed', () {
      final nb = fakeNotebook(FakeNotebookBackend());
      final lines = <String>[];
      final c = NotebookConnections(notebook: nb, dir: () async => Directory.systemTemp, onActivity: lines.add);
      c.say(SyncReport()..read = 5..arrived = 3..removedHere = 1);
      expect(lines, ['Notebooks: 3 entries arrived from your other devices', 'Notebooks: 2 entries updated from your other devices', 'Notebooks: 1 entry removed by your other devices']);
      lines.clear();
      c.say(SyncReport()..merged.add('Water'));
      c.say(SyncReport()..merged.addAll(['A', 'B', 'C']));
      c.say(SyncReport()..keptAsTwo.add('Water cache restocked'));
      expect(lines, [
        'Notebooks: 1 entry combined with changes from your other devices',
        'Notebooks: 3 entries combined with changes from your other devices',
        'Notebooks: Water cache restocked: both devices changed the same words; the other version is kept as a new entry',
      ]);
      lines.clear();
      c.say(SyncReport()..written = 4);
      expect(lines, isEmpty, reason: 'what this device sent is not said');
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
      // The status line appears when the first sync of the new folder has ended; that sync does real file work, so wait for
      // it (up to 10 s) instead of a fixed time.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
        for (var i = 0; i < 200; i++) {
          final t = c.target(SyncKind.obsidian);
          if (t != null && c.status(t.id) != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
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

class _Included implements PrivateSharing {
  final Set<String> ids = {};

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

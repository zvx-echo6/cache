import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/folder.dart';
import 'package:cache/notebook/sync/formats.dart';
import 'package:cache/notebook/sync/merge.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
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

class _Rig {
  _Rig(this.kind, {this.includePrivate = true}) {
    nb = fakeNotebook(store);
  }

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
      // removed in the folder: Cache asks
      r.folder.text.remove(path);
      final eng2 = r.engine;
      expect((await eng2.run()).conflicts, 1);
      expect(eng2.conflicts.single.kind, ConflictKind.removedOutside);
      await eng2.resolve(eng2.conflicts.single, keepCache: true);
      expect(r.folder.text[path], contains('cache_id: ${a.id}'));
      // a new note in the Journal folder: a new entry, and its id written into it
      r.folder.text['Journal/Shopping.md'] = 'Buy matches.\n';
      rep = await r.engine.run();
      expect(rep.read, 1);
      final made = r.store.entries.firstWhere((x) => x['body'] == 'Buy matches.');
      expect(r.folder.text['Journal/Shopping.md'], contains('cache_id: ${made['id']}'));
      // unreadable properties: left alone, and Cache asks
      const broken = '---\ntitle: x\nnot a property\n---\nbody\n';
      r.folder.text['Journal/Broken.md'] = broken;
      final eng3 = r.engine;
      expect((await eng3.run()).conflicts, 1);
      expect(eng3.conflicts.single.kind, ConflictKind.unreadable);
      expect(r.folder.text['Journal/Broken.md'], broken);
      await eng3.resolve(eng3.conflicts.single, keepCache: true);
      expect((await r.engine.run()).conflicts, 0, reason: 'ignored from now on');
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
    test('private items stay home unless chosen; a second device makes the notebook and its entries', () async {
      final one = _Rig(SyncKind.share, includePrivate: false);
      final j = await one.journal();
      final log = await one.nb.saveNotebook(
          template: 'log',
          def: const NotebookDef(name: 'Generator test', fields: [LogField(label: 'Run time', type: FieldType.number, unit: 'min')], quickAdd: true, sort: NotebookSort.recent));
      await one.nb.saveEntry(notebookId: log.id, occurredAt: '2026-10-25T16:12:00-06:00', values: {'f1': 20}, body: 'Oil fine.');
      await one.nb.saveEntry(notebookId: j.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Private', body: 'x', private: true);
      await one.engine.run();
      expect(one.folder.text.keys.where((k) => k.endsWith('.md')).length, 1);
      final books = jsonDecode(one.folder.text['.cache/notebooks.json']!) as Map;
      expect([for (final n in books['notebooks'] as List) (n as Map)['def']['name']], containsAll(['Journal', 'Generator test']));
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
      // with private items chosen, the private entry goes too
      final again = NotebookSync(notebook: one.nb, kind: SyncKind.share, folder: one.folder, stateFile: one.state, includePrivate: true);
      await again.run();
      expect(one.folder.text.keys.where((k) => k.endsWith('.md')).length, 2);
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
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: ConnectionsScreen(connections: c)));
      expect(find.text('Obsidian'), findsNothing);
      expect(find.text('Your other devices'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: ConnectionsScreen(connections: c, folders: true, pickFolder: () async => '/vault')));
      expect(find.text('Obsidian'), findsOneWidget);
      expect(find.text('Logseq'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(c.target(SyncKind.obsidian)?.path, '/vault');
      expect(find.byKey(const ValueKey('status-obsidian')), findsOneWidget);
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

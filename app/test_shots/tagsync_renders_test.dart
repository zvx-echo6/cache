// Import by tag (1.0.30, UX-tag-import-30) for the owner to review, drawn by the app itself with sample data (no personal data).
// flutter test test_shots/tagsync_renders_test.dart --update-goldens  (pictures in test_shots/tagsync/)

import 'dart:io';
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/folder.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/entry_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/update/update_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const _out = 'tagsync';

class _Mem implements SyncFolder {
  final Map<String, String> text = {};
  final Set<String> readOnly = {};

  @override
  String get display => 'Vault';

  @override
  Future<bool> reachable() async => true;

  @override
  Future<List<FolderFile>> list(String dir) async => [
        for (final p in (text.keys.toList()..sort()))
          if (dir.isEmpty || p.startsWith('$dir/')) FolderFile(p, 0, text[p]!.length),
      ];

  @override
  Future<String?> readText(String path) async => text[path];

  @override
  Future<Uint8List?> readBytes(String path) async => null;

  @override
  Future<void> writeText(String path, String t) async {
    if (readOnly.contains(path)) throw const FileSystemException('Read-only file system');
    text[path] = t;
  }

  @override
  Future<void> writeBytes(String path, Uint8List b) async {}

  @override
  Future<void> delete(String path) async => text.remove(path);

  @override
  Future<bool> exists(String path) async => text.containsKey(path);
}

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

class _Kit {
  _Kit(this.nb, this.mem, this.c);

  final NotebookState nb;
  final _Mem mem;
  final NotebookConnections c;

  NotebookDeps get deps => NotebookDeps(notebook: nb, places: PlaceChoices.none, connections: c, now: () => DateTime(2026, 10, 29, 17, 2));

  /// Notebooks with an Obsidian vault connected; [notes] are in the vault before the first sync.
  static Future<_Kit> boot(WidgetTester tester, {Map<String, String> notes = const {}, Set<String> readOnly = const {}, bool sync = true}) async {
    final nb = fakeNotebook(FakeNotebookBackend());
    final mem = _Mem()
      ..text.addAll(notes)
      ..readOnly.addAll(readOnly);
    final dir = Directory.systemTemp.createTempSync('cache-tagsync-shots-');
    final c = NotebookConnections(notebook: nb, dir: () async => dir, folderFor: (_) => mem);
    await tester.runAsync(() async {
      await nb.start();
      await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Camping trip', fields: [], sort: NotebookSort.recent));
      await c.init();
      await c.connect(SyncKind.obsidian, '/storage/Vault', display: 'Vault');
      if (sync) await _waitSync(c);
    });
    return _Kit(nb, mem, c);
  }
}

Future<void> _waitSync(NotebookConnections c) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await c.syncAll();
  while (c.syncing) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String _id(String text) => RegExp(r'cache_id: (\S+)').firstMatch(text)!.group(1)!;

Future<void> _show(WidgetTester tester, Widget page, {CacheThemeId theme = CacheThemeId.light}) async {
  phone(tester);
  await tester.pumpWidget(shotApp(page, theme: theme));
  await _settle(tester);
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets('1: the Import tag row, default and changed; light and dark', (tester) async {
    final k = await _Kit.boot(tester);
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      await _show(tester, ConnectionsScreen(connections: k.c, pickFolder: () async => null, phone: true), theme: theme);
      await snap(tester, _out, '1a-import-tag-row-default${theme == CacheThemeId.dark ? '-dark' : ''}');
    }
    await tester.runAsync(() => k.c.setImportTag('obsidian', '#camping'));
    await _show(tester, ConnectionsScreen(connections: k.c, pickFolder: () async => null, phone: true));
    await snap(tester, _out, '1b-import-tag-row-changed');
  });

  testWidgets('2: the Import tag sheet, valid and invalid', (tester) async {
    final k = await _Kit.boot(tester);
    await _show(tester, ConnectionsScreen(connections: k.c, pickFolder: () async => null, phone: true));
    await tester.tap(find.byKey(const ValueKey('import-tag-obsidian')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('import-tag-field')), '#camping');
    await _settle(tester);
    await snap(tester, _out, '2a-import-tag-sheet-valid');
    await tester.enterText(find.byKey(const ValueKey('import-tag-field')), '#camping trip');
    await _settle(tester);
    await snap(tester, _out, '2b-import-tag-sheet-invalid');
  });

  testWidgets('3: the entry menu with Stop syncing, its confirm, the unreachable state; then the entry with the sync-off mark', (tester) async {
    final k = await _Kit.boot(tester, notes: {'Trips/Camping list.md': '---\ntags:\n  - cachesync/Camping-trip\n---\nWater filter, stove, two fuel cans.\n'});
    final id = _id(k.mem.text['Trips/Camping list.md']!);
    final e = (await tester.runAsync(() => k.nb.entry(id)))!;
    Widget editor(NbEntry e) => EntryEditor(notebook: k.nb, book: k.nb.notebook(e.notebookId)!, places: PlaceChoices.none, entry: e, connections: k.c, now: k.deps.now);
    await _show(tester, editor(e));
    await tester.tap(find.byKey(const ValueKey('editor-menu')));
    await _settle(tester);
    await snap(tester, _out, '3a-entry-menu-stop-syncing');
    await tester.tap(find.text('Stop syncing this note'));
    await _settle(tester);
    await snap(tester, _out, '3b-stop-syncing-confirm');
    await _show(tester, editor(e));
    showDialog<bool>(
      context: tester.element(find.byType(EntryEditor)),
      builder: (_) => StopSyncingDialog(
          app: 'Obsidian', stop: () async => null, unreachable: 'Cache cannot reach Obsidian right now. Try again when it is connected.'),
    );
    await _settle(tester);
    await snap(tester, _out, '3c-stop-syncing-unreachable');
    await _show(tester, editor(e));
    await tester.tap(find.byKey(const ValueKey('editor-menu')));
    await _settle(tester);
    await tester.tap(find.text('Stop syncing this note'));
    await _settle(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('stop-sync-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settle(tester, 20);
    await snap(tester, _out, '3d-stopped-snackbar-and-mark');
    await _show(tester, NotebookScreen(deps: k.deps, notebookId: e.notebookId));
    await snap(tester, _out, '3e-list-with-sync-off-mark');
  });

  testWidgets('4: after a sync: one note added, two notes added, a note not added', (tester) async {
    var k = await _Kit.boot(tester, sync: false, notes: {'Trips/Camping list.md': 'Water filter, stove. #cachesync/Camping-trip\n'});
    await _show(tester, NotebooksScreen(deps: k.deps));
    await _settle(tester, 30);
    await snap(tester, _out, '4a-added-one');
    k = await _Kit.boot(tester, sync: false, notes: {
      'Trips/Camping list.md': 'Water filter, stove. #cachesync/Camping-trip\n',
      'Trips/Tent check.md': 'Seam sealer, spare stakes. #cachesync/Camping-trip\n',
    });
    await _show(tester, NotebooksScreen(deps: k.deps));
    await _settle(tester, 30);
    await snap(tester, _out, '4b-added-two');
    k = await _Kit.boot(tester, notes: {'Locked.md': 'Keep this. #cachesync\n'}, readOnly: {'Locked.md'});
    await _show(tester, ConnectionsScreen(connections: k.c, pickFolder: () async => null, phone: true));
    await snap(tester, _out, '4c-not-added');
  });

  testWidgets('5: deleting an entry that came from Obsidian', (tester) async {
    final k = await _Kit.boot(tester, notes: {'Trips/Camping list.md': 'Water filter, stove. #cachesync\n'});
    final e = (await tester.runAsync(() => k.nb.entry(_id(k.mem.text['Trips/Camping list.md']!))))!;
    await _show(tester, EntryEditor(notebook: k.nb, book: k.nb.notebook(e.notebookId)!, places: PlaceChoices.none, entry: e, connections: k.c, now: k.deps.now));
    await tester.tap(find.byKey(const ValueKey('editor-menu')));
    await _settle(tester);
    await tester.tap(find.text('Delete'));
    await _settle(tester);
    await snap(tester, _out, '5-delete-confirm');
  });

  testWidgets('6: a private note imported (private: true), in the list and opened', (tester) async {
    final k = await _Kit.boot(tester, notes: {
      'Health/Allergies.md': '---\nprivate: true\ntags: cachesync\n---\nPenicillin. Carry the card.\n',
      'Trips/Camping list.md': 'Water filter, stove. #cachesync\n',
    });
    final e = (await tester.runAsync(() => k.nb.entry(_id(k.mem.text['Health/Allergies.md']!))))!;
    await _show(tester, NotebookScreen(deps: k.deps, notebookId: e.notebookId));
    await snap(tester, _out, '6a-private-in-list');
    await _show(tester, EntryEditor(notebook: k.nb, book: k.nb.notebook(e.notebookId)!, places: PlaceChoices.none, entry: e, connections: k.c, now: k.deps.now));
    await snap(tester, _out, '6b-private-entry');
  });

  testWidgets('7: What\'s new in 1.0.30 (the owner\'s lines), phone light and dark, iPad', (tester) async {
    final lines = whatsNewLines(File('assets/whats_new.md').readAsStringSync(), '1.0.30');
    expect(lines.length, 11);
    for (final (name, size, ratio, theme) in [
      ('phone', const Size(430, 932), 3.0, CacheThemeId.light),
      ('phone-dark', const Size(430, 932), 3.0, CacheThemeId.dark),
      ('ipad', const Size(820, 1180), 2.0, CacheThemeId.light),
    ]) {
      phone(tester, size: size, ratio: ratio);
      await tester.pumpWidget(shotApp(
          Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showWhatsNew(c, version: '1.0.30', lines: lines), child: const Text('open'))))),
          theme: theme));
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await snap(tester, _out, '7-whats-new-1.0.30-$name');
    }
  });
}

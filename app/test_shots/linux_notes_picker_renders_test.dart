// Cache on Linux: connecting an Obsidian vault or Logseq graph with Cache's own folder picker (a browser cannot hand over a folder
// path). Drawn by the real widgets with sample data, dark theme, in the desktop shell's Settings layout at 1440x900 and alone at
// phone width 412x915. Pictures in test_shots/linux-notes-picker/. Not part of the test suite.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/desktop/desktop_shell.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart' show NotebookDeps;
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/device_folder_picker.dart';
import 'package:cache/notebook/sync/folder.dart';
import 'package:cache/notebook/sync/sync_engine.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const _out = 'linux-notes-picker';

class _Mem implements SyncFolder {
  Completer<void>? gate;
  final Map<String, String> text = {'Trips/Camping list.md': 'Water filter, stove.\n'};
  @override
  String get display => 'Vault';
  @override
  Future<bool> reachable() async => true;
  @override
  Future<List<FolderFile>> list(String dir) async {
    if (gate != null) await gate!.future;
    return [for (final p in text.keys) FolderFile(p, 0, text[p]!.length)];
  }

  @override
  Future<String?> readText(String path) async => text[path];
  @override
  Future<Uint8List?> readBytes(String path) async => null;
  @override
  Future<void> writeText(String path, String t) async => text[path] = t;
  @override
  Future<void> writeBytes(String path, Uint8List b) async {}
  @override
  Future<void> delete(String path) async => text.remove(path);
  @override
  Future<bool> exists(String path) async => text.containsKey(path);
}

/// The computer's folders, as the Cache side would list them.
const _home = '/home/user';
final Map<String, (NotesKind, List<DeviceFolderEntry>)> _tree = {
  '/home': (NotesKind.none, [DeviceFolderEntry('user')]),
  _home: (NotesKind.none, [
    DeviceFolderEntry('Desktop'),
    DeviceFolderEntry('Documents'),
    DeviceFolderEntry('Downloads'),
    DeviceFolderEntry('Music'),
    DeviceFolderEntry('Pictures'),
    DeviceFolderEntry('Notes', NotesKind.obsidian),
  ]),
  '$_home/Documents': (NotesKind.none, [
    DeviceFolderEntry('Field manuals'),
    DeviceFolderEntry('Trip planning'),
    DeviceFolderEntry('Vault', NotesKind.obsidian),
    DeviceFolderEntry('Journal graph', NotesKind.logseq),
  ]),
  '$_home/Documents/Vault': (NotesKind.obsidian, [DeviceFolderEntry('Daily'), DeviceFolderEntry('Trips'), DeviceFolderEntry('Templates')]),
  '$_home/Documents/Trip planning': (NotesKind.none, []),
};

String? _parent(String p) => p == '/' ? null : (p.lastIndexOf('/') <= 0 ? '/' : p.substring(0, p.lastIndexOf('/')));

Future<DeviceListing> _list(String? path) async {
  final p = path == null || path == '~' ? _home : path;
  if (p.contains('Private')) throw const FileSystemException('Permission denied');
  final e = _tree[p];
  if (e == null) throw const FileSystemException('No such folder');
  return DeviceListing(path: p, home: _home, parent: _parent(p), kind: e.$1, folders: e.$2);
}

const _rows = [
  ('Cache model and web search', 'Gemma 4 E2B · web search off'),
  ('Maps', 'Idaho Falls, Twin Falls · miles'),
  ('Weather and alerts', '4 sources · 2 places'),
  ('Notifications', 'Serious alerts · quiet 10 PM-6 AM'),
  ('Storage', '41.0 GB free'),
  ('Sharing and sync', 'Off'),
  ('Appearance', 'Dark'),
];

Widget _settingsList() => Scaffold(
  appBar: AppBar(title: const Text('Settings')),
  body: ListView(children: [for (final r in _rows) ListTile(minTileHeight: 52, title: Text(r.$1), subtitle: Text(r.$2))]),
);

const Map<String, Size> _sizes = {'1440x900': Size(1440, 900), '412x915': Size(412, 915)};

void main() {
  setUpAll(loadShotFonts);

  for (final entry in _sizes.entries) {
    final size = entry.value;
    final wide = size.width >= 1280;
    final ratio = wide ? 1.0 : 2.0;
    final tag = entry.key;

    Future<void> settle(WidgetTester tester, [int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<void> draw(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = size * ratio;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
      final shown = !wide
          ? page
          : DesktopShell(
              atHome: false,
              module: ModuleId.settings,
              onHome: () {},
              onModule: (_) {},
              onModuleOptions: (c, m) {},
              child: TwoPane(key: UniqueKey(), list: _settingsList(), initialKey: 'page', initial: (_) => page),
            );
      await tester.pumpWidget(shotApp(shown, theme: CacheThemeId.dark, insets: wide ? EdgeInsets.zero : const EdgeInsets.only(top: 47, bottom: 34), desktop: wide));
      await settle(tester);
    }

    Future<void> shot(WidgetTester tester, String name) async {
      final e = tester.takeException();
      // ignore: avoid_print
      print('PICKER-SHOT $tag-$name${e == null ? '' : ' EXC ${e.toString().split('\n').first}'}');
      await snap(tester, _out, '$tag-$name');
    }

    Future<(NotebookConnections, _Mem)> rig(WidgetTester tester, {bool connect = false, bool hold = false}) async {
      final nb = fakeNotebook(FakeNotebookBackend());
      final mem = _Mem();
      if (hold) mem.gate = Completer<void>();
      final dir = Directory.systemTemp.createTempSync('cache-picker-shots-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final c = NotebookConnections(notebook: nb, dir: () async => dir, folderFor: (_) => mem, clock: () => DateTime(2026, 11, 23, 17, 2));
      await tester.runAsync(() async {
        await nb.start();
        await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Camping trip', fields: [], sort: NotebookSort.recent));
        await c.init();
        if (connect) await c.connect(SyncKind.obsidian, '$_home/Documents/Vault', display: '$_home/Documents/Vault');
      });
      return (c, mem);
    }

    ConnectionsScreen conn(NotebookConnections c, {PickFolder? pick}) =>
        ConnectionsScreen(connections: c, pickFolder: pick ?? () async => null, phone: false);

    testWidgets('1 entry point ($tag)', (tester) async {
      final (c, _) = await rig(tester);
      await draw(tester, conn(c));
      await shot(tester, '1a-entry-connections');
      await tester.tap(find.byKey(const ValueKey('connect-logseq')));
      await settle(tester);
      await shot(tester, '1b-entry-logseq-choice');
    });

    testWidgets('2 picker ($tag)', (tester) async {
      await draw(tester, DeviceFolderPicker(list: _list, home: _home));
      await shot(tester, '2a-picker-home');
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await settle(tester);
      await shot(tester, '2b-picker-documents-marked');
      await tester.tap(find.byKey(const ValueKey('folder-Vault')));
      await settle(tester);
      await shot(tester, '2c-picker-inside-vault');
      await draw(tester, DeviceFolderPicker(list: _list, home: _home, start: '$_home/Documents/Trip planning'));
      await shot(tester, '2d-picker-empty');
      await draw(tester, DeviceFolderPicker(list: _list, home: _home, start: '$_home/Private'));
      await shot(tester, '2e-picker-unreadable');
    });

    // The Notebooks placement (decided by cache-pm): the real Notebooks screen, Notebooks > menu > Connections, as the phone does it.
    Future<NotebookConnections> notebooksPage(WidgetTester tester) async {
      final (c, _) = await rig(tester);
      final nb = (c as dynamic).notebook as dynamic;
      await tester.runAsync(() async {
        await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Trail log', fields: [], sort: NotebookSort.recent));
        await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Garden', fields: [], sort: NotebookSort.recent));
      });
      tester.view.physicalSize = size * ratio;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
      final deps = NotebookDeps(notebook: nb, places: PlaceChoices.none, connections: c, now: () => DateTime(2026, 11, 23, 17, 2));
      final page = NotebooksScreen(deps: deps);
      final shown = !wide ? page : DesktopShell(atHome: false, module: ModuleId.notebooks, onHome: () {}, onModule: (_) {}, onModuleOptions: (c, m) {}, child: page);
      await tester.pumpWidget(shotApp(shown, theme: CacheThemeId.dark, insets: wide ? EdgeInsets.zero : const EdgeInsets.only(top: 47, bottom: 34), desktop: wide));
      await settle(tester, 10);
      if (wide) {
        // On the desktop the page opens in the detail pane beside the shelf (openDetail), so the rail and the shelf stay.
        openDetail(tester.element(find.byKey(const ValueKey('notebooks-menu'))), key: 'connections', builder: (_) => ConnectionsScreen(connections: c, pickFolder: () async => null, phone: false));
      } else {
        await tester.tap(find.byKey(const ValueKey('notebooks-menu')));
        await settle(tester);
        await tester.tap(find.text('Connections'));
      }
      await settle(tester, 10);
      return c;
    }

    testWidgets('4 Notebooks placement ($tag)', (tester) async {
      await notebooksPage(tester);
      await shot(tester, '1a-entry-connections-notebooks');
      final nav = Navigator.of(tester.element(find.byType(ConnectionsScreen)));
      nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFolderPicker(list: _list, home: _home)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await settle(tester);
      await shot(tester, '2b-picker-documents-marked-notebooks');
    });

    testWidgets('3 connected row ($tag)', (tester) async {
      var (c, mem) = await rig(tester, connect: true, hold: true);
      await draw(tester, conn(c));
      await shot(tester, '3a-connected-syncing');
      mem.gate!.complete();
      await tester.runAsync(() async {
        while (c.syncing) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await draw(tester, conn(c));
      await shot(tester, '3b-connected-synced');
      await tester.tap(find.byKey(const ValueKey('menu-obsidian')));
      await settle(tester);
      await shot(tester, '3c-connected-menu');
    });
  }
}

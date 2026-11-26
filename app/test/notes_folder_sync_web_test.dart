// Cache on Linux: connecting an Obsidian vault or a Logseq graph with Cache's own folder picker (a browser cannot hand over a folder
// path). The picker lists the folders of the computer Cache runs on; the connections are kept and synced there (nbfolders.*), the page
// only asks for their state and sends the person's choices. Notebooks > Connections opens in the detail pane on the desktop.
import 'dart:async';

import 'package:cache/linux_ui.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/sync/connections_web.dart';
import 'package:cache/notebook/sync/device_folder_picker.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart' show NotebookDeps;
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException, CoreTransport;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

const _home = '/home/user';

/// The computer's folders as the helper's `devfs.list` lists them: path -> (its own kind, its subfolders (name, kind)).
final Map<String, (String, List<(String, String)>)> _tree = {
  '/': ('none', [('home', 'none'), ('etc', 'none')]),
  '/home': ('none', [('user', 'none')]),
  _home: ('none', [('Documents', 'none'), ('Music', 'none'), ('Notes', 'obsidian')]),
  '$_home/Documents': ('none', [('Field manuals', 'none'), ('Vault', 'obsidian'), ('Journal graph', 'logseq')]),
  '$_home/Documents/Vault': ('obsidian', [('Daily', 'none'), ('Trips', 'none')]),
  '$_home/Documents/Journal graph': ('logseq', []),
  '$_home/Music': ('none', []),
};

String? _parent(String p) => p == '/' ? null : (p.lastIndexOf('/') <= 0 ? '/' : p.substring(0, p.lastIndexOf('/')));

/// Cache on the computer, as a browser reaches it: `devfs.list` and `nbfolders.*`, with the answers of the helper.
class FakeComputer implements CoreTransport {
  final List<String> ops = [];
  final List<Map<String, dynamic>> opArgs = [];
  final List<Map<String, dynamic>> targets = [];
  String? connectError;
  bool down = false;

  /// Folders that cannot be read.
  final Set<String> locked = {};

  /// The next `nbfolders.sync` waits for this.
  Completer<void>? syncGate;
  Map<String, dynamic> extra = {};

  int get listCalls => ops.where((o) => o == 'devfs.list').length;

  @override
  Future<dynamic> call(String op, Map<String, dynamic> args) async {
    ops.add(op);
    opArgs.add(args);
    if (down) throw const CacheSearchException('io_error', 'no answer');
    switch (op) {
      case 'devfs.list':
        final p = (args['path'] as String?) ?? _home;
        if (locked.contains(p)) throw const CacheSearchException('io_error', 'Permission denied');
        final e = _tree[p] ?? (throw const CacheSearchException('not_found', 'no such folder'));
        return {
          'path': p,
          'home': _home,
          'parent': _parent(p),
          'kind': e.$1,
          'folders': [for (final f in e.$2) {'name': f.$1, 'kind': f.$2, 'readable': true}],
        };
      case 'nbfolders.state':
        return {'syncing': false, 'targets': [for (final t in targets) {...t, ...extra}]};
      case 'nbfolders.connect':
        if (connectError != null) return {'error': connectError};
        final id = args['kind'] == 'obsidian' ? 'obsidian' : 'logseq';
        targets.removeWhere((t) => t['id'] == id);
        targets.add({'id': id, 'kind': args['kind'], 'path': args['path'], 'paused': false, 'tag': '#cachesync', 'status': 'Synced 5:02 PM', 'synced_at': DateTime(2026, 11, 23, 17, 2).millisecondsSinceEpoch});
        return {};
      case 'nbfolders.disconnect':
        targets.removeWhere((t) => t['id'] == args['id']);
        return null;
      case 'nbfolders.pause':
        for (final t in targets) {
          if (t['id'] == args['id']) {
            t['paused'] = args['paused'];
            t['status'] = args['paused'] == true ? 'Paused.' : 'Synced 5:02 PM';
          }
        }
        return null;
      case 'nbfolders.sync':
        await syncGate?.future;
        return null;
    }
    return null;
  }

  @override
  Future<void> close() async {}
}

Future<DeviceListing> _list(String? path) async {
  final p = path ?? _home;
  final e = _tree[p] ?? (throw const FormatException('no such folder'));
  NotesKind k(String s) => s == 'obsidian' ? NotesKind.obsidian : (s == 'logseq' ? NotesKind.logseq : NotesKind.none);
  return DeviceListing(path: p, home: _home, parent: _parent(p), kind: k(e.$1), folders: [for (final f in e.$2) DeviceFolderEntry(f.$1, k(f.$2))]);
}

void _window(WidgetTester tester, Size size, [double ratio = 1]) {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
}

/// The picker as a page that was pushed, so what it pops can be read.
class _Opener extends StatelessWidget {
  const _Opener(this.list, this.result, {this.start});
  final ListDeviceFolder list;
  final ValueChanged<({String path, String display})?> result;
  final String? start;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('open'),
            onPressed: () async => result(await Navigator.of(context).push<({String path, String display})>(MaterialPageRoute(builder: (_) => DeviceFolderPicker(list: list, start: start)))),
            child: const Text('open'),
          ),
        ),
      );
}

void main() {
  setUp(() => debugLinuxUi = true);
  tearDown(() => debugLinuxUi = null);

  Widget app(Widget home) => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: home);

  group('the picker', () {
    Future<void> open(WidgetTester tester, ValueChanged<({String path, String display})?> result, {ListDeviceFolder list = _list, String? start}) async {
      _window(tester, const Size(1440, 900));
      await tester.pumpWidget(app(_Opener(list, result, start: start)));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
    }

    testWidgets('it opens at the home folder: the title, "Folders on this computer", the crumbs, the subfolders, the full path and Use this folder', (tester) async {
      await open(tester, (_) {});
      expect(find.text('Choose a folder'), findsOneWidget);
      expect(find.text('Folders on this computer'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.byKey(const ValueKey('folder-Documents')), findsOneWidget);
      expect(find.byKey(const ValueKey('folder-Music')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, _home);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNotNull);
      expect(find.textContaining('server'), findsNothing);
    });

    testWidgets('a vault and a graph are marked and have a one-tap Use; other folders have neither', (tester) async {
      await open(tester, (_) {});
      expect(find.descendant(of: find.byKey(const ValueKey('folder-Notes')), matching: find.text('Obsidian vault')), findsOneWidget);
      expect(find.byKey(const ValueKey('use-Notes')), findsOneWidget);
      expect(find.byKey(const ValueKey('use-Documents')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const ValueKey('folder-Vault')), matching: find.text('Obsidian vault')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('folder-Journal graph')), matching: find.text('Logseq graph')), findsOneWidget);
      expect(find.byKey(const ValueKey('use-Field manuals')), findsNothing);
    });

    testWidgets('Use on a marked row chooses it without opening it, and gives the path as the phone gives (path, display)', (tester) async {
      ({String path, String display})? got;
      var done = false;
      await open(tester, (r) {
        got = r;
        done = true;
      });
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-Journal graph')));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(got!.path, '$_home/Documents/Journal graph');
      expect(find.text('Choose a folder'), findsNothing); // the page closed
    });

    testWidgets('a tap on a folder opens it with a spinner while it loads; the crumbs say where you are, the last one is bold and not a link, and Home goes back', (tester) async {
      final gate = Completer<void>();
      Future<DeviceListing> slow(String? p) async {
        if (p == '$_home/Documents') await gate.future;
        return _list(p);
      }

      await open(tester, (_) {}, list: slow);
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNull, reason: 'while loading');
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, '$_home/Documents');
      final last = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('picker-path')), matching: find.text('Documents')));
      expect(last.style!.fontWeight, FontWeight.w600);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('picker-path')), matching: find.text('Home')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, _home);
    });

    testWidgets('inside a vault a line says so; Use this folder chooses the folder you are in', (tester) async {
      ({String path, String display})? got;
      await open(tester, (r) => got = r, start: '$_home/Documents/Vault');
      expect(find.byKey(const ValueKey('picker-this-kind')), findsOneWidget);
      expect(find.text('This folder is an Obsidian vault.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('picker-use')));
      await tester.pumpAndSettle();
      expect(got!.path, '$_home/Documents/Vault');
    });

    testWidgets('Up goes one folder up, past home to "/", where it is disabled; outside home the crumbs start at "/"', (tester) async {
      await open(tester, (_) {});
      await tester.tap(find.byKey(const ValueKey('picker-up')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, '/home');
      expect(find.text('Home'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('picker-up')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, '/');
      expect(find.byKey(const ValueKey('folder-home')), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('picker-up'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('folder-home')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, '/home');
    });

    testWidgets('a folder with no subfolders says so and can still be used', (tester) async {
      ({String path, String display})? got;
      await open(tester, (r) => got = r, start: '$_home/Music');
      expect(find.text('No folders in here.'), findsOneWidget);
      expect(find.text('Use this folder to keep your notes in it, or go up.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('picker-use')));
      await tester.pumpAndSettle();
      expect(got!.path, '$_home/Music');
    });

    testWidgets('a folder that cannot be read says so, cannot be used, offers Try again and Go up, and the Up arrow works', (tester) async {
      var locked = true;
      Future<DeviceListing> list(String? p) async {
        if (p == '$_home/Documents' && locked) throw const FormatException('Permission denied');
        return _list(p);
      }

      await open(tester, (_) {}, list: list);
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      expect(find.text("Can't open this folder."), findsOneWidget);
      expect(find.text('This computer does not let Cache read it. Choose another folder, or go up.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNull);
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, '$_home/Documents');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('picker-up'))).onPressed, isNotNull);
      // Try again, after it can be read
      locked = false;
      await tester.tap(find.byKey(const ValueKey('picker-retry')));
      await tester.pumpAndSettle();
      expect(find.text("Can't open this folder."), findsNothing);
      expect(find.byKey(const ValueKey('folder-Vault')), findsOneWidget);
      // and Go up from one that cannot
      locked = true;
      await tester.tap(find.byKey(const ValueKey('picker-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('picker-up-failed')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('picker-chosen'))).data, _home);
    });

    testWidgets('the back arrow leaves with nothing chosen', (tester) async {
      var done = false;
      ({String path, String display})? got = (path: 'x', display: 'x');
      await open(tester, (r) {
        got = r;
        done = true;
      });
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(got, isNull);
    });
  });

  group('the connections of this computer', () {
    late FakeComputer pc;
    late ServerConnections conns;

    setUp(() {
      pc = FakeComputer();
      conns = ServerConnections(pc, poll: const Duration(milliseconds: 50));
    });
    tearDown(() => conns.dispose());

    Future<void> show(WidgetTester tester) async {
      _window(tester, const Size(1440, 900));
      await tester.pumpWidget(app(ConnectionsScreen(connections: conns, phone: false)));
      await tester.pumpAndSettle();
    }

    testWidgets('nothing connected: Obsidian and Logseq each have Connect, and the page asks the computer for its state', (tester) async {
      await show(tester);
      expect(find.byKey(const ValueKey('connect-obsidian')), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-logseq')), findsOneWidget);
      expect(pc.ops, contains('nbfolders.state'));
    });

    testWidgets('Obsidian: Connect, the picker, Use on a marked folder; the computer is told the kind and the path, and the row shows the full path and the phone\'s status line', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a folder'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('use-Notes')));
      await tester.pumpAndSettle();
      final i = pc.ops.indexOf('nbfolders.connect');
      expect(pc.opArgs[i], {'kind': 'obsidian', 'path': '$_home/Notes'});
      expect(find.text('Choose a folder'), findsNothing);
      expect(find.byKey(const ValueKey('connect-obsidian')), findsNothing);
      expect(find.text('$_home/Notes'), findsOneWidget); // the full path, not only the name
      expect(find.byKey(const ValueKey('status-obsidian')), findsOneWidget);
      expect(find.text('Synced 5:02 PM'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-obsidian')), findsOneWidget);
    });

    testWidgets('Logseq asks which kind first (the phone\'s sheet), then the picker; Logseq 2 is the export kind', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('connect-logseq')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('logseq-files')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('logseq-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-Journal graph')));
      await tester.pumpAndSettle();
      final i = pc.ops.indexOf('nbfolders.connect');
      expect(pc.opArgs[i], {'kind': 'logseqExport', 'path': '$_home/Documents/Journal graph'});
      expect(find.textContaining('export only'), findsOneWidget);
      expect(find.textContaining('$_home/Documents/Journal graph'), findsOneWidget);
    });

    testWidgets('Use this folder connects the folder you are in, from any depth', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('picker-use')));
      await tester.pumpAndSettle();
      expect(pc.opArgs[pc.ops.indexOf('nbfolders.connect')]['path'], '$_home/Documents');
    });

    testWidgets('a folder the computer cannot use gives the phone\'s snack bar and stays on Connections with Connect', (tester) async {
      pc.connectError = "Can't reach the folder.";
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-Notes')));
      await tester.pumpAndSettle();
      expect(find.text("Can't reach the folder."), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-obsidian')), findsOneWidget);
    });

    testWidgets('a computer that does not answer a connect gives the same snack bar', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-Documents')));
      await tester.pumpAndSettle();
      pc.down = true;
      await tester.tap(find.byKey(const ValueKey('use-Vault')));
      await tester.pumpAndSettle();
      expect(find.text("Can't reach the folder."), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-obsidian')), findsOneWidget);
      pc.down = false;
    });

    Future<void> connected(WidgetTester tester, {Map<String, dynamic> extra = const {}}) async {
      pc.targets.add({
        'id': 'obsidian',
        'kind': 'obsidian',
        'path': '$_home/Documents/Vault',
        'paused': false,
        'tag': '#cachesync',
        'status': 'Synced 5:02 PM',
        'synced_at': DateTime(2026, 11, 23, 17, 2).millisecondsSinceEpoch,
        ...extra,
      });
      await show(tester);
    }

    testWidgets('the connected row: the full path, the status in this browser\'s time, the import tag, and no Connect', (tester) async {
      await connected(tester);
      expect(find.text('$_home/Documents/Vault'), findsOneWidget);
      expect(find.text('Synced 5:02 PM'), findsOneWidget);
      expect(find.byKey(const ValueKey('import-tag-obsidian')), findsOneWidget);
      expect(find.byKey(const ValueKey('connect-obsidian')), findsNothing);
      expect(find.byKey(const ValueKey('connect-logseq')), findsOneWidget);
      // not a phone: the note about Obsidian syncing only while it is open is not shown
      expect(find.byKey(const ValueKey('obsidian-phone-note')), findsNothing);
    });

    testWidgets('the row follows the computer: a new status and the notes of the last pass appear on their own', (tester) async {
      await connected(tester);
      pc.targets.single['status'] = "Can't reach the folder.";
      pc.targets.single['merged'] = ['Water'];
      pc.targets.single['kept_as_two'] = ['Trail'];
      pc.targets.single['not_added'] = 2;
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(find.text("Can't reach the folder."), findsOneWidget);
      expect(find.text('Changed in both places and merged: Water'), findsOneWidget);
      expect(find.text('Changed in the same words in both places; the other version is kept as a new entry: Trail'), findsOneWidget);
      expect(find.text('2 notes not added: Cache cannot change them.'), findsOneWidget);
    });

    testWidgets('the menu has Sync now, Pause and Disconnect; Sync now shows "Syncing..." at once and the result when the pass is done', (tester) async {
      await connected(tester);
      pc.syncGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('menu-obsidian')));
      await tester.pumpAndSettle();
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Syncing...'), findsOneWidget);
      expect(pc.ops, contains('nbfolders.sync'));
      pc.syncGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Syncing...'), findsNothing);
      expect(find.text('Synced 5:02 PM'), findsOneWidget);
    });

    testWidgets('Pause says "Paused." and the menu offers Resume; Resume syncs again', (tester) async {
      await connected(tester);
      await tester.tap(find.byKey(const ValueKey('menu-obsidian')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(pc.opArgs[pc.ops.indexOf('nbfolders.pause')], {'id': 'obsidian', 'paused': true});
      expect(find.text('Paused.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu-obsidian')));
      await tester.pumpAndSettle();
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(pc.opArgs[pc.ops.lastIndexOf('nbfolders.pause')], {'id': 'obsidian', 'paused': false});
      expect(find.text('Synced 5:02 PM'), findsOneWidget);
    });

    testWidgets('Disconnect takes the row away and Connect comes back', (tester) async {
      await connected(tester);
      await tester.tap(find.byKey(const ValueKey('menu-obsidian')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(pc.opArgs[pc.ops.indexOf('nbfolders.disconnect')], {'id': 'obsidian'});
      expect(find.byKey(const ValueKey('connect-obsidian')), findsOneWidget);
      expect(find.text('$_home/Documents/Vault'), findsNothing);
    });

    testWidgets('a decision (an entry removed outside) is shown with the phone\'s buttons and sent to the computer', (tester) async {
      await connected(tester, extra: {
        'status': '1 change needs a decision',
        'conflicts': [
          {'entry': 'e1', 'kind': 'removedOutside', 'title': 'Water', 'path': 'Journal/Water.md'}
        ],
      });
      expect(find.text('Removed in the folder: Water'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('conflict-keep-cache')));
      await tester.pumpAndSettle();
      expect(pc.opArgs[pc.ops.indexOf('nbfolders.resolve')], {'id': 'obsidian', 'entry': 'e1', 'kind': 'removedOutside', 'title': 'Water', 'path': 'Journal/Water.md', 'keep_cache': true});
    });

    testWidgets('the polling stops when the page is left', (tester) async {
      await connected(tester);
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      final n = pc.ops.length;
      await tester.pump(const Duration(milliseconds: 300));
      expect(pc.ops.length, n);
    });
  });

  group('in Notebooks', () {
    late FakeComputer pc;
    late ServerConnections conns;
    late NotebookState nb;

    setUp(() {
      pc = FakeComputer();
      conns = ServerConnections(pc, poll: const Duration(milliseconds: 50));
      nb = fakeNotebook(FakeNotebookBackend());
    });
    tearDown(() => conns.dispose());

    Future<void> pump(WidgetTester tester, Size size, [double ratio = 1]) async {
      _window(tester, size, ratio);
      await nb.start();
      await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Trail log', fields: [], sort: NotebookSort.recent));
      final deps = NotebookDeps(notebook: nb, places: PlaceChoices.none, deviceConnections: conns, now: () => DateTime(2026, 11, 23, 17, 2));
      await tester.pumpWidget(app(NotebooksScreen(deps: deps)));
      await tester.pumpAndSettle();
    }

    testWidgets('desktop: the menu\'s Connections opens in the detail pane, beside the shelf, which stays; the picker opens in the pane too', (tester) async {
      await pump(tester, const Size(1440, 900));
      expect(find.text('Trail log'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notebooks-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connections'));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionsScreen), findsOneWidget);
      expect(find.text('Trail log'), findsOneWidget, reason: 'the shelf stays');
      expect(find.byKey(const ValueKey('notebooks-menu')), findsOneWidget);
      expect(tester.getTopLeft(find.byType(ConnectionsScreen)).dx, greaterThan(300), reason: 'beside the shelf, not over it');
      await tester.tap(find.byKey(const ValueKey('connect-obsidian')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a folder'), findsOneWidget);
      expect(find.text('Trail log'), findsOneWidget, reason: 'the shelf stays under the picker too');
      expect(tester.getTopLeft(find.text('Choose a folder')).dx, greaterThan(300));
    });

    testWidgets('a phone: Connections is a page of its own with a back arrow, as before', (tester) async {
      await pump(tester, const Size(412, 915), 2);
      await tester.tap(find.byKey(const ValueKey('notebooks-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connections'));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionsScreen), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('Trail log'), findsNothing);
    });
  });
}

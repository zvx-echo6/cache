// Sharing and sync, per item: each kind's items with their own switches carried by the kind's one share (the engine's `off`),
// what earlier versions left (kinds ticked before items existed, the Shared folder), private notebooks, Sync now for
// everything, a kind or an item, and the linked device's page.

import 'dart:convert';
import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

/// Sharing on a fake engine in a temp folder, with Library (ZIMs and libraries), Models and Notebooks (one private).
class _Rig {
  _Rig(this.dir) {
    for (final d in ['zims', 'libraries', 'models', 'notebook-share']) {
      Directory('${dir.path}/$d').createSync(recursive: true);
    }
  }

  final Directory dir;
  final sync = FakeSync();
  final configs = <Map<String, Object?>>[];

  /// The private notebook's "Include in sync and sharing".
  bool privateIncluded = false;
  final privateSet = <bool>[];

  late final List<DataKind> kinds = [
    DataKind(
      id: 'library',
      label: 'Library',
      icon: Icons.menu_book_outlined,
      shared: () => {'library': Directory('${dir.path}/zims'), 'libraries': Directory('${dir.path}/libraries')},
      items: () => const [
        ShareItem(share: 'library', path: 'wikimed.zim', name: 'Medical encyclopedia', bytes: 1400 << 20),
        ShareItem(share: 'library', path: 'canning.zim', name: 'Home canning', bytes: 29 << 20),
        ShareItem(share: 'libraries', path: 'field-manuals', name: 'Field manuals', bytes: 7700 << 20),
      ],
      remoteItem: libraryRemoteItem,
    ),
    DataKind(
      id: 'models',
      label: 'Models',
      icon: Icons.memory,
      shared: () => {'models': Directory('${dir.path}/models')},
      items: () => const [ShareItem(share: 'models', path: 'gemma.gguf', name: 'Gemma 4 E2B', bytes: 3200 << 20)],
      remoteItem: modelRemoteItem,
    ),
    DataKind(
      id: 'notebooks',
      label: 'Notebooks',
      icon: Icons.book_outlined,
      shared: () => {'notebooks': Directory('${dir.path}/notebook-share')},
      items: () => [
        const ShareItem(share: 'notebooks', path: 'Journal', name: 'Journal'),
        ShareItem(share: 'notebooks', path: 'Health log', name: 'Health log', private: true, on: privateIncluded),
      ],
      remoteItem: notebookRemoteItem,
      setPrivate: (it, on) async {
        privateSet.add(on);
        privateIncluded = on;
      },
    ),
  ];

  DataKind kind(String id) => kinds.firstWhere((k) => k.id == id);

  SharingState make() => SharingState(
    policy: testPolicy(wifi: true),
    supportDir: () async => dir,
    kinds: kinds,
    opener: (c) async {
      configs.add(c);
      return sync;
    },
  );

  List<Map<String, Object?>> calls(String m) => sync.argsOf[m] ?? const [];
}

Future<_Rig> _rig() async => _Rig(await Directory.systemTemp.createTemp('sharing-items'));

void main() {
  test('each item has its own switch, and the kind\'s one share carries the items switched off', () async {
    final r = await _rig();
    // Desk holds a ZIM this device does not.
    r.sync.items['library'] = [
      {'name': 'wikimed.zim', 'files': 1, 'bytes': 1400 << 20, 'peers': [{'peer': 'p1', 'peer_name': 'Desk', 'files': 1, 'bytes': 1400 << 20}]},
      {'name': 'wikipedia.zim', 'files': 0, 'bytes': 0, 'peers': [{'peer': 'p1', 'peer_name': 'Desk', 'files': 1, 'bytes': 118 << 30}]},
      {'name': 'wikimed.zim.pdfindex', 'files': 0, 'bytes': 0, 'peers': [{'peer': 'p1', 'peer_name': 'Desk', 'files': 3, 'bytes': 10}]},
    ];
    final s = r.make();
    await s.setUp();
    final lib = r.kind('library');
    await s.setShared(lib, true);
    expect([for (final c in r.calls('share_add')) c['id']], ['library', 'libraries'], reason: 'one share per folder of the kind, never one per item');

    final items = s.itemsOf(lib);
    expect([for (final i in items) i.item.name], ['Medical encyclopedia', 'Home canning', 'Field manuals', 'wikipedia'],
        reason: "this device's items, then what only a linked device holds; a file that is not a ZIM is not an item");
    final wikipedia = items.last;
    expect(wikipedia.here, isFalse);
    expect(wikipedia.peers, ['Desk']);
    expect(wikipedia.bytes, 118 << 30);
    expect(items.every((i) => s.itemOn(lib, i.item)), isTrue, reason: 'a kind switched on shares every item');

    // Two items off, one of them only on Desk: the share's list reaches the engine.
    await s.setItem(lib, items[1].item, false);
    await s.setItem(lib, wikipedia.item, false);
    expect(r.calls('set_off').last, {'id': 'library', 'off': ['canning.zim', 'wikipedia.zim']});
    expect(r.sync.off['libraries'], isNull, reason: 'the other folder of the kind has nothing off');
    expect(s.itemOn(lib, items[1].item), isFalse);
    expect(s.itemOn(lib, items[0].item), isTrue);
    // A library switched off goes to its own folder's list.
    await s.setItem(lib, items[2].item, false);
    expect(r.calls('set_off').last, {'id': 'libraries', 'off': ['field-manuals']});
    await s.setItem(lib, items[1].item, true);
    expect(r.calls('set_off').last, {'id': 'library', 'off': ['wikipedia.zim']});
    s.dispose();

    // A restart: the engine starts with the same lists.
    final again = r.make();
    await again.init();
    final off = r.configs.last['off'] as Map;
    expect(off['library'], ['wikipedia.zim']);
    expect(off['libraries'], ['field-manuals']);
    expect(off['models'], isEmpty);
    again.dispose();
    await r.dir.delete(recursive: true);
  });

  test("what earlier versions left: a kind that was ticked shares every item, one that wasn't has every item off", () async {
    final r = await _rig();
    // sharing.json as 1.0 wrote it, and the engine's shares as 1.0 left them: Library ticked, Models not.
    File('${r.dir.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': true}));
    r.sync.shares
      ..add({'id': 'library', 'name': 'Library (library)', 'path': '${r.dir.path}/zims'})
      ..add({'id': 'libraries', 'name': 'Library (libraries)', 'path': '${r.dir.path}/libraries'});
    final s = r.make();
    await s.init();
    expect(s.running, isTrue);
    final lib = r.kind('library'), models = r.kind('models');
    expect(s.kindOn(lib), isTrue);
    expect(s.itemsOf(lib).every((i) => s.itemOn(lib, i.item)), isTrue, reason: 'nothing that synced before stops');
    expect((r.configs.single['off'] as Map)['library'], isEmpty);
    expect((r.configs.single['off'] as Map)['libraries'], isEmpty);
    expect(s.kindOn(models), isFalse);
    expect(s.itemsOf(models).any((i) => s.itemOn(models, i.item)), isFalse, reason: 'a kind that was off starts with every item off');
    expect(r.calls('share_add'), isEmpty, reason: 'nothing new is shared at start');

    // Switching one item on in a kind that is off shares the kind with that item alone.
    r.sync.items['models'] = [
      {'name': 'gemma.gguf', 'files': 1, 'bytes': 1, 'peers': []},
      {'name': 'qwen.gguf', 'files': 0, 'bytes': 0, 'peers': [{'peer': 'p1', 'peer_name': 'Desk', 'files': 1, 'bytes': 5}]},
    ];
    await s.refreshItems();
    final qwen = s.itemsOf(models).firstWhere((i) => i.item.path == 'qwen.gguf').item;
    await s.setItem(models, qwen, true);
    expect(s.kindOn(models), isTrue);
    expect(r.calls('set_off').last, {'id': 'models', 'off': ['gemma.gguf']}, reason: 'given before the share is added');
    expect(r.sync.calls.lastIndexOf('set_off'), lessThan(r.sync.calls.lastIndexOf('share_add')));
    expect(s.itemOn(models, qwen), isTrue);
    // Switching the kind off and on again: every item.
    await s.setShared(models, false);
    expect(s.itemsOf(models).any((i) => s.itemOn(models, i.item)), isFalse);
    await s.setShared(models, true);
    expect(s.itemsOf(models).every((i) => s.itemOn(models, i.item)), isTrue);
    expect(r.calls('set_off').last, {'id': 'models', 'off': <String>[]});
    s.dispose();
    await r.dir.delete(recursive: true);
  });

  test('the Shared folder stops being shared at start, and its files stay where they are', () async {
    final r = await _rig();
    final shared = Directory('${r.dir.path}/Shared')..createSync();
    File('${shared.path}/plans.txt').writeAsStringSync('keep me');
    File('${r.dir.path}/sharing.json').writeAsStringSync(jsonEncode({'enabled': true}));
    r.sync.shares.add({'id': 'shared', 'name': 'Shared folder', 'path': shared.path});
    final s = r.make();
    await s.init();
    expect(r.calls('share_remove'), [
      {'id': 'shared'},
    ]);
    expect(s.shareOf('shared'), isNull);
    expect(File('${shared.path}/plans.txt').readAsStringSync(), 'keep me', reason: 'no data is lost');
    expect([for (final k in s.shareKinds) k.sharingLabel], ['Library', 'Models', 'Notebooks']);
    s.dispose();
    // Not asked again on the next start.
    final again = r.make();
    await again.init();
    expect(r.calls('share_remove'), hasLength(1));
    again.dispose();
    await r.dir.delete(recursive: true);
  });

  test('private notebooks are listed and start off, also when the kind is switched on', () async {
    final r = await _rig();
    final s = r.make();
    await s.setUp();
    final nb = r.kind('notebooks');
    expect((r.configs.single['off'] as Map)['notebooks'], ['Health log'], reason: 'off from the engine\'s start');
    await s.setShared(nb, true);
    final items = {for (final i in s.itemsOf(nb)) i.item.name: i.item};
    expect(items.keys, ['Journal', 'Health log']);
    expect(s.itemOn(nb, items['Journal']!), isTrue);
    expect(s.itemOn(nb, items['Health log']!), isFalse);
    expect(r.sync.off['notebooks'], isNull, reason: 'the engine already has it from its start');

    // Switched on: its "Include in sync and sharing", and the engine's list.
    await s.setItem(nb, items['Health log']!, true);
    expect(r.privateSet, [true]);
    expect(r.calls('set_off').last, {'id': 'notebooks', 'off': <String>[]});
    final now = s.itemsOf(nb).firstWhere((i) => i.item.private).item;
    expect(s.itemOn(nb, now), isTrue);
    await s.setItem(nb, now, false);
    expect(r.privateSet, [true, false]);
    expect(r.calls('set_off').last, {'id': 'notebooks', 'off': ['Health log']});
    s.dispose();
    await r.dir.delete(recursive: true);
  });

  testWidgets('Sync now: everything, a kind, an item', (tester) async {
    final r = await tester.runAsync(_rig);
    final s = r!.make();
    await tester.runAsync(s.setUp);
    await tester.runAsync(() => s.setShared(r.kind('library'), true));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();

    expect(find.text('Library'), findsOneWidget);
    expect(find.text('3 of 3 shared · 8.9 GB'), findsOneWidget);
    expect(find.text('Not shared'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('sync-all')));
    await tester.pump();
    expect(r.calls('sync_now').last, isEmpty, reason: 'Sync all now: every folder with every device');

    // The kind's page.
    await tester.tap(find.byKey(const ValueKey('share-library')));
    await tester.pumpAndSettle();
    expect(find.text('Share Library'), findsOneWidget);
    expect(find.text('Medical encyclopedia'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kind-sync')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(r.calls('sync_now').last, {
      'shares': ['library', 'libraries'],
    });

    // One item.
    await tester.tap(find.byTooltip('Sync Home canning now'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(r.calls('sync_now').last, {
      'share': 'library',
      'paths': ['canning.zim'],
    });

    // An item switched off on its page: its switch, and nothing to sync for it.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('item-library/canning.zim')), matching: find.byType(Switch)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(r.sync.off['library'], ['canning.zim']);
    final button = tester.widget<IconButton>(find.descendant(of: find.byKey(const ValueKey('item-library/canning.zim')), matching: find.byType(IconButton)));
    expect(button.onPressed, isNull);
    expect(find.text('2 of 3 shared · 8.9 GB'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    s.dispose();
    await tester.runAsync(() => r.dir.delete(recursive: true));
  });

  testWidgets("a linked device's page: status and free space, Sync now, Rename, Unlink", (tester) async {
    final r = await tester.runAsync(_rig);
    final s = r!.make();
    await tester.runAsync(s.setUp);
    r.sync.peers.add({
      'id': 'p1',
      'name': 'Desk',
      'linked': 1,
      'last_seen': DateTime.now().millisecondsSinceEpoch - 120000,
      'via': 'direct',
      'error': null,
      'free_bytes': 612 << 30,
    });
    await tester.runAsync(s.refresh);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('peer-p1')));
    await tester.pumpAndSettle();
    expect(find.text('Connected directly · 2 min ago'), findsOneWidget);
    expect(find.text('612.0 GB free'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('device-sync')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(r.calls('sync_now').last, {'peer': 'p1'}, reason: 'Sync now with this device only');

    await tester.tap(find.byKey(const ValueKey('device-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('peer-name')), 'Office');
    await tester.tap(find.text('Save'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(r.calls('set_peer_name').last, {'peer': 'p1', 'name': 'Office'});
    expect(find.text('Office'), findsOneWidget, reason: 'the page takes the new name');

    expect(find.text('It can no longer connect to this device. Files already here stay.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('device-unlink')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(r.calls('unlink').last, {'peer': 'p1'});
    expect(find.byKey(const ValueKey('peer-p1')), findsNothing, reason: 'back on Sharing and sync, the device is gone');
    expect(find.text('Show my link code'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    s.dispose();
    await tester.runAsync(() => r.dir.delete(recursive: true));
  });
}

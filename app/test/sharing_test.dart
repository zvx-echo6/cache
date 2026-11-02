import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/regions/regions_state.dart' show kMapLayersNotShared, kRegionsNotShared;
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

void main() {
  testWidgets('set up, link with a code, and tick a folder to share', (tester) async {
    final r = await SettingsRig.create(tester);
    await r.show(tester, SharingPage(sharing: r.sharing));
    expect(find.text('Set up sharing'), findsOneWidget);
    expect(r.sync.calls, isEmpty, reason: 'nothing starts before it is set up');

    await tester.runAsync(() => r.sharing.setUp());
    await tester.pump();
    expect(find.text('Test phone'), findsOneWidget);
    expect(find.text('Show my link code'), findsOneWidget);
    expect(r.sync.calls, contains('set_policy'), reason: 'the mobile-data rule is applied at start');
    expect(File('${r.dir.path}/sharing.json').existsSync(), isTrue, reason: 'set up is remembered');

    // Mobile data for downloads switched off on mobile data: the engine is told at once.
    r.probe.kind = ConnectionKind.mobile;
    r.settings.setMobileForDownloads(true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    r.sync.calls.clear();
    r.settings.setMobileForDownloads(false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(r.sync.policies.last, {'network': false});
    r.settings.setMobileForDownloads(true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(r.sync.policies.last, {'network': true});

    await tester.runAsync(() => r.sharing.link('CACHE1-TESTCODE'));
    await tester.pump();
    expect(find.text('Desk'), findsOneWidget);

    expect(r.sharing.shareOf('shared'), isNull);
    await tester.runAsync(() => r.sharing.setShared(r.sharing.kinds.single, true));
    await tester.pump();
    expect(r.sharing.shareOf('shared')?['path'], '${r.dir.path}/Shared');
    expect(Directory('${r.dir.path}/Shared').existsSync(), isTrue);
    expect(find.text('0 files · 0 B'), findsOneWidget);

    await tester.runAsync(() => r.sharing.setShared(r.sharing.kinds.single, false));
    await tester.pump();
    expect(r.sharing.shareOf('shared'), isNull);

    // A restart picks sharing up again without asking.
    final again = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], opener: (_) async => r.sync);
    await tester.runAsync(again.init);
    expect(again.running, isTrue);
    again.dispose();
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });

  testWidgets("what each device builds or caches for itself never syncs: a library's index, the regions' caches", (tester) async {
    final r = await SettingsRig.create(tester);
    final libs = Directory('${r.dir.path}/libraries')..createSync();
    Map<String, Object?>? config;
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: [
        DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined, shared: () => {'libraries': libs}, notShared: const {'libraries': kLibraryNotShared}),
        DataKind(
          id: 'regions',
          label: 'Regions',
          icon: Icons.map_outlined,
          shared: () => {'maps': Directory('${r.dir.path}/maps'), 'regions': Directory('${r.dir.path}/regions')},
          notShared: const {'maps': kMapLayersNotShared, 'regions': kRegionsNotShared},
        ),
        DataKind(id: 'shared', label: 'Shared folder', icon: Icons.folder_shared_outlined, shared: () => {'shared': Directory('${r.dir.path}/Shared')}),
      ],
      opener: (c) async {
        config = c;
        return r.sync;
      },
    );
    await tester.runAsync(sharing.setUp);
    // The engine is told at its start, before its first round, so nothing of an index goes out or comes in even once.
    // The same patterns cache_sync's tests check (packages/cache_search/native/cache_sync/tests/derived_folders.rs): fetched
    // indexes, the viewed-tile cache and TileJSON, and SQLite's -shm and -journal; every downloaded part still syncs.
    expect(config?['exclude'], {
      'libraries': ['*/index'],
      'maps': ['tiles.sqlite*', 'tilejson', '**/*-shm', '**/*-journal'],
      'regions': ['index', 'places/index', '**/*-shm', '**/*-journal'],
    });
    // The pattern names exactly where a library keeps its index: <libraries>/<library>/index.
    final item = LibraryItem(dir: Directory('${libs.path}${Platform.pathSeparator}first-aid'), size: 0);
    expect(item.indexPath.substring(libs.path.length + 1).replaceAll(Platform.pathSeparator, '/'), 'first-aid/index');
    sharing.dispose();
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });

  testWidgets('the search indexes are always shared once sharing is set up, and fetch only what this device holds', (tester) async {
    final r = await SettingsRig.create(tester);
    final configs = <Map<String, Object?>>[];
    SharingState make() => SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: const [],
      always: [
        AlwaysShared(
          id: 'indexes',
          name: 'Search indexes',
          dir: () => Directory('${r.dir.path}/search-indexes'),
          exclude: const ['**/.build', '**/*-shm'],
          localDeletes: const ['*/*/snap'],
          last: const ['*/*/snap/*/manifest.json'],
        ),
      ],
      opener: (c) async {
        configs.add(c);
        return r.sync;
      },
    );
    final sharing = make();
    await tester.runAsync(sharing.setUp);
    final c = configs.single;
    expect((c['exclude'] as Map)['indexes'], ['**/.build', '**/*-shm']);
    expect((c['local_deletes'] as Map)['indexes'], ['*/*/snap']);
    expect((c['last'] as Map)['indexes'], ['*/*/snap/*/manifest.json']);
    expect((c['only'] as Map)['indexes'], isEmpty, reason: 'nothing is fetched before the app says what this device holds');
    // Shared without any box ticked, its folder made.
    expect(r.sync.argsOf['share_add']!.single, {'id': 'indexes', 'name': 'Search indexes', 'path': '${r.dir.path}/search-indexes'});
    expect(Directory('${r.dir.path}/search-indexes').existsSync(), isTrue);

    await tester.runAsync(() => sharing.setOnly('indexes', ['zim/B', 'zim/A']));
    expect(r.sync.argsOf['set_only']!.single, {'id': 'indexes', 'only': ['zim/A', 'zim/B']});
    await tester.runAsync(() => sharing.setOnly('indexes', ['zim/A', 'zim/B']));
    expect(r.sync.argsOf['set_only'], hasLength(1), reason: 'the same list again is not sent');
    sharing.dispose();

    // A restart: already shared, so not added again; the engine starts with what was last set.
    final again = make();
    await tester.runAsync(() => again.setOnly('indexes', ['zim/A']));
    await tester.runAsync(again.init);
    expect((configs.last['only'] as Map)['indexes'], ['zim/A']);
    expect(r.sync.argsOf['share_add'], hasLength(1));
    again.dispose();
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });
}

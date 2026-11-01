import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
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

  testWidgets("a library's search index is built on each device and never syncs", (tester) async {
    final r = await SettingsRig.create(tester);
    final libs = Directory('${r.dir.path}/libraries')..createSync();
    Map<String, Object?>? config;
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: [
        DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined, shared: () => {'libraries': libs}, notShared: const {'libraries': kLibraryNotShared}),
        DataKind(id: 'shared', label: 'Shared folder', icon: Icons.folder_shared_outlined, shared: () => {'shared': Directory('${r.dir.path}/Shared')}),
      ],
      opener: (c) async {
        config = c;
        return r.sync;
      },
    );
    await tester.runAsync(sharing.setUp);
    // The engine is told at its start, before its first round, so nothing of an index goes out or comes in even once.
    expect(config?['exclude'], {'libraries': ['*/index']});
    // The pattern names exactly where a library keeps its index: <libraries>/<library>/index.
    final item = LibraryItem(dir: Directory('${libs.path}${Platform.pathSeparator}first-aid'), size: 0);
    expect(item.indexPath.substring(libs.path.length + 1).replaceAll(Platform.pathSeparator, '/'), 'first-aid/index');
    sharing.dispose();
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });
}

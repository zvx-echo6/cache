import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/sharing_state.dart';
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
}

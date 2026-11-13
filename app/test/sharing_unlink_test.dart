// Unlinking a device that is off: the Sharing page says an unlink is waiting for it (read from the engine's status `unlinks`) until
// the device has been told, and the Activity log shows the three lines the engine writes about unlinking. The engine's own
// behaviour is tested in packages/cache_search/native/cache_sync/tests/unlink.rs.

import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  Future<(SharingState, FakeSync)> open(WidgetTester tester, FakeSync sync) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('sharing-unlink')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => dir, kinds: const [], opener: (_) async => sync);
    await tester.runAsync(s.setUp);
    await tester.runAsync(s.refresh);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();
    return (s, sync);
  }

  testWidgets('a waiting unlink is noted on the page until the device has been told', (tester) async {
    final sync = FakeSync()
      ..peers.add({'id': 'p2', 'name': 'Desk tablet', 'linked': 1, 'last_seen': now - 60000, 'via': 'direct', 'error': null})
      ..unlinks.addAll([
        {'id': 'p1', 'name': 'Trail phone', 'old': false},
        {'id': 'p3', 'name': 'Old spare', 'old': true},
      ]);
    final (s, _) = await open(tester, sync);
    expect(find.text('Unlink waiting for Trail phone'), findsOneWidget);
    expect(find.text('Unlink waiting for Old spare'), findsOneWidget, reason: 'an older version is told the same way');
    expect(find.text('Desk tablet'), findsOneWidget, reason: 'the linked device is still listed');
    expect(s.unlinks.map((u) => u['id']), ['p1', 'p3']);

    // The engine told one of them: its note goes at the next status.
    sync.unlinks.removeWhere((u) => u['id'] == 'p1');
    await tester.runAsync(s.refresh);
    await tester.pump();
    expect(find.text('Unlink waiting for Trail phone'), findsNothing);
    expect(find.text('Unlink waiting for Old spare'), findsOneWidget);

    sync.unlinks.clear();
    await tester.runAsync(s.refresh);
    await tester.pump();
    expect(find.textContaining('Unlink waiting'), findsNothing);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a status from an engine with no unlinks field shows no note', (tester) async {
    final (s, _) = await open(tester, FakeSync()..peers.add({'id': 'p2', 'name': 'Desk tablet', 'linked': 1, 'last_seen': now, 'via': 'direct', 'error': null}));
    expect(find.textContaining('Unlink waiting'), findsNothing);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Activity log shows the three lines about unlinking', (tester) async {
    final sync = FakeSync()
      ..peers.add({'id': 'p2', 'name': 'Desk tablet', 'linked': 1, 'last_seen': now, 'via': 'direct', 'error': null})
      ..log.addAll([
        {'at': now - 60000, 'text': 'Trail phone unlinked this device.'}, // WORDING QUESTION (owner): draft, not yet approved
        {'at': now - 120000, 'text': 'Desk tablet was told it is unlinked.'}, // WORDING QUESTION (owner): draft, not yet approved
        {'at': now - 180000, 'text': 'Old spare was not reached within 30 days; it may still show this device.'}, // WORDING QUESTION (owner): draft, not yet approved
      ]);
    final (s, _) = await open(tester, sync);
    await tester.scrollUntilVisible(find.text('Activity'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Trail phone unlinked this device.'), findsOneWidget);
    expect(find.text('Desk tablet was told it is unlinked.'), findsOneWidget);
    expect(find.text('Old spare was not reached within 30 days; it may still show this device.'), findsOneWidget);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}

// A linked device's last seen time: what the row and its page say in each state, and Unlink for a device that never answered.

import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

String _words(Map<String, dynamic> p) => peerStatus(p).map((x) => x.text).join();

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const day = 24 * 3600 * 1000;

  test('the words for each state', () {
    expect(_words({'last_seen': null, 'error': null}), 'Checking…', reason: 'not looked for yet');
    expect(_words({'last_seen': null, 'error': 'not reachable'}), 'Not reachable · Never connected since linking');
    expect(_words({'last_seen': now - 5 * 60000, 'via': 'relay', 'error': null}), 'Connected through a relay · Last seen 5 min ago');
    expect(_words({'last_seen': now - 2 * 60000, 'via': 'direct', 'error': null}), 'Connected directly · Last seen 2 min ago');
    expect(_words({'last_seen': now - 3 * 3600000, 'error': 'not reachable'}), 'Not reachable · Last seen 3 h ago');
    // Kept from an earlier session, not looked for yet in this one: told as the past, not as a connection.
    expect(_words({'last_seen': now - 3 * 3600000, 'via': 'relay', 'live': false, 'error': null}), 'Last seen 3 h ago via a relay');
    expect(_words({'last_seen': now - 3 * 3600000, 'via': 'direct', 'live': false, 'error': null}), 'Last seen 3 h ago via direct');
  });

  test('Unlink is offered for a device never reached and linked more than 7 days ago', () {
    final at = DateTime.fromMillisecondsSinceEpoch(now);
    expect(neverReached({'last_seen': null, 'linked': now - 8 * day}, at), isTrue);
    expect(neverReached({'last_seen': null, 'linked': now - 6 * day}, at), isFalse);
    expect(neverReached({'last_seen': now - day, 'linked': now - 30 * day}, at), isFalse);
    expect(neverReached({'last_seen': null, 'linked': null}, at), isFalse);
  });

  Future<(SharingState, FakeSync, Directory)> open(WidgetTester tester, List<Map<String, Object?>> peers) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('peer-seen')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final sync = FakeSync()..peers.addAll(peers);
    final s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => dir, kinds: const [], opener: (_) async => sync);
    await tester.runAsync(s.setUp);
    await tester.runAsync(s.refresh);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();
    return (s, sync, dir);
  }

  testWidgets('a device never reached: the row says so, and its page offers Unlink', (tester) async {
    final (s, sync, _) = await open(tester, [
      {'id': 'p1', 'name': 'Android device', 'linked': now - 9 * day, 'last_seen': null, 'via': null, 'error': 'not reachable'},
    ]);
    expect(find.text('Not reachable · Never connected since linking'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peer-p1')));
    await tester.pumpAndSettle();
    expect(find.text('Not reachable · Never connected since linking'), findsOneWidget);
    expect(find.text("This device hasn't connected since it was linked."), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('device-unlink-never')), matching: find.text('Unlink')), findsOneWidget, reason: 'the button says Unlink');
    await tester.ensureVisible(find.byKey(const ValueKey('device-unlink-never')));
    await tester.tap(find.byKey(const ValueKey('device-unlink-never')));
    await tester.pumpAndSettle();
    // One question first: Cancel leaves it linked.
    expect(find.text('Unlink Android device?'), findsOneWidget);
    expect(find.text('It can no longer connect to this device. Files already here stay.'), findsNWidgets(2), reason: 'in the question and under the Unlink row');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sync.argsOf['unlink'], isNull, reason: 'Cancel does nothing');
    await tester.tap(find.byKey(const ValueKey('device-unlink-never')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-unlink')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(sync.argsOf['unlink']!.last, {'peer': 'p1'}, reason: 'the same call the Unlink row makes');
    expect(sync.peers, isEmpty);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a device linked a day ago and not reached yet has no Unlink line', (tester) async {
    final (s, _, _) = await open(tester, [
      {'id': 'p1', 'name': 'Desk', 'linked': now - day, 'last_seen': null, 'via': null, 'error': 'not reachable'},
    ]);
    await tester.tap(find.byKey(const ValueKey('peer-p1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-never')), findsNothing);
    expect(find.byKey(const ValueKey('device-unlink-never')), findsNothing);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a device seen 5 minutes ago through a relay says so on its row and page', (tester) async {
    final (s, _, _) = await open(tester, [
      {'id': 'p1', 'name': 'Tablet', 'linked': now - 20 * day, 'last_seen': now - 5 * 60000, 'via': 'relay', 'error': null},
    ]);
    expect(find.text('Connected through a relay · Last seen 5 min ago'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('peer-p1')));
    await tester.pumpAndSettle();
    expect(find.text('Connected through a relay · Last seen 5 min ago'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-unlink-never')), findsNothing);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}

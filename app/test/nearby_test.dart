// Nearby linking on "Show my link code": the list, Link, the three words on both sides, every way it ends, and the calls the page
// makes (open, poll, close), with the fake engine's scripted states.

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/nearby.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// Lets the page's half-second polls run, without waiting for the dialog's endless bar.
Future<void> tick(WidgetTester tester, [int ms = 600]) async {
  await tester.pump(Duration(milliseconds: ms));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  Future<SettingsRig> openCodePage(WidgetTester tester, {void Function(SettingsRig r)? script}) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.sharing.setUp());
    script?.call(r);
    await r.show(tester, SharingPage(sharing: r.sharing, share: (_) async {}));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('show-code')));
    await tick(tester);
    return r;
  }

  Future<void> closePage(WidgetTester tester, SettingsRig r) async {
    await r.dispose(tester);
  }

  testWidgets('the page: the code and QR, Copy code and Share link, and the Nearby list with an unnamed device', (tester) async {
    final r = await openCodePage(tester, script: (r) {
      r.sync.nearbyDevices.addAll([
        {'id': 'a', 'name': 'Pixel 8', 'via': 'wifi'},
        {'id': 'b', 'name': null, 'via': 'wifi'},
      ]);
    });
    expect(find.text('Show my link code'), findsWidgets);
    expect(find.byType(LinkQr), findsOneWidget);
    expect(find.text('CACHE1-TESTCODE'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(find.text('Share link'), findsOneWidget);
    expect(find.text('Nearby'.toUpperCase()), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text('Device nearby'), findsOneWidget, reason: 'a name not known yet');
    expect(find.text('Link'), findsNWidgets(2));
    expect(find.text('Same Wi-Fi · not linked'), findsNWidgets(2));
    await closePage(tester, r);
  });

  testWidgets('nothing nearby: it says so; an engine with no Nearby shows no list', (tester) async {
    var r = await openCodePage(tester);
    expect(find.text('No devices found yet.'), findsOneWidget);
    await closePage(tester, r);

    r = await openCodePage(tester, script: (r) => r.sync.pairingOpenError = Exception('no nearby'));
    expect(find.text('Nearby'.toUpperCase()), findsNothing);
    expect(find.text('Copy code'), findsOneWidget, reason: 'the code works as before');
    await closePage(tester, r);
  });

  testWidgets('Link goes to getting the words, then the words with Cancel and Link; Link then waiting, then linked and Done', (tester) async {
    final r = await openCodePage(tester, script: (r) => r.sync.nearbyDevices.add({'id': 'a', 'name': 'Pixel 8', 'via': 'wifi'}));
    await tester.tap(find.byKey(const ValueKey('nearby-link-a')));
    await tick(tester);
    expect(r.sync.argsOf['nearby_link']!.single, {'id': 'a'});
    expect(find.text('Link with Pixel 8?'), findsOneWidget);
    expect(find.text('Getting the three words…'), findsOneWidget);

    r.sync.nearbyState = {'state': 'words', 'words': ['maple', 'river', 'seven'], 'name': 'Pixel 8'};
    await tick(tester);
    expect(find.text('maple · river · seven'), findsOneWidget);
    expect(find.text('Check that both screens show the same three words.'), findsOneWidget);
    expect(find.byKey(const ValueKey('nearby-cancel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nearby-confirm')));
    await tick(tester);
    expect(r.sync.argsOf['nearby_answer']!.single, {'ok': true});
    expect(find.text('Waiting for Pixel 8 to confirm…'), findsOneWidget);

    // The other side confirmed: linked; the new device is in the list of linked devices when the page closes.
    r.sync.peers.add({'id': 'peer9', 'name': 'Pixel 8', 'linked': DateTime.now().millisecondsSinceEpoch, 'last_seen': null, 'via': null, 'error': null});
    r.sync.nearbyState = {'state': 'linked', 'name': 'Pixel 8'};
    await tick(tester);
    expect(find.text('Linked with Pixel 8'), findsOneWidget);
    expect(find.byType(LinkQr), findsOneWidget, reason: 'the page stays until Done');
    await tester.tap(find.byKey(const ValueKey('nearby-done')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tick(tester);
    expect(find.byType(LinkQr), findsNothing, reason: 'back on Sharing and sync');
    expect(r.sync.pairingOpen, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await closePage(tester, r);
  });

  testWidgets('Cancel on the words ends it at once and says so', (tester) async {
    final r = await openCodePage(tester, script: (r) {
      r.sync.nearbyDevices.add({'id': 'a', 'name': 'Pixel 8', 'via': 'wifi'});
      r.sync.nearbyState = {'state': 'words', 'words': ['maple', 'river', 'seven'], 'name': 'Pixel 8'};
    });
    await tick(tester);
    expect(find.text('maple · river · seven'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nearby-cancel')));
    await tester.pump();
    expect(find.text('maple · river · seven'), findsNothing);
    await tick(tester);
    expect(r.sync.argsOf['nearby_answer']!.single, {'ok': false});
    expect(find.text(nearbyDroppedMessage('cancelled')), findsOneWidget);
    expect(find.byKey(const ValueKey('nearby-words')), findsNothing, reason: 'it does not come back');
    await closePage(tester, r);
  });

  testWidgets('an incoming request shows "Link with Pixel 8?" at once, then the words', (tester) async {
    final r = await openCodePage(tester);
    expect(find.textContaining('Link with'), findsNothing);
    r.sync.nearbyState = {'state': 'incoming', 'name': 'Pixel 8'};
    await tick(tester);
    expect(find.text('Link with Pixel 8?'), findsOneWidget);
    r.sync.nearbyState = {'state': 'words', 'words': ['maple', 'river', 'seven'], 'name': 'Pixel 8'};
    await tick(tester);
    expect(find.text('Link with Pixel 8?'), findsOneWidget);
    expect(find.text('maple · river · seven'), findsOneWidget);
    await closePage(tester, r);
  });

  for (final e in {
    'cancelled': 'Link cancelled. Nothing was linked.',
    'timeout': 'No answer from the other device. Nothing was linked. Try again.',
    'mismatch': 'The words did not match, so nothing was linked. Try again.',
    'busy': 'Too many link requests. Try again in a minute.',
  }.entries) {
    testWidgets('dropped (${e.key}) closes the question and says why', (tester) async {
      final r = await openCodePage(tester);
      r.sync.nearbyState = {'state': 'incoming', 'name': 'Pixel 8'};
      await tick(tester);
      expect(find.text('Link with Pixel 8?'), findsOneWidget);
      r.sync.nearbyState = {'state': 'dropped', 'reason': e.key};
      await tick(tester);
      expect(find.text('Link with Pixel 8?'), findsNothing);
      expect(find.text(e.value), findsOneWidget);
      await closePage(tester, r);
    });
  }

  testWidgets('pairing_open when the page opens, polling every half second, pairing_close when it closes and polling stops', (tester) async {
    final r = await openCodePage(tester);
    expect(r.sync.pairingOpen, isTrue);
    expect(r.sync.calls.where((c) => c == 'pairing_open'), hasLength(1));
    final lists = r.sync.calls.where((c) => c == 'nearby_list').length;
    await tick(tester, 1000);
    final more = r.sync.calls.where((c) => c == 'nearby_list').length;
    expect(more - lists, inInclusiveRange(1, 3));
    expect(r.sync.calls.where((c) => c == 'nearby_state').length, more, reason: 'the list and the state are asked together');

    // Back: the page closes.
    await tester.tap(find.byTooltip('Back'));
    await tick(tester, 400);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tick(tester);
    expect(r.sync.pairingOpen, isFalse);
    expect(r.sync.calls.where((c) => c == 'pairing_close'), hasLength(1));
    final after = r.sync.calls.length;
    await tick(tester, 3000);
    expect(r.sync.calls.length, after, reason: 'no more asking after it closed');
    await closePage(tester, r);
  });
}

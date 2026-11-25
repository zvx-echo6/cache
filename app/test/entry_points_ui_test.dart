// Step 4's pages: Ways to connect, an entry point's page and the add form, the Remove confirm, and how Sharing and sync and a device's page
// say a device is reached (through an entry point, over radio) and what waits for a faster connection.

import 'dart:io';

import 'package:cache/screens/settings/entry_point_page.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/screens/settings/ways_to_connect_page.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

void main() {
  Future<(SharingState, FakeSync)> open(WidgetTester tester, FakeSync sync, Widget Function(SharingState) page) async {
    tester.view.physicalSize = const Size(1170, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('entries-ui')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
    await tester.runAsync(s.setUp);
    await tester.runAsync(s.refresh);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page(s)));
    await tester.pump();
    return (s, sync);
  }

  /// Lets a call to the fake engine finish and the page redraw.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  /// What a text field holds.
  String field(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

  group('Ways to connect', () {
    testWidgets('no entry points yet: the empty card, Wi-Fi and Bluetooth, and the add button', (tester) async {
      await open(tester, FakeSync(), (s) => WaysToConnectPage(sharing: s));
      expect(find.text("Cache uses every way that's on to reach your other devices."), findsOneWidget);
      expect(find.text('Wi-Fi and local network'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);
      expect(find.text('Over the internet'.toUpperCase()), findsOneWidget);
      expect(find.text("Add Reticulum entry points to reach your devices from anywhere. Every one that's on is used at the same time."), findsOneWidget);
      expect(find.text('No entry points yet'), findsOneWidget);
      expect(find.text('For now your devices connect only over Wi-Fi and Bluetooth.'), findsOneWidget);
      expect(find.text('Add an entry point'), findsOneWidget);
      expect(find.text('Cache comes with none and only uses ones you add. They sync to your other linked devices. Nothing goes through our servers.'), findsOneWidget);
    });

    testWidgets('each entry point says private, its port and where it stands', (tester) async {
      final sync = FakeSync()
        ..addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true)
        ..addEntry('b', 'reticulum.example.org', 4965, status: 'not_answering')
        ..addEntry('c', '192.168.1.20', 4242, private: true, network: 'lab', pass: true, on: false)
        ..addEntry('d', 'quiet.example.net', 4242, status: 'nothing_heard')
        ..addEntry('e', 'mismatch.example.net', 4242, private: true, network: 'x', pass: true, status: 'mismatch')
        ..addEntry('f', 'new.example.net', 4242, status: 'connecting');
      await open(tester, sync, (s) => WaysToConnectPage(sharing: s));
      expect(find.text('No entry points yet'), findsNothing);
      // The rows' words, in the order of the list (by address).
      expect(find.textContaining('Port 4242'), findsWidgets);
      expect(find.textContaining('Private ·'), findsNWidgets(3));
      expect(find.textContaining('Connected'), findsWidgets);
      expect(find.textContaining('Not answering'), findsOneWidget);
      expect(find.textContaining('Off'), findsOneWidget);
      expect(find.textContaining('Connected, nothing heard yet'), findsOneWidget);
      expect(find.textContaining("Network name or passphrase doesn't match"), findsOneWidget);
      expect(find.textContaining('Connecting…'), findsOneWidget);
    });

    testWidgets("an entry point's switch turns it on or off at once, keeping its settings", (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242);
      await open(tester, sync, (s) => WaysToConnectPage(sharing: s));
      await tester.tap(find.byKey(const ValueKey('entry-switch-a')));
      await settle(tester);
      expect(sync.argsOf['entry_point_on']!.last, {'id': 'a', 'on': false});
      expect(sync.entries.single['host'], 'rt.example.net', reason: 'off keeps the settings');
      expect(find.textContaining('Off'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('entry-switch-a')));
      await settle(tester);
      expect(sync.argsOf['entry_point_on']!.last, {'id': 'a', 'on': true});
    });

    testWidgets('the row opens the page, and Add an entry point opens the form', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242);
      await open(tester, sync, (s) => WaysToConnectPage(sharing: s));
      await tester.tap(find.byKey(const ValueKey('entry-a')));
      await tester.pumpAndSettle();
      expect(find.text('Added on all your linked devices.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-entry')));
      await tester.pumpAndSettle();
      expect(find.text('The address and port of a Reticulum node you run or trust. Private ones also need a network name and passphrase.'), findsOneWidget);
    });
  });

  group('an entry point page', () {
    testWidgets('connected: the switch, the address, the status with the devices online through it, the cap and the privacy text', (tester) async {
      final sync = FakeSync()
        ..peers.addAll([
          {'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': null, 'via': null, 'error': null},
          {'id': 'p2', 'name': 'Tablet', 'linked': 1, 'last_seen': null, 'via': null, 'error': null},
          {'id': 'p3', 'name': 'Home PC', 'linked': 1, 'last_seen': null, 'via': null, 'error': null},
        ])
        ..addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true);
      for (final p in ['p1', 'p2', 'p3']) {
        sync.reachThrough(p, 'a');
      }
      await open(tester, sync, (s) => EntryPointPage(sharing: s, id: 'a'));
      expect(find.text('Use this entry point'), findsOneWidget);
      expect(find.text('Off keeps these settings'), findsOneWidget);
      expect(find.text('Where it is'.toUpperCase()), findsOneWidget);
      expect(field(tester, 'entry-host'), 'rt.example.net');
      expect(field(tester, 'entry-port'), '4242');
      expect(find.text('Private network'), findsOneWidget);
      expect(find.text('Needs a network name and passphrase. Ask whoever runs it.'), findsOneWidget);
      expect(field(tester, 'entry-network'), 'example-net');
      expect(find.text('Show'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Checked just now · 3 of your devices are online through it'), findsOneWidget);
      expect(find.text('Up to 50 MB each'), findsOneWidget);
      expect(find.text('Bigger files wait for Wi-Fi or Bluetooth'), findsOneWidget);
      expect(find.textContaining('The person who runs it can see when your devices are online'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Remove from all my devices'), findsOneWidget);
    });

    testWidgets('not answering, mismatch, nothing heard yet and off each say so', (tester) async {
      for (final (state, title, sub) in [
        ('not_answering', 'Not answering', 'Checked just now'),
        ('mismatch', "Network name or passphrase doesn't match", 'Check both with whoever runs it, then Save. Checked just now.'),
        ('nothing_heard', 'Connected, nothing heard yet', 'Checked just now'),
        ('off', 'Off', null),
      ]) {
        final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242, private: true, network: 'n', pass: true, on: state != 'off', status: state);
        await open(tester, sync, (s) => EntryPointPage(sharing: s, id: 'a'));
        final box = find.byKey(const ValueKey('entry-status'));
        expect(find.descendant(of: box, matching: find.text(title)), findsOneWidget, reason: state);
        if (sub != null) expect(find.descendant(of: box, matching: find.text(sub)), findsOneWidget, reason: state);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Private network off hides the network name and passphrase', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242);
      await open(tester, sync, (s) => EntryPointPage(sharing: s, id: 'a'));
      expect(find.byKey(const ValueKey('entry-network')), findsNothing);
      expect(find.byKey(const ValueKey('entry-passphrase')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('entry-private')));
      await tester.pump();
      expect(find.byKey(const ValueKey('entry-network')), findsOneWidget);
      expect(find.byKey(const ValueKey('entry-passphrase')), findsOneWidget);
    });

    testWidgets('Save keeps the passphrase saved unless a new one is typed, and sends the rest', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true);
      await open(tester, sync, (s) => EntryPointPage(sharing: s, id: 'a'));
      await tester.enterText(find.byKey(const ValueKey('entry-port')), '4343');
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await settle(tester);
      final sent = sync.argsOf['entry_point_set']!.last;
      expect(sent['id'], 'a');
      expect(sent['host'], 'rt.example.net');
      expect(sent['port'], 4343);
      expect(sent['private'], true);
      expect(sent['network_name'], 'example-net');
      expect(sent.containsKey('passphrase'), isFalse, reason: 'left alone, the saved one stays');
      expect(sync.entries.single['port'], 4343);
    });

    testWidgets('a typed passphrase is sent; Show makes it readable', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true);
      await open(tester, sync, (s) => EntryPointPage(sharing: s, id: 'a'));
      await tester.enterText(find.byKey(const ValueKey('entry-passphrase')), 'a new phrase');
      expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('entry-passphrase')), matching: find.byType(EditableText))).obscureText, isTrue);
      await tester.tap(find.byKey(const ValueKey('entry-show')));
      await tester.pump();
      expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('entry-passphrase')), matching: find.byType(EditableText))).obscureText, isFalse);
      expect(find.text('Hide'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await settle(tester);
      expect(sync.argsOf['entry_point_set']!.last['passphrase'], 'a new phrase');
    });

    testWidgets('the file limit offers choices', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242);
      await open(tester, sync, (s) => EntryPointPage(sharing: s, id: 'a'));
      await tester.tap(find.byKey(const ValueKey('entry-cap')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cap-${100 << 20}')));
      await tester.pumpAndSettle();
      expect(find.text('Up to 100 MB each'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await settle(tester);
      expect(sync.argsOf['entry_point_set']!.last['cap_bytes'], 100 << 20);
    });

    testWidgets('Remove asks first; Cancel keeps it; Remove deletes it and closes the page', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242, private: true, network: 'n', pass: true);
      await open(tester, sync, (s) => WaysToConnectPage(sharing: s));
      await tester.tap(find.byKey(const ValueKey('entry-a')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('entry-remove')));
      await tester.tap(find.byKey(const ValueKey('entry-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Remove rt.example.net?'), findsOneWidget);
      expect(find.text("It's removed from all your linked devices, with its network name and passphrase. To use it again, you'll need to enter it again."), findsOneWidget);
      expect(find.text('To stop using it for now and keep its settings, turn it off instead.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-remove')));
      await tester.pumpAndSettle();
      expect(sync.entries, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('entry-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove')));
      await settle(tester);
      expect(sync.argsOf['entry_point_remove']!.last, {'id': 'a'});
      expect(sync.entries, isEmpty);
      expect(find.text('No entry points yet'), findsOneWidget, reason: 'back on Ways to connect');
    });
  });

  group('the add form', () {
    testWidgets('its words, and nothing is sent when a check fails', (tester) async {
      final sync = FakeSync()..addEntry('a', 'rt.example.net', 4242);
      await open(tester, sync, (s) => EntryPointPage(sharing: s));
      expect(find.text('Add an entry point'), findsOneWidget);
      expect(find.text('Add and connect'), findsOneWidget);
      expect(find.text('Use this entry point'), findsNothing);
      expect(find.text('Remove from all my devices'), findsNothing);
      expect(find.text('Up to 50 MB each'), findsOneWidget);

      // Nothing entered.
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await tester.pump();
      expect(find.text('Enter the address of the entry point.'), findsOneWidget);
      expect(find.text('The port has to be a number from 1 to 65535.'), findsOneWidget);

      // A port that is too big.
      await tester.enterText(find.byKey(const ValueKey('entry-host')), 'rt2.example.net');
      await tester.enterText(find.byKey(const ValueKey('entry-port')), '70000');
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await tester.pump();
      expect(find.text('Enter the address of the entry point.'), findsNothing);
      expect(find.text('The port has to be a number from 1 to 65535.'), findsOneWidget);

      // Private with neither a name nor a passphrase.
      await tester.enterText(find.byKey(const ValueKey('entry-port')), '4242');
      await tester.tap(find.byKey(const ValueKey('entry-private')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await tester.pump();
      expect(find.text('A private entry point needs a network name or a passphrase.'), findsOneWidget);

      // The same address and port as one already in the list.
      await tester.tap(find.byKey(const ValueKey('entry-private')));
      await tester.enterText(find.byKey(const ValueKey('entry-host')), 'RT.example.net');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await tester.pump();
      expect(find.text('That entry point is already in your list.'), findsOneWidget);
      expect(sync.argsOf['entry_point_set'], isNull, reason: 'nothing reached the engine');
    });

    testWidgets('Add and connect sends the entry on and closes the form', (tester) async {
      final sync = FakeSync();
      await open(tester, sync, (s) => WaysToConnectPage(sharing: s));
      await tester.tap(find.byKey(const ValueKey('add-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('entry-host')), 'rt.example.net');
      await tester.enterText(find.byKey(const ValueKey('entry-port')), '4242');
      await tester.tap(find.byKey(const ValueKey('entry-private')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('entry-network')), 'example-net');
      await tester.enterText(find.byKey(const ValueKey('entry-passphrase')), 'a phrase');
      await tester.tap(find.byKey(const ValueKey('entry-save')));
      await settle(tester);
      final sent = sync.argsOf['entry_point_set']!.single;
      expect(sent, {'host': 'rt.example.net', 'port': 4242, 'private': true, 'network_name': 'example-net', 'passphrase': 'a phrase', 'cap_bytes': 50 << 20, 'on': true});
      expect(find.text('rt.example.net'), findsOneWidget, reason: 'back on the list, with the new entry point');
      expect(find.text('Add an entry point'), findsOneWidget);
    });

    test('the checks', () {
      EntryPointProblems check(String host, String port, {bool private = false, String name = '', bool pass = false, List<EntryPoint> others = const []}) =>
          checkEntryPoint(host: host, port: port, private: private, networkName: name, hasPassphrase: pass, others: others);
      expect(check('rt.example.net', '4242').any, isFalse);
      expect(check('', '4242').address, 'Enter the address of the entry point.');
      expect(check('rt example', '4242').address, 'The address cannot have spaces in it.');
      expect(check('h', '0').port, 'The port has to be a number from 1 to 65535.');
      expect(check('h', '65535').port, isNull);
      expect(check('h', '65536').port, isNotNull);
      expect(check('h', 'abc').port, isNotNull);
      expect(check('h', '1', private: true).network, 'A private entry point needs a network name or a passphrase.');
      expect(check('h', '1', private: true, name: 'n').network, isNull);
      expect(check('h', '1', private: true, pass: true).network, isNull);
      expect(check('H.example', '1', others: const [EntryPoint(id: 'x', host: 'h.example', port: 1)]).address, 'That entry point is already in your list.');
      expect(check('h.example', '2', others: const [EntryPoint(id: 'x', host: 'h.example', port: 1)]).any, isFalse);
    });
  });

  group('Sharing and sync', () {
    final now = DateTime.now().millisecondsSinceEpoch;

    testWidgets('This device and the Ways to connect row count the entry points that are on', (tester) async {
      final sync = FakeSync()
        ..addEntry('a', 'rt.example.net', 4242)
        ..addEntry('b', 'reticulum.example.org', 4965, status: 'not_answering')
        ..addEntry('c', '192.168.1.20', 4242, on: false);
      await open(tester, sync, (s) => SharingPage(sharing: s));
      expect(find.text('Test phone'), findsOneWidget);
      expect(find.textContaining('Wi-Fi, Bluetooth and 2 entry points · 10.0 GB free'), findsOneWidget);
      expect(find.text('WAYS TO CONNECT'), findsOneWidget);
      expect(find.text('Wi-Fi and local network, Bluetooth, 2 entry points'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ways-to-connect')));
      await tester.pumpAndSettle();
      expect(find.text('Over the internet'.toUpperCase()), findsOneWidget);
    });

    testWidgets('with none, the lines leave the count out', (tester) async {
      await open(tester, FakeSync(), (s) => SharingPage(sharing: s));
      expect(find.textContaining('Wi-Fi and Bluetooth · 10.0 GB free'), findsOneWidget);
      expect(find.text('Wi-Fi and local network, Bluetooth'), findsOneWidget);
    });

    testWidgets('a device through an entry point says Through <host>', (tester) async {
      final sync = FakeSync()
        ..addEntry('a', 'rt.example.net', 4242)
        ..peers.add({'id': 'p1', 'name': 'Home PC', 'linked': 1, 'last_seen': now, 'via': null, 'error': null});
      sync.reachThrough('p1', 'a');
      await open(tester, sync, (s) => SharingPage(sharing: s));
      expect(find.text('Through rt.example.net · Last seen just now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('peer-p1')));
      await tester.pumpAndSettle();
      expect(find.text('Through rt.example.net · Last seen just now'), findsOneWidget);
    });

    testWidgets('each class of link: Wi-Fi, Bluetooth, radio', (tester) async {
      final sync = FakeSync()
        ..peers.addAll([
          {'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': now, 'via': 'wifi', 'speed': 'fast', 'live': true, 'error': null},
          {'id': 'p2', 'name': 'Tablet', 'linked': 1, 'last_seen': now - 120000, 'via': 'reticulum', 'speed': 'medium', 'live': true, 'error': null},
          {'id': 'p3', 'name': "Partner's phone", 'linked': 1, 'last_seen': now - 300000, 'via': 'reticulum', 'speed': 'slow', 'live': true, 'error': null},
        ]);
      await open(tester, sync, (s) => SharingPage(sharing: s));
      expect(find.text('Same Wi-Fi · Last seen just now'), findsOneWidget);
      expect(find.text('Bluetooth · Last seen 2 min ago'), findsOneWidget);
      expect(find.text('Radio, small items only · Last seen 5 min ago'), findsOneWidget);
    });

    testWidgets('a device on a slow link: its page says how, and lists what waits for a faster connection', (tester) async {
      final sync = FakeSync()
        ..addEntry('a', 'rt.example.net', 4242)
        ..peers.add({'id': 'p3', 'name': "Partner's phone", 'linked': 1, 'last_seen': now - 300000, 'via': 'reticulum', 'speed': 'slow', 'live': true, 'error': null})
        ..waiting.addAll([
          {'peer': 'p3', 'peer_name': "Partner's phone", 'share_id': 'regions', 'share': 'Region map', 'path': '', 'what': 'list', 'size': 0, 'reason': 'Waiting for a faster connection'},
          {'peer': 'p3', 'peer_name': "Partner's phone", 'share_id': 'notes', 'share': 'Notebooks', 'path': 'photos/IMG_0412.jpg', 'what': 'file', 'size': 4400000, 'reason': 'Waiting for a faster connection'},
          {'peer': 'other', 'peer_name': 'Elsewhere', 'share_id': 'notes', 'share': 'Notebooks', 'path': 'x.jpg', 'what': 'file', 'size': 1, 'reason': 'Waiting for a faster connection'},
        ]);
      await open(tester, sync, (s) => SharingDevicePage(sharing: s, peer: 'p3'));
      expect(find.text('Connected over radio'), findsOneWidget);
      expect(find.text('Slow: notes, places, positions and check-ins only'), findsOneWidget);
      expect(find.text('WAITING FOR A FASTER CONNECTION'), findsOneWidget);
      expect(find.text('Region map'), findsOneWidget);
      expect(find.text('IMG_0412.jpg'), findsOneWidget);
      expect(find.text('4.2 MB'), findsOneWidget);
      expect(find.text('x.jpg'), findsNothing, reason: "another device's waiting items are not listed here");
      expect(find.text('These go the next time the devices are on the same Wi-Fi or in Bluetooth range, or both use an entry point that allows files this big.'), findsOneWidget);
    });

    testWidgets('a device with nothing waiting has no waiting list', (tester) async {
      final sync = FakeSync()..peers.add({'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': now, 'via': 'wifi', 'speed': 'fast', 'live': true, 'error': null});
      await open(tester, sync, (s) => SharingDevicePage(sharing: s, peer: 'p1'));
      expect(find.text('Same Wi-Fi · Last seen just now'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-waiting')), findsNothing);
    });
  });
}

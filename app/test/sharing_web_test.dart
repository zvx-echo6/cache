// Sharing and sync in the browser: SharingState with the web driver, which asks Cache Server's sharing host (`sharing.*` ops through
// /api/core) instead of running the engine. The same cases as sharing_test.dart where they make sense for the server, and the Sharing
// page on that driver: its code, a pasted link, the linked device's row, and only the Library and Models switches.

import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/screens/settings/widgets.dart' show SettingsRow;
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/share_items.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sharing_host_fake.dart';
import 'support/sync_fake.dart' show linkCodeLines;

/// What a browser knows of the kinds: the phone's own list, whose folders are not the browser's (every folder is null).
List<DataKind> _kinds() => [
  DataKind(
    id: 'library',
    label: 'Library',
    icon: Icons.menu_book_outlined,
    shared: () => const {'library': null, 'libraries': null},
    items: () => const [
      ShareItem(share: 'library', path: 'wikimed.zim', name: 'Medical encyclopedia', bytes: 1400 << 20),
      ShareItem(share: 'library', path: 'canning.zim', name: 'Home canning', bytes: 29 << 20),
    ],
    remoteItem: libraryRemoteItem,
  ),
  DataKind(
    id: 'models',
    label: 'Models',
    icon: Icons.memory,
    shared: () => const {'models': null},
    items: () => const [ShareItem(share: 'models', path: 'gemma.gguf', name: 'Gemma 4 E2B', bytes: 3200 << 20)],
    remoteItem: modelRemoteItem,
  ),
  DataKind(id: 'regions', label: 'Regions', icon: Icons.map_outlined, shareLabel: 'Maps', shared: () => const {'maps': null, 'regions': null}),
  DataKind(id: 'notebooks', label: 'Notebooks', icon: Icons.book_outlined, shared: () => const {'notebooks': null}),
  DataKind(id: 'videos', label: 'Videos and weather', icon: Icons.smart_display_outlined, shareLabel: 'Videos', shared: () => const {'videos': null}),
];

FakeSharingHost _host() => FakeSharingHost(table: {
  'library': {'library': '/srv/zims', 'libraries': '/srv/libraries'},
  'regions': {'maps': '/srv/layers', 'regions': '/srv/regions'},
  'models': {'models': '/srv/models'},
  'notebooks': {'notebooks': '/srv/nb'},
  'videos': {'videos': '/srv/videos'},
});

SharingState _web(FakeSharingHost host, Directory dir) =>
    SharingState(policy: testPolicy(), supportDir: () async => dir, kinds: _kinds(), remote: host);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 5400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Lets the page settle: the fake host answers in microtasks, so a few pumps run everything a tap started.
Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sharing-web'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a tab reloads its settings when the host\'s settings_applied moves, once per move, and not when it stays', (tester) async {
    final host = _host()..settingsApplied = 1;
    final s = _web(host, dir);
    var reloads = 0;
    s.onSettingsApplied = () => reloads++;
    await s.init();
    await s.setUp();
    await _settle(tester);
    expect(reloads, 0, reason: 'the first reading is the baseline, not a change');
    await tester.pump(const Duration(seconds: 6));
    expect(reloads, 0, reason: 'the counter did not move');
    host.settingsApplied = 2;
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(reloads, 1);
    await tester.pump(const Duration(seconds: 6));
    expect(reloads, 1, reason: 'the same value again does not reload');
    host.settingsApplied = 3;
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(reloads, 2);
    s.dispose();
  });


  testWidgets('not set up: nothing is asked of the engine and nothing polls; set up starts it on the server, not in the browser', (tester) async {
    final host = _host();
    final s = _web(host, dir);
    await s.init();
    expect(s.enabled, isFalse);
    expect(s.running, isFalse);
    expect(host.sync.calls, isEmpty, reason: 'the engine runs on the server, and only once set up');
    await tester.pump(const Duration(seconds: 6));
    expect(host.count('sharing.state'), 1, reason: 'one read at start; a server that is not set up is not polled');

    await s.setUp();
    expect(s.enabled, isTrue);
    expect(s.running, isTrue);
    expect(host.count('sharing.setup'), 1);
    expect(s.name, 'Cache Server', reason: 'the server names itself; the browser has no say');
    expect(s.myId, 'me');
    expect(File('${dir.path}/sharing.json').existsSync(), isFalse, reason: 'the browser keeps no sharing.json: the server does');
    expect(host.sync.calls, isNot(contains('set_policy')), reason: "the network rule is the phone's");
    s.dispose();
  });

  testWidgets('the state is read every 2 s while set up, and the poll stops with dispose', (tester) async {
    final host = _host()..enabled = true;
    final s = _web(host, dir);
    await s.init();
    expect(s.running, isTrue, reason: 'a server that was set up before shows at once');
    final before = host.count('sharing.state');
    host.sync.peers.add({'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': 1, 'via': 'direct', 'error': null});
    await tester.pump(const Duration(seconds: 2));
    expect(host.count('sharing.state'), greaterThan(before));
    expect(s.peers.map((p) => p['id']), ['p1'], reason: 'what changed on the server shows without any action here');
    final n = host.count('sharing.state');
    await tester.pump(const Duration(seconds: 4));
    expect(host.count('sharing.state'), n + 2);
    s.dispose();
    await tester.pump(const Duration(seconds: 6));
    expect(host.count('sharing.state'), n + 2, reason: 'no poll after dispose');
  });

  testWidgets('a server that cannot answer says so, and starting again works', (tester) async {
    final host = _host()..enabled = true;
    host.stateError = const CacheSearchException('internal', 'Cache Server could not be reached: offline');
    final s = _web(host, dir);
    await s.init();
    expect(s.running, isFalse);
    expect(s.error, contains('Sharing could not start'));
    host.stateError = null;
    await s.init();
    expect(s.running, isTrue);
    expect(s.error, isNull);
    s.dispose();
  });

  testWidgets('link with a code: started at once, polled until done; the device shows; a failure says why', (tester) async {
    final host = _host()..enabled = true;
    final s = _web(host, dir);
    await s.init();

    ({String peer, String name})? got;
    final f = s.link('CACHE1-TESTCODE').then((r) => got = r);
    await tester.pump();
    expect(host.count('sharing.link_start'), 1);
    expect(host.opArgs[host.ops.indexOf('sharing.link_start')], {'code': 'CACHE1-TESTCODE'});
    expect(got, isNull, reason: 'the host answers at once; the link is still going');
    for (var i = 0; i < 8 && got == null; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await f;
    expect(got, (peer: 'peer1', name: 'Desk'));
    expect(s.peerOf('peer1')?['name'], 'Desk');

    host.sync.linkError = const CacheSearchException('sync', 'that code has run out');
    Object? err;
    final g = s.link('CACHE1-OTHER').then<void>((_) {}, onError: (Object e) => err = e);
    for (var i = 0; i < 8 && err == null; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await g;
    expect(err, isA<CacheSearchException>().having((e) => e.message, 'message', contains('that code has run out')));
    s.dispose();
  });

  testWidgets('the actions go through sharing.call, with the same arguments as on the phone', (tester) async {
    final host = _host()..enabled = true;
    host.sync.peers.add({'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': 1, 'via': 'direct', 'error': null});
    final s = _web(host, dir);
    await s.init();
    expect(await s.linkCode(), 'CACHE-7KQF-M2XD-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ');
    await s.rename('Basement');
    expect(s.name, 'Basement');
    await s.renamePeer('p1', 'Office');
    expect(s.peerOf('p1')?['name'], 'Office');
    await s.setLink('p1', {'mode': 'match'});
    expect(host.sync.argsOf['set_link']!.single, {'peer': 'p1', 'link': {'mode': 'match'}});
    await s.syncNow();
    await s.syncPeer('p1');
    expect(host.sync.argsOf['sync_now'], [<String, Object?>{}, {'peer': 'p1'}]);
    await s.unlink('p1');
    expect(s.peers, isEmpty);
    expect(host.count('sharing.call'), greaterThanOrEqualTo(7));
    s.dispose();
  });

  testWidgets('a kind on and off, an item switched off, and an item switched on in a kind that is off', (tester) async {
    final host = _host()..enabled = true;
    final s = _web(host, dir);
    await s.init();
    final lib = s.kinds.firstWhere((k) => k.id == 'library');
    expect(s.kindOn(lib), isFalse);

    await s.setShared(lib, true);
    expect(host.opArgs[host.ops.indexOf('sharing.set_kind')], {'kind': 'library', 'on': true});
    expect(s.shareOf('library')?['path'], '/srv/zims', reason: "the server's folder, not one of the browser");
    expect(s.shareOf('libraries')?['path'], '/srv/libraries');
    expect(s.kindOn(lib), isTrue);

    final items = s.itemsOf(lib);
    expect(items.every((i) => s.itemOn(lib, i.item)), isTrue);
    await s.setItem(lib, items[1].item, false);
    expect(s.itemOn(lib, items[1].item), isFalse, reason: 'the off list comes back with the state');
    expect(s.itemOn(lib, items[0].item), isTrue);
    await s.setItem(lib, items[1].item, true);
    expect(s.itemOn(lib, items[1].item), isTrue);

    await s.setShared(lib, false);
    expect(s.kindOn(lib), isFalse);
    expect(s.shareOf('library'), isNull);

    // An item switched on in a kind that is off shares the kind with that item alone: the host is given every item.
    await s.setItem(lib, items[0].item, true);
    final i = host.ops.lastIndexOf('sharing.set_item');
    expect(host.opArgs[i]['all'], ['library/wikimed.zim', 'library/canning.zim']);
    expect(s.kindOn(lib), isTrue);
    expect(s.itemOn(lib, items[0].item), isTrue);
    expect(s.itemOn(lib, items[1].item), isFalse);
    s.dispose();
  });

  testWidgets('a restart (a new tab) picks up what the server already runs, with no question', (tester) async {
    final host = _host();
    final first = _web(host, dir);
    await first.init();
    await first.setUp();
    first.dispose();
    final again = _web(host, dir);
    await again.init();
    expect(again.running, isTrue);
    expect(host.count('sharing.setup'), 1);
    again.dispose();
  });

  testWidgets("the engine's key methods are not reachable from the browser, and the browser asks for none", (tester) async {
    final host = _host()..enabled = true;
    await expectLater(
      host.call('sharing.call', {'method': 'set_secrets', 'args': {}}),
      throwsA(isA<CacheSearchException>().having((e) => e.code, 'code', 'forbidden')),
    );
    final s = _web(host, dir);
    await s.init();
    await s.setSecrets('p1', {'a': 'b'});
    expect(await s.takeSecrets(), isEmpty, reason: "keys are the server's own, later");
    expect(host.sync.calls, isNot(contains('set_secrets')));
    expect(host.sync.calls, isNot(contains('take_secrets')));
    s.dispose();
  });

  testWidgets('the page: set up, the code, a pasted link, the linked device row, and only the Library and Models switches', (tester) async {
    _tall(tester);
    final host = _host();
    final s = _web(host, dir);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: SharingPage(sharing: s)));
    await tester.pump();
    expect(find.text('Set up sharing'), findsOneWidget);
    // On a server the setup line says what setting up does there (the phone's says "this device's identity").
    expect(find.textContaining('Setting up gives this server its own identity for linking with your devices.'), findsOneWidget);
    expect(find.textContaining("creates this device's identity"), findsNothing);
    await _tap(tester, find.text('Set up sharing'));
    expect(find.text('Cache Server'), findsOneWidget, reason: "the server's own name");
    // "This device" is a server, not a phone
    final me = find.ancestor(of: find.text('Cache Server'), matching: find.byType(SettingsRow));
    expect(find.descendant(of: me, matching: find.byIcon(Icons.dns)), findsOneWidget);
    expect(find.descendant(of: me, matching: find.byIcon(Icons.smartphone)), findsNothing);
    expect(find.text('Show my link code'), findsOneWidget);
    expect(find.text('Enter a link code'), findsOneWidget);

    // Only the kinds that need nothing else yet.
    expect(find.byKey(const ValueKey('share-library')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-models')), findsOneWidget);
    for (final k in ['regions', 'notebooks', 'videos']) {
      expect(find.byKey(ValueKey('share-$k')), findsNothing, reason: '$k comes in a later slice');
    }
    expect(s.shareKinds.map((k) => k.id), ['library', 'models']);

    // The code and its QR.
    await _tap(tester, find.byKey(const ValueKey('show-code')));
    expect(find.text('Show my link code'), findsOneWidget, reason: 'its own page now, with a back arrow');
    expect(linkCodeLines(tester).join(), 'CACHE-7KQF-M2XD-P4WN-R7TA-H3JC-V6YB-Q5LE-W2FS-ZQ');
    expect(find.text('Copy code'), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);
    expect(find.text('Copy code'), findsNothing);

    // A pasted link: nothing is linked until Link is tapped, then the device is there.
    await _tap(tester, find.byKey(const ValueKey('enter-code')));
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'CACHE1-PASTEDCODE');
    expect(host.count('sharing.link_start'), 0);
    await tester.tap(find.text('Link'));
    for (var i = 0; i < 10 && find.text('Linked with Desk').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(host.count('sharing.link_start'), 1);
    expect(find.text('Linked with Desk'), findsOneWidget);
    expect(find.byKey(const ValueKey('peer-peer1')), findsOneWidget);
    expect(find.text('Desk'), findsOneWidget);

    // A kind's switch shares the server's folder.
    expect(find.text('Not shared'), findsNWidgets(2));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('share-models')), matching: find.byType(Switch)));
    await _settle(tester);
    expect(s.shareOf('models')?['path'], '/srv/models');
    expect(find.textContaining('1 of 1 shared'), findsOneWidget);

    // The linked device's page: Sync now and Unlink go to the server.
    await _tap(tester, find.byKey(const ValueKey('peer-peer1')));
    await _tap(tester, find.byKey(const ValueKey('device-sync')));
    expect(host.sync.argsOf['sync_now']!.last, {'peer': 'peer1'});
    await _tap(tester, find.byKey(const ValueKey('device-unlink')));
    expect(find.text('Unlink Desk?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-unlink')));
    // The screen-lock question goes through a platform channel (none answers here), which takes a real moment.
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !(host.sync.argsOf['unlink'] != null); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await _settle(tester);
    expect(host.sync.argsOf['unlink']!.single, {'peer': 'peer1'});
    expect(s.peers, isEmpty);

    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}

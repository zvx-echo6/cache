// Step 4's pages as the app draws them, 390 points wide, light and dark, with sample data (example hosts only): Sharing and sync (this
// device, how each device is connected, the Ways to connect row), Ways to connect (with entry points, and empty), an entry point's page
// in each state (connected, not answering, network name or passphrase doesn't match, nothing heard yet, off), the add form (empty, and
// with its checks), the Remove confirm, the file limit choices, and a device's page through an entry point and on a slow link with
// what waits for a faster connection. The page is as tall as it needs to be, so each picture shows all of it.
// flutter test test_shots/entry_points_renders_test.dart --update-goldens  (pictures in test_shots/entry_points/)

import 'dart:io';

import 'package:cache/screens/settings/entry_point_page.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/screens/settings/ways_to_connect_page.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'entry_points';

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

final int _now = DateTime.now().millisecondsSinceEpoch;

/// The sample set of entry points: a private one that is connected, one not answering, and a private one switched off.
void _threeEntries(FakeSync sync) {
  sync
    ..addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true)
    ..addEntry('b', 'reticulum.example.org', 4965, status: 'not_answering')
    ..addEntry('c', '192.168.1.20', 4242, private: true, network: 'lab', pass: true, on: false);
}

void main() {
  setUpAll(loadShotFonts);

  /// One picture of [page] per theme: [name] says what it shows. [prepare] fills the fake engine; [act] drives the page before the shot.
  void shot(
    String name,
    Widget Function(SharingState s) page, {
    required void Function(FakeSync sync) prepare,
    Future<void> Function(WidgetTester tester)? act,
    double height = 1000,
    List<DataKind> Function(Directory dir)? kinds,
  }) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('$name $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final sync = FakeSync();
        prepare(sync);
        final ks = kinds?.call(r.dir) ?? const <DataKind>[];
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: ks, deviceName: 'Test phone', phone: true, reticulum: true, opener: (_) async => sync);
        await tester.runAsync(() async {
          await sharing.setUp();
          for (final k in ks) {
            if (k.id != 'models') await sharing.setShared(k, true);
          }
        });
        await tester.runAsync(sharing.refresh);
        phone(tester, size: Size(390, height), ratio: 3);
        await tester.pumpWidget(shotApp(page(sharing), theme: theme));
        await _settle(tester);
        if (act != null) await act(tester);
        await snap(tester, _out, '$name-$t');
        await tester.pumpWidget(const SizedBox());
        sharing.dispose();
        await r.dispose(tester);
      });
    }
  }

  List<DataKind> sampleKinds(Directory dir) {
    Directory d(String n) => Directory('${dir.path}/share-$n')..createSync(recursive: true);
    return [
      DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined, shared: () => {'library': d('zims')}, items: () => const []),
      DataKind(id: 'models', label: 'Models', icon: Icons.memory, shared: () => {'models': d('models')}, items: () => const []),
      DataKind(id: 'notebooks', label: 'Notebooks', icon: Icons.book_outlined, shared: () => {'notebooks': d('notebooks')}, items: () => const []),
    ];
  }

  // Sharing and sync: this device, each way a device is connected, the Ways to connect row.
  shot(
    '01-sharing-and-sync',
    (s) => SharingPage(sharing: s),
    height: 1250,
    kinds: sampleKinds,
    prepare: (sync) {
      _threeEntries(sync);
      sync.entries.removeLast();
      sync.peers.addAll([
          {'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': _now - 1000, 'via': 'wifi', 'speed': 'fast', 'live': true, 'error': null},
          {'id': 'p2', 'name': 'Tablet', 'linked': 1, 'last_seen': _now - 120000, 'via': 'reticulum', 'speed': 'medium', 'live': true, 'error': null},
          {'id': 'p3', 'name': "Partner's phone", 'linked': 1, 'last_seen': _now - 300000, 'via': 'reticulum', 'speed': 'slow', 'live': true, 'error': null},
          {'id': 'p4', 'name': 'Home PC', 'linked': 1, 'last_seen': _now - 1000, 'via': 'entry:a', 'speed': 'fast', 'live': true, 'error': null},
        ]);
    },
  );
  shot('01b-sharing-and-sync-no-entry-points', (s) => SharingPage(sharing: s), height: 1100, kinds: sampleKinds, prepare: (sync) {
    sync.peers.add({'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': _now - 1000, 'via': 'wifi', 'speed': 'fast', 'live': true, 'error': null});
  });

  // Ways to connect.
  shot('02-ways-to-connect', (s) => WaysToConnectPage(sharing: s), prepare: _threeEntries);
  shot('02b-ways-to-connect-empty', (s) => WaysToConnectPage(sharing: s), height: 900, prepare: (_) {});
  shot('02c-ways-to-connect-other-states', (s) => WaysToConnectPage(sharing: s), height: 1100, prepare: (sync) {
    sync
      ..addEntry('d', 'quiet.example.net', 4242, status: 'nothing_heard')
      ..addEntry('e', 'private.example.net', 4242, private: true, network: 'x', pass: true, status: 'mismatch')
      ..addEntry('f', 'new.example.net', 4242, status: 'connecting');
  });

  // One entry point's page, by state.
  void entryShot(String name, String status, {bool on = true, int through = 0}) {
    shot(
      name,
      (s) => EntryPointPage(sharing: s, id: 'a'),
      height: 1350,
      prepare: (sync) {
        sync.addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true, on: on, status: status);
        for (var i = 0; i < through; i++) {
          sync.peers.add({'id': 'p$i', 'name': 'Device $i', 'linked': 1, 'last_seen': null, 'via': null, 'error': null});
          sync.reachThrough('p$i', 'a');
        }
      },
    );
  }

  entryShot('03-entry-point-connected', 'connected', through: 3);
  entryShot('03b-entry-point-not-answering', 'not_answering');
  entryShot('03c-entry-point-mismatch', 'mismatch');
  entryShot('03d-entry-point-nothing-heard', 'nothing_heard');
  entryShot('03e-entry-point-off', 'off', on: false);

  // The Remove confirm.
  shot(
    '04-remove-confirm',
    (s) => EntryPointPage(sharing: s, id: 'a'),
    height: 1350,
    prepare: (sync) {
      sync.addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true);
      for (var i = 0; i < 3; i++) {
        sync.peers.add({'id': 'p$i', 'name': 'Device $i', 'linked': 1, 'last_seen': null, 'via': null, 'error': null});
        sync.reachThrough('p$i', 'a');
      }
    },
    act: (tester) async {
      await tester.tap(find.byKey(const ValueKey('entry-remove')));
      await _settle(tester);
    },
  );

  // The file limit choices.
  shot(
    '04b-file-limit-choices',
    (s) => EntryPointPage(sharing: s, id: 'a'),
    height: 1350,
    prepare: (sync) => sync.addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true),
    act: (tester) async {
      await tester.tap(find.byKey(const ValueKey('entry-cap')));
      await _settle(tester);
    },
  );

  // The add form: empty, private, and with its checks.
  shot('05-add-entry-point', (s) => EntryPointPage(sharing: s), height: 1000, prepare: (_) {});
  shot('05b-add-private', (s) => EntryPointPage(sharing: s), height: 1250, prepare: (_) {}, act: (tester) async {
    await tester.enterText(find.byKey(const ValueKey('entry-host')), 'rt.example.net');
    await tester.enterText(find.byKey(const ValueKey('entry-port')), '4242');
    await tester.tap(find.byKey(const ValueKey('entry-private')));
    await _settle(tester, 4);
    await tester.enterText(find.byKey(const ValueKey('entry-network')), 'example-net');
    await tester.enterText(find.byKey(const ValueKey('entry-passphrase')), 'sample passphrase');
    await _settle(tester, 4);
  });
  shot('05c-add-checks-empty', (s) => EntryPointPage(sharing: s), height: 1050, prepare: (_) {}, act: (tester) async {
    await tester.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(tester, 4);
  });
  shot('05d-add-checks-private-and-duplicate', (s) => EntryPointPage(sharing: s), height: 1350, prepare: (sync) => sync.addEntry('a', 'rt.example.net', 4242), act: (tester) async {
    await tester.enterText(find.byKey(const ValueKey('entry-host')), 'rt.example.net');
    await tester.enterText(find.byKey(const ValueKey('entry-port')), '4242');
    await tester.tap(find.byKey(const ValueKey('entry-private')));
    await _settle(tester, 4);
    await tester.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(tester, 4);
  });

  // A device's page: through an entry point, and on a slow link with what waits.
  shot(
    '06-device-through-entry-point',
    (s) => SharingDevicePage(sharing: s, peer: 'p4'),
    height: 700,
    prepare: (sync) {
      sync.addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true);
      sync.peers.add({'id': 'p4', 'name': 'Home PC', 'linked': 1, 'last_seen': _now - 1000, 'live': true, 'error': null, 'free_bytes': 612 << 30});
      sync.reachThrough('p4', 'a');
    },
  );
  shot(
    '06b-device-slow-link-waiting',
    (s) => SharingDevicePage(sharing: s, peer: 'p3'),
    height: 1000,
    prepare: (sync) {
      sync.addEntry('a', 'rt.example.net', 4242, private: true, network: 'example-net', pass: true);
      sync.peers.add({'id': 'p3', 'name': "Partner's phone", 'linked': 1, 'last_seen': _now - 300000, 'via': 'reticulum', 'speed': 'slow', 'live': true, 'error': null, 'free_bytes': 48 << 30});
      sync.waiting.addAll([
        {'peer': 'p3', 'peer_name': "Partner's phone", 'share_id': 'regions', 'share': 'Region map', 'path': 'store/streets.sqlite', 'what': 'file', 'size': 1288490189, 'reason': 'Waiting for a faster connection'},
        {'peer': 'p3', 'peer_name': "Partner's phone", 'share_id': 'notebooks', 'share': 'Notebooks', 'path': 'Journal/photo-0412.jpg', 'what': 'file', 'size': 4400000, 'reason': 'Waiting for a faster connection'},
        {'peer': 'p3', 'peer_name': "Partner's phone", 'share_id': 'notebooks', 'share': 'Notebooks', 'path': 'Journal/photo-0413.jpg', 'what': 'file', 'size': 4400000, 'reason': 'Waiting for a faster connection'},
      ]);
    },
  );
  shot(
    '06c-device-bluetooth',
    (s) => SharingDevicePage(sharing: s, peer: 'p2'),
    height: 700,
    prepare: (sync) {
      sync.peers.add({'id': 'p2', 'name': 'Tablet', 'linked': 1, 'last_seen': _now - 120000, 'via': 'reticulum', 'speed': 'medium', 'live': true, 'error': null});
    },
  );
}

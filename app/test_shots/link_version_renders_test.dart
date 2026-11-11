// Sharing and sync (1.1.0), design only: a linked device on a version that cannot sync with this one. The Linked devices list with
// one device in "Version mismatch" next to a normal one, and the device's page in both cases (it is older; this device is older),
// at 390 and 1440 points wide, light, dark and Tactical. The status carries a made-up `compat` (the engine does not send it yet).
// flutter test test_shots/link_version_renders_test.dart --update-goldens  (pictures in test_shots/link_version/)

import 'dart:async';
import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'link_version';

const Map<String, Size> _sizes = {
  '390': Size(390, 844),
  '1440': Size(1440, 900),
};

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, Size size, CacheThemeId theme) async {
  final ratio = size.width < 600 ? 3.0 : 1.0;
  phone(tester, size: size, ratio: ratio);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: size.width < 600 ? null : EdgeInsets.zero));
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
      final t = theme.name;
      testWidgets('link version ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final now = DateTime.now().millisecondsSinceEpoch;
        final sync = FakeSync()
          ..peers.addAll([
            {
              'id': 'peer1', 'name': 'Pixel', 'linked': 1, 'last_seen': now - 60000, 'via': 'direct', 'error': null, 'link_known': false,
              'compat': 'peer_older', 'peer_version': null, 'our_version': '1.1.0',
            },
            {
              'id': 'peer2', 'name': 'Tablet', 'linked': 1, 'last_seen': now - 90000, 'via': 'relay', 'error': null, 'link_known': true,
              'compat': 'peer_newer', 'peer_version': '1.2.0', 'our_version': '1.1.0',
            },
            {'id': 'peer3', 'name': 'Desk', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null, 'free_bytes': 612 << 30, 'link_known': true, 'compat': 'ok'},
          ]);
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
        final layout = LayoutState(settingsDirOverride: r.dir);
        final settingsSync = SettingsSync(
          sharing: sharing,
          settings: appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather),
          keys: () => const [],
          storeKey: (_, _) async => false,
          dir: () async => Directory('${r.dir.path}/$kSettingsShareDir'),
          every: const Duration(hours: 1),
        );
        await tester.runAsync(() async {
          await layout.init();
          await sharing.setUp();
          await settingsSync.start();
        });
        r.hub = SettingsHub(
          sharing: sharing,
          settingsSync: settingsSync,
          settings: r.settings,
          policy: r.policy,
          webSearch: r.webSearch,
          storage: r.storage,
          weather: r.weather,
          openUrl: (u) async => r.opened.add(u),
        );

        Future<void> openSharing() async {
          await _show(tester, SettingsScreen(deps: r.deps), e.value, theme);
          await _tap(tester, 'settings-sharing');
        }

        await openSharing();
        await snap(tester, _out, '1-list-${e.key}-$t');
        await _tap(tester, 'peer-peer1');
        await snap(tester, _out, '2-device-they-are-older-${e.key}-$t');
        // Check again, while it is still asking.
        sync.holdCheck = Completer<void>();
        await tester.tap(find.byKey(const ValueKey('device-check')));
        await tester.pump(const Duration(milliseconds: 100));
        await snap(tester, _out, '4-device-checking-${e.key}-$t');
        sync.holdCheck!.complete();
        sync.holdCheck = null;
        await _settle(tester);
        // What Check again says afterwards (390 only): not reached, no network it may use, still different, and a match.
        if (e.key == '390') {
          var n = 5;
          for (final x in const {'unreachable': 'not-reached', 'network_off': 'network-off', 'peer_older': 'still-different', 'ok': 'match'}.entries) {
            await openSharing();
            await _tap(tester, 'peer-peer1');
            sync.checkResult['peer1'] = x.key;
            await tester.tap(find.byKey(const ValueKey('device-check')));
            await _settle(tester);
            await snap(tester, _out, '${n++}-toast-${x.value}-${e.key}-$t');
            sync.peers.first['compat'] = 'peer_older';
          }
          sync.checkResult.clear();
        }
        await openSharing();
        await _tap(tester, 'peer-peer2');
        await snap(tester, _out, '3-device-we-are-older-${e.key}-$t');

        await _show(tester, const SizedBox(), e.value, theme);
        await tester.runAsync(() async {
          await settingsSync.flush();
        });
        settingsSync.dispose();
        sharing.dispose();
        layout.dispose();
        await r.dispose(tester);
      });
    }
  }
}

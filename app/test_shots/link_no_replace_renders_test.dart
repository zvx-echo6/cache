// Renders of "Don't replace my copies from this device" on a linked device's page, the switch off and on, 390 points wide,
// light and dark (the approved design: origin/design/link-no-replace, picture 1). The app's own page, sample data.
// flutter test test_shots/link_no_replace_renders_test.dart --update-goldens  (pictures in test_shots/link_no_replace/)

import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/settings_sync.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sharing/synced_settings.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'link_no_replace';

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final th in {CacheThemeId.light: 'light', CacheThemeId.dark: 'dark'}.entries) {
    testWidgets('device page 390 ${th.value}', (tester) async {
      final r = await SettingsRig.create(tester);
      final now = DateTime.now().millisecondsSinceEpoch;
      final pixel = <String, dynamic>{
        'id': 'peer1', 'name': 'Pixel', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null, 'free_bytes': 48 << 30, 'link_known': true,
        'link': {'mode': 'match'},
      };
      final sync = FakeSync()..peers.add(pixel);
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
      for (final on in [false, true]) {
        pixel['keep_copies'] = on;
        await tester.runAsync(sharing.refresh);
        phone(tester, size: const Size(390, 844), ratio: 3);
        await tester.pumpWidget(shotApp(SharingDevicePage(sharing: sharing, peer: 'peer1', settingsSync: settingsSync), theme: th.key));
        await _settle(tester);
        await snap(tester, _out, '1-device-${on ? 'on' : 'off'}-390-${th.value}');
      }
      await tester.pumpWidget(const SizedBox());
      settingsSync.dispose();
      sharing.dispose();
      layout.dispose();
      await r.dispose(tester);
    });
  }
}

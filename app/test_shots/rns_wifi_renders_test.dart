// Sharing and sync with one linked device, for the Reticulum Wi-Fi row: "Same Wi-Fi · Last seen just now" and, to compare,
// "Connected directly · Last seen just now", at 390 points wide, light and dark.
// flutter test test_shots/rns_wifi_renders_test.dart --update-goldens  (pictures in test_shots/rns_wifi/)

import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'rns_wifi';

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final via in ['wifi', 'direct']) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('sharing $via $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final sync = FakeSync()
          ..peers.add({'id': 'peer1', 'name': 'Desk', 'linked': 1, 'last_seen': null, 'via': null, 'error': null});
        sync.reach('peer1', via);
        final sharing = SharingState(
          policy: r.policy,
          supportDir: () async => r.dir,
          kinds: const [],
          deviceName: 'Test phone',
          phone: true,
          reticulum: true,
          opener: (_) async => sync,
        );
        await tester.runAsync(sharing.setUp);
        r.hub = SettingsHub(
          sharing: sharing,
          settings: r.settings,
          policy: r.policy,
          webSearch: r.webSearch,
          storage: r.storage,
          weather: r.weather,
          openUrl: (u) async => r.opened.add(u),
        );
        phone(tester, size: const Size(390, 844), ratio: 3);
        await tester.pumpWidget(shotApp(SettingsScreen(deps: r.deps), theme: theme));
        await _settle(tester);
        final row = find.byKey(const ValueKey('settings-sharing'));
        await tester.ensureVisible(row);
        await tester.pump();
        await tester.tap(row);
        await _settle(tester);
        await tester.runAsync(sharing.refresh);
        await _settle(tester);
        expect(find.textContaining(via == 'wifi' ? 'Same Wi-Fi' : 'Connected directly'), findsWidgets);
        await snap(tester, _out, 'same-$via-$t');

        await tester.pumpWidget(const SizedBox());
        sharing.dispose();
        await r.dispose(tester);
      });
    }
  }
}

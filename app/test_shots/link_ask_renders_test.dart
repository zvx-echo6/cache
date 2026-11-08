// Sharing and sync (1.1.0): the question right after a new link ("Sync Cache settings with Desk?": Both ways, Send mine, Not
// now), reached as the app does (Settings > Sharing and sync > Enter a link code > Link), at 390 and 1440 points wide, light
// and dark.
// flutter test test_shots/link_ask_renders_test.dart --update-goldens  (pictures in test_shots/link_ask/)

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

const _out = 'link_ask';

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

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('link ask ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final sync = FakeSync();
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

        final size = e.value;
        final ratio = size.width < 600 ? 3.0 : 1.0;
        phone(tester, size: size, ratio: ratio);
        await tester.pumpWidget(shotApp(SettingsScreen(deps: r.deps), theme: theme, insets: size.width < 600 ? null : EdgeInsets.zero));
        await _settle(tester);
        await _tap(tester, find.byKey(const ValueKey('settings-sharing')));
        await _tap(tester, find.byKey(const ValueKey('enter-code')));
        await tester.enterText(find.byType(TextField), 'CACHE1-TESTCODE');
        await _tap(tester, find.widgetWithText(FilledButton, 'Link'));
        expect(find.text('Sync Cache settings with Desk?'), findsOneWidget);
        await snap(tester, _out, '1-ask-${e.key}-$t');

        // Answered: Send mine.
        await _tap(tester, find.byKey(const ValueKey('ask-send')));
        expect(sync.peers.single['link'], {'mode': 'send', 'from': 'me'});

        await tester.pumpWidget(shotApp(const SizedBox(), theme: theme));
        await _settle(tester);
        await tester.runAsync(settingsSync.flush);
        settingsSync.dispose();
        sharing.dispose();
        layout.dispose();
        await r.dispose(tester);
      });
    }
  }
}

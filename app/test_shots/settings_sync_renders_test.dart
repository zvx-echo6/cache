// Sharing and sync, part B (1.1.0): a linked device's Settings section with each choice (Match, Send mine, Off, and the device
// that follows: "Follows Desk's settings"), What's included, one group's page (Ask, with a model not downloaded here) and API
// keys, opened from Settings as the app does, at 390, 820, 1180 and 1440 points wide, light and dark.
// flutter test test_shots/settings_sync_renders_test.dart --update-goldens  (pictures in test_shots/settings_sync/)

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
import 'beta_sizes.dart';
import 'shot_kit.dart';

const _out = 'settings_sync';

/// The sizes drawn (the beta checklist's with BETA_SIZES, see beta_sizes.dart).
final Map<String, Size> _sizes = kBeta ? kBetaSizes : const {
  '390': Size(390, 844),
  '820': Size(820, 1180),
  '1180': Size(1180, 820),
  '1440': Size(1440, 900),
};

Future<void> _settle(WidgetTester tester, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, Size size, CacheThemeId theme) async {
  final ratio = kBeta ? betaRatio(size) : (size.width < 600 ? 3.0 : (size.width >= 1280 ? 1.0 : 2.0));
  phone(tester, size: size, ratio: ratio);
  final insets = kBeta ? betaInsets(size) : (size.width < 600 ? null : (size.width >= 1280 ? EdgeInsets.zero : const EdgeInsets.only(top: 24, bottom: 20)));
  await tester.pumpWidget(shotApp(page, theme: theme, insets: insets));
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
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('settings sync ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final now = DateTime.now().millisecondsSinceEpoch;
        final sync = FakeSync()
          ..peers.addAll([
            {'id': 'peer1', 'name': 'Desk', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null, 'free_bytes': 612 << 30, 'link_known': true},
            {'id': 'peer2', 'name': 'Tablet', 'linked': 1, 'last_seen': now - 3600000, 'via': 'relay', 'error': null, 'link_known': true},
          ]);
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
        final layout = LayoutState(settingsDirOverride: r.dir);
        final dir = Directory('${r.dir.path}/$kSettingsShareDir');
        final keys = [
          SyncedKey(name: 'search.kagi.key', label: 'Kagi (web search)', read: () async => 'k1'),
          SyncedKey(name: 'live.key.owm', label: 'OpenWeather', read: () async => 'k2'),
          SyncedKey(name: 'live.key.river', label: 'Your own: River gauge', read: () async => 'k3'),
        ];
        final settingsSync = SettingsSync(
          sharing: sharing,
          settings: appSyncedSettings(app: r.app, layout: layout, settings: r.settings, maps: r.maps, weather: r.weather),
          keys: () => keys,
          storeKey: (_, _) async => false,
          dir: () async => dir,
          downloadModel: (_) async {},
          every: const Duration(hours: 1),
        );
        await tester.runAsync(() async {
          await layout.init();
          await sharing.setUp();
          await settingsSync.start();
          await settingsSync.setKeyOn('peer1', 'search.kagi.key', true);
          await settingsSync.setKeyOn('peer1', 'live.key.owm', true);
          // Desk uses a model this phone does not have.
          File('${dir.path}/log/peer1.jsonl')
            ..createSync(recursive: true)
            ..writeAsStringSync('${const SettingsEvent(
              at: 1 << 42,
              dev: 'peer1',
              key: kModelSettingKey,
              value: 'gemma-4-E4B-it-Q4_K_M.gguf',
              note: {'name': 'Gemma 4 E4B · Q4_K_M', 'download': {'repo': 'org/gemma', 'path': 'gemma-4-E4B-it-Q4_K_M.gguf', 'size': 5 << 30}},
            ).toLine()}\n');
          await settingsSync.pull();
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

        Future<void> openDevice() async {
          await _show(tester, SettingsScreen(deps: r.deps), e.value, theme);
          await _tap(tester, 'settings-sharing');
          await _tap(tester, 'peer-peer1');
        }

        // 1-3: the device page with each choice
        await openDevice();
        await snap(tester, _out, '1-device-match-${e.key}-$t');
        await _tap(tester, 'link-send');
        await snap(tester, _out, '2-device-send-${e.key}-$t');
        await _tap(tester, 'link-off');
        await snap(tester, _out, '3-device-off-${e.key}-$t');

        // 4-5: What's included, and one group's page (Ask)
        await _tap(tester, 'link-match');
        await _tap(tester, 'link-included');
        await snap(tester, _out, '4-included-${e.key}-$t');
        await _tap(tester, 'group-ask');
        await snap(tester, _out, '5-group-ask-${e.key}-$t');

        // 6: API keys
        await openDevice();
        await _tap(tester, 'link-keys');
        await snap(tester, _out, '6-api-keys-${e.key}-$t');

        // 7: on the device that follows Desk's settings
        sync.peers.first['link'] = {'mode': 'send', 'from': 'peer1'};
        await tester.runAsync(sharing.refresh);
        await openDevice();
        await snap(tester, _out, '7-device-follows-${e.key}-$t');

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

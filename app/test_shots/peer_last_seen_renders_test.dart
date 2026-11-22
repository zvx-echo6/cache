// Linked devices (1.1.0): the Sharing list and a device's page when it was never reached, when it was seen 5 minutes ago through a
// relay, and when it was never reached and linked over 7 days ago (with Unlink), at 390 and 1440 points wide in Light, Dark and Tactical.
// flutter test test_shots/peer_last_seen_renders_test.dart --update-goldens  (pictures in test_shots/peer-last-seen/)

import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'peer-last-seen';
const _gb = 1 << 30;

const Map<String, Size> _sizes = {'390': Size(390, 844), '1440': Size(1440, 900)};
const Map<String, CacheThemeId> _themes = {'light': CacheThemeId.light, 'dark': CacheThemeId.dark, 'tactical': CacheThemeId.tactical};

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

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final th in _themes.entries) {
      testWidgets('peer last seen ${e.key} ${th.key}', (tester) async {
        final r = await SettingsRig.create(tester);
        final now = DateTime.now().millisecondsSinceEpoch;
        const day = 24 * 3600 * 1000;
        final sync = FakeSync()
          ..peers.addAll([
            {'id': 'never', 'name': 'Android device', 'linked': now - 2 * day, 'last_seen': null, 'via': null, 'error': 'not reachable'},
            {'id': 'seen', 'name': 'Tablet', 'linked': now - 30 * day, 'last_seen': now - 5 * 60000, 'via': 'relay', 'error': null, 'free_bytes': 88 * _gb},
            {'id': 'old', 'name': 'Android device', 'linked': now - 12 * day, 'last_seen': null, 'via': null, 'error': 'not reachable'},
          ]);
        final sharing = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], deviceName: 'Test phone', opener: (_) async => sync);
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

        Future<void> openSharing() async {
          await _show(tester, SettingsScreen(deps: r.deps), e.value, th.value);
          final row = find.byKey(const ValueKey('settings-sharing'));
          await tester.ensureVisible(row);
          await tester.pump();
          await tester.tap(row);
          await _settle(tester);
        }

        await openSharing();
        final list = find.byKey(const ValueKey('peer-never'));
        await tester.ensureVisible(list);
        await tester.pump();
        await snap(tester, _out, '1-list-${e.key}-${th.key}');

        var n = 2;
        for (final (id, label) in [('never', 'never'), ('seen', 'seen-relay'), ('old', 'never-unlink')]) {
          await openSharing();
          await tester.ensureVisible(find.byKey(ValueKey('peer-$id')));
          await tester.pump();
          await tester.tap(find.byKey(ValueKey('peer-$id')));
          await _settle(tester);
          await snap(tester, _out, '${n++}-$label-${e.key}-${th.key}');
          if (id == 'old') {
            // The one question before it is unlinked.
            await tester.tap(find.byKey(const ValueKey('device-unlink-never')));
            await _settle(tester);
            await snap(tester, _out, '${n++}-unlink-question-${e.key}-${th.key}');
          }
        }

        await _show(tester, const SizedBox(), e.value, th.value);
        sharing.dispose();
        await r.dispose(tester);
      });
    }
  }
}

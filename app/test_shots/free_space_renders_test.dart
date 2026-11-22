// Free space (1.1.0): Settings > Storage and Sharing > This device, which show the same free-now figure and the same kept-free
// reserve (the app hands its reserve to the sharing engine when it starts), at 390 and 1440 points wide in Light, Dark and Tactical.
// flutter test test_shots/free_space_renders_test.dart --update-goldens  (pictures in test_shots/free-space/)

import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/sync_fake.dart';
import 'shot_kit.dart';

const _out = 'free-space';
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
      testWidgets('free space ${e.key} ${th.key}', (tester) async {
        final r = await SettingsRig.create(tester);
        // The rig's phone: 128 GB with 41 GB free now. The engine is started with the app's reserve and shows the same figures.
        final sync = FakeSync()..freeBytes = 41 * _gb;
        final sharing = SharingState(
          policy: r.policy,
          supportDir: () async => r.dir,
          kinds: const [],
          deviceName: 'Test phone',
          reserveBytes: (_) => reserveFor(128 * _gb),
          opener: (c) async {
            sync.reserveBytes = c['reserve_bytes'] as int;
            return sync;
          },
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

        Future<void> open(String key) async {
          await _show(tester, SettingsScreen(deps: r.deps), e.value, th.value);
          final row = find.byKey(ValueKey(key));
          await tester.ensureVisible(row);
          await tester.pump();
          await tester.tap(row);
          await _settle(tester);
        }

        await open('settings-storage');
        await snap(tester, _out, '1-storage-${e.key}-${th.key}');

        await open('settings-sharing');
        await snap(tester, _out, '2-this-device-${e.key}-${th.key}');

        await _show(tester, const SizedBox(), e.value, th.value);
        sharing.dispose();
        await r.dispose(tester);
      });
    }
  }
}

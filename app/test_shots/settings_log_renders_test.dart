// Settings > Log (1.1): the Settings home with its Log row, and the Log page opened from it as the app does (level, Share log,
// Clear log), at 390 and 1440 points wide, light and dark.
// flutter test test_shots/settings_log_renders_test.dart --update-goldens  (pictures in test_shots/settings_log/)

import 'dart:io';

import 'package:cache/platform/app_log.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'settings_log';

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

void main() {
  setUpAll(loadShotFonts);

  for (final e in _sizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('settings log ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        await tester.runAsync(() async {
          await appLog.open(Directory('${r.dir.path}/logs'));
          await appLog.setLevel(LogLevel.standard);
          logInfo('Cache started');
        });

        // 1: the Settings home, with the Log row
        await _show(tester, SettingsScreen(deps: r.deps), e.value, theme);
        final row = find.byKey(const ValueKey('settings-log'));
        await tester.ensureVisible(row);
        await _settle(tester, 4);
        await snap(tester, _out, '1-settings-${e.key}-$t');

        // 2: the Log page, opened from the row
        await tester.tap(row);
        await _settle(tester);
        await snap(tester, _out, '2-log-${e.key}-$t');

        await _show(tester, const SizedBox(), e.value, theme);
        await tester.runAsync(appLog.close);
        await r.dispose(tester);
      });
    }
  }
}

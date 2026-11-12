// Settings > Appearance with the Car group (shown only in a build with Android Auto; the gate is forced on here), for review.
// flutter test test_shots/car_settings_renders_test.dart --update-goldens  (pictures in test_shots/car_settings/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/car/car_support.dart';
import 'package:cache/screens/settings/appearance_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  for (final id in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    testWidgets('Settings > Appearance > Car, phone-390, ${id.name}', (tester) async {
      carScreenSupported.value = true;
      addTearDown(() => carScreenSupported.value = false);
      final dir = Directory.systemTemp.createTempSync('car-settings-shot-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..theme = id;
      phone(tester, size: const Size(390, 1000), ratio: 3);
      await tester.pumpWidget(shotApp(AppearancePage(app: app), theme: id));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await snap(tester, 'car_settings', 'phone-390-${id.name}');
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    });
  }
}

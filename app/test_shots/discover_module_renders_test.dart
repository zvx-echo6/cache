// The Modules page with Discover listed, at 390 x 844 in light, dark and Tactical, drawn by the app's own widgets.
import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('Modules with Discover at 390', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: Directory('${r.dir.path}/layout')..createSync());
    await tester.runAsync(layout.init);
    for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
      phone(tester, size: const Size(390, 844), ratio: 2);
      await tester.pumpWidget(shotApp(ModulesScreen(layout: layout, app: r.app, onOpen: (_) {}), theme: theme, insets: const EdgeInsets.only(top: 44, bottom: 30)));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await snap(tester, 'discover_module', '390-modules-${theme.name}');
    }
    await tester.pumpWidget(const SizedBox());
    layout.dispose();
    await r.dispose(tester);
  });
}

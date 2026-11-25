// Cache on Linux, as built: the "Run the installer again" card at the top of Settings (the server says run_installer_again), and the
// How dialog, at 1440x900 inside the desktop shell, dark and light. Pictures in test_shots/run-installer-notice-built/. Not part of
// the test suite.
// flutter test test_shots/run_installer_notice_built_test.dart --update-goldens
import 'package:cache/desktop/desktop_shell.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'run-installer-notice-built';

const Map<String, CacheThemeId> _themes = {'dark': CacheThemeId.dark, 'light': CacheThemeId.light};

void main() {
  setUpAll(loadShotFonts);
  setUp(() => debugLinuxUi = true);
  tearDown(() => debugLinuxUi = null);

  for (final th in _themes.entries) {
    for (final how in [false, true]) {
      testWidgets('run installer card 1440x900 ${th.key}${how ? ' how' : ''}', (tester) async {
        final r = await SettingsRig.create(tester);
        const size = Size(1440, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final page = SettingsScreen(deps: r.deps, runInstallerAgain: () async => true);
        final shown = DesktopShell(atHome: false, module: ModuleId.settings, onHome: () {}, onModule: (_) {}, onModuleOptions: (c, m) {}, child: page);
        await tester.pumpWidget(shotApp(shown, theme: th.value, insets: EdgeInsets.zero, desktop: true));
        for (var i = 0; i < 14; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump(const Duration(milliseconds: 40));
        }
        if (how) {
          await tester.tap(find.byKey(const ValueKey('settings-run-installer-how')));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }
        final e = tester.takeException();
        final name = '1440x900-settings-b-${th.key}${how ? '-how' : ''}-built';
        // ignore: avoid_print
        print('RIN-SHOT $name${e == null ? '' : ' EXC ${e.toString().split('\n').first}'}');
        await snap(tester, _out, name);
        await tester.pumpWidget(const SizedBox());
        await r.dispose(tester);
      });
    }
  }
}

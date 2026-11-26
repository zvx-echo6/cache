// Pictures of the real First aid screens (the owner's review renders): the CPR metronome ready, running, in the breaths pause and
// hands-only, drawn by the app's own widgets on the phone's theme.
// flutter test test_shots/first_aid_renders_test.dart --update-goldens   (pictures in test_shots/first_aid/)
import 'dart:io';

import 'package:cache/firstaid/cpr_metronome.dart';
import 'package:cache/firstaid/cpr_prefs.dart';
import 'package:cache/firstaid/first_aid_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/cpr_fakes.dart';
import 'shot_kit.dart';

const _folder = 'first_aid';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('First aid pictures', (tester) async {
    final dir = Directory.systemTemp.createTempSync('cpr-shot');
    final prefs = CprPrefs(settingsDirOverride: dir);
    await tester.runAsync(prefs.init);

    Future<void> shot(String name, {required CprMode mode, Duration after = Duration.zero, bool start = false, bool dark = false}) async {
      final clock = FakeClock();
      final m = CprMetronome(feedback: FakeFeedback(clock), mode: mode, now: () => clock.now, timer: clock.timer);
      phone(tester, size: const Size(1080 / 2.625, 2400 / 2.625), ratio: 2.625);
      await tester.pumpWidget(shotApp(CprScreen(prefs: prefs, metronome: m, canCall: true), theme: dark ? CacheThemeId.dark : CacheThemeId.parchment, insets: const EdgeInsets.only(top: 54, bottom: 34)));
      if (start) {
        await m.start();
        clock.advance(after);
      }
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await snap(tester, _folder, name);
      await tester.pumpWidget(const SizedBox());
    }

    await shot('03-ready', mode: CprMode.handsOnly);
    await shot('03b-ready-breaths', mode: CprMode.withBreaths);
    await shot('04-running-30-2', mode: CprMode.withBreaths, start: true, after: Duration(microseconds: (16 * kCprBeatMicros).round() + 1000));
    await shot('05-breaths', mode: CprMode.withBreaths, start: true, after: Duration(microseconds: (29 * kCprBeatMicros).round() + 1000 + 1000000));
    await shot('06-handsonly', mode: CprMode.handsOnly, start: true, after: const Duration(seconds: 134));
    prefs.dispose();
    dir.deleteSync(recursive: true);
  });
}

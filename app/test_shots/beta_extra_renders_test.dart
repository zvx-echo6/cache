// The beta checklist's screens that no other render test draws: the launch screen, the lock screen and App PIN, About, Reported
// answers, the map layers catalogue and the videos library, drawn by the app's own widgets with sample data (no personal data) at
// the beta checklist's four sizes (beta_sizes.dart), light and dark.
// flutter test test_shots/beta_extra_renders_test.dart --update-goldens  (pictures in test_shots/beta_extra/)

import 'package:cache/brand.dart';
import 'package:cache/chat/answer_reports.dart';
import 'package:cache/maps/ui/catalogue_screen.dart';
import 'package:cache/screens/answer_reports_ui.dart';
import 'package:cache/screens/pin_screen.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/screens/videos/library_screen.dart' as videos;
import 'package:cache/settings/app_pin.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'beta_sizes.dart';
import 'shot_kit.dart';

const _out = 'beta_extra';

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final e in kBetaSizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme == CacheThemeId.dark ? 'dark' : 'light';
      testWidgets('beta extra ${e.key} $t', (tester) async {
        final r = await SettingsRig.create(tester);
        final pin = AppPin(MemoryTokenStore(), iterations: 10);
        await tester.runAsync(() => pin.set('2468'));
        final reports = AnswerReports(dirOverride: r.dir);

        Future<void> shot(String name, Widget page) async {
          phone(tester, size: e.value, ratio: betaRatio(e.value));
          await tester.pumpWidget(shotApp(page, theme: theme, insets: betaInsets(e.value)));
          await _settle(tester);
          // a layout error drawn in the picture is listed, not fatal (the checklist marks it)
          final x = tester.takeException();
          // ignore: avoid_print
          if (x != null) print('BETA-EXC ${e.key}-$name-$t: ${x.toString().split('\n').first}');
          await snap(tester, _out, '${e.key}-$name-$t');
        }

        await shot('launch', const LaunchScreen());
        await shot('pin-lock', PinLockScreen(pin: pin));
        await shot('app-pin', AppPinScreen(pin: pin));
        await shot('about', const AboutPage());
        await shot('reported-answers', ReportedAnswersPage(reports: reports));
        await shot('map-layers-catalogue', CatalogueScreen(maps: r.maps));
        await shot('videos-library', videos.LibraryScreen(video: r.video));
        await tester.pumpWidget(const SizedBox());
        await r.dispose(tester);
      });
    }
  }
}

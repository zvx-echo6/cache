// Add your own source (1.1.0): More sources with "Your own" and Add your own source, the form, and Pick what to show (an answer,
// and one that is not JSON), in the light and dark themes, at phone and tablet width.
// flutter test test_shots/own_source_renders_test.dart --update-goldens  (pictures in test_shots/own/)

import 'package:cache/screens/settings/own_source_pages.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/own_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'beta_sizes.dart';
import 'shot_kit.dart';

const _out = 'own';

const Size _phone = Size(430, 932);
const Size _tablet = Size(820, 1180);

/// The sizes drawn (the beta checklist's with BETA_SIZES, see beta_sizes.dart).
final List<Size> _sizes = kBeta ? kBetaSizes.values.toList() : const [_phone, _tablet];
String _sizeName(Size size) => kBeta ? kBetaSizes.entries.firstWhere((e) => e.value == size).key : (size == _phone ? 'phone' : 'tablet');

const _answer = {
  'station': {'id': 'site-12', 'name': 'Bridge gauge', 'latitude': 42.53, 'longitude': -113.79},
  'water': {'level': 1.42, 'trend': 'Rising'},
  'updated': '12:40',
  'battery': 87,
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, CacheThemeId theme, Size size) async {
  phone(tester, size: size, ratio: kBeta ? betaRatio(size) : (size == _phone ? 3 : 2));
  await tester.pumpWidget(shotApp(page, theme: theme, insets: kBeta ? betaInsets(size) : (size == _phone ? null : const EdgeInsets.only(top: 24, bottom: 20))));
  await _settle(tester);
}

String _name(String screen, CacheThemeId theme, Size size) => '${kBeta ? '${_sizeName(size)}-$screen' : '$screen-${_sizeName(size)}'}-${theme == CacheThemeId.dark ? 'dark' : 'light'}';

void main() {
  setUpAll(loadShotFonts);

  for (final size in _sizes) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      testWidgets('More sources, the form and Pick what to show: ${_name('own', theme, size)}', (tester) async {
        final r = await SettingsRig.create(tester);
        await tester.runAsync(() async {
          await r.weather.saveOwnSource(
            const OwnDraft(name: 'Creek level at the bridge', address: 'https://sensors.example.org/api/creek?site=12'),
            const [OwnPick('water.level', 'Water level'), OwnPick('water.trend', 'Trend')],
          );
        });

        // 1: More sources, with Your own and Add your own source
        await _show(tester, MoreSourcesPage(deps: r.deps), theme, size);
        await snap(tester, _out, _name('1-more-sources', theme, size));

        // 2: the form, filled in
        await _show(tester, OwnSourceFormPage(deps: r.deps), theme, size);
        await tester.enterText(find.byKey(const ValueKey('own-name')), 'Creek level at the bridge');
        await tester.enterText(find.byKey(const ValueKey('own-address')), 'https://sensors.example.org/api/creek?site=12&lat={lat}&lon={lon}');
        await tester.enterText(find.byKey(const ValueKey('own-key')), 'abcdef123456');
        FocusManager.instance.primaryFocus?.unfocus();
        await _settle(tester);
        await snap(tester, _out, _name('2-form', theme, size));

        // 2b: the form says what is wrong
        await tester.enterText(find.byKey(const ValueKey('own-address')), 'https://sensors.example.org/api/creek?site=12');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.tap(find.byKey(const ValueKey('own-try')));
        await _settle(tester);
        await snap(tester, _out, _name('2b-form-problem', theme, size));

        // 3: Pick what to show, after an answer
        const draft = OwnDraft(name: 'Creek level at the bridge', address: 'https://sensors.example.org/api/creek?site=12&lat={lat}&lon={lon}');
        await _show(
          tester,
          OwnSourcePickPage(deps: r.deps, draft: draft, first: OwnTry.ok('sensors.example.org', flattenJson(_answer)), earlier: const [OwnPick('water.level', 'Water level'), OwnPick('water.trend', 'Trend'), OwnPick('updated', 'Updated')]),
          theme,
          size,
        );
        await snap(tester, _out, _name('3-pick', theme, size));

        // 3b: an answer that is not JSON
        await _show(tester, OwnSourcePickPage(deps: r.deps, draft: draft, first: const OwnTry.failed('sensors.example.org', OwnTryFailure.notJson)), theme, size);
        await snap(tester, _out, _name('3b-pick-not-json', theme, size));

        // 4: the import page
        await _show(tester, OwnImportPage(deps: r.deps), theme, size);
        await snap(tester, _out, _name('4-import', theme, size));
        await r.dispose(tester);
      });
    }
  }
}

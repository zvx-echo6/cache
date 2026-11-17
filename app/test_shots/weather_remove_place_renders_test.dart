// Weather and alerts > Saved places: Remove on a row that is waiting for its saved place (owner's design, 2026-11-16), and its
// confirm. 390 wide, light. Made-up place names; the real page on the settings test rig.
// flutter test test_shots/weather_remove_place_renders_test.dart --update-goldens  (pictures in test_shots/weather_remove_place/)
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  const folder = 'weather_remove_place';

  Future<SettingsRig> page(WidgetTester tester) async {
    final r = await SettingsRig.create(tester);
    phone(tester, size: const Size(390, 844), ratio: 2);
    r.liveCore.saved = const [SavedPlaceRecord(key: 'larkspur', name: 'Larkspur Cabin', lat: 43.1, lon: -114.2)];
    for (final id in ['place:larkspur', 'place:x', 'place:y']) {
      r.settings.setWatched(id, true);
    }
    await tester.pumpWidget(shotApp(WeatherPage(deps: r.deps)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('watch-place:larkspur')));
    await tester.drag(find.byType(ListView).first, const Offset(0, 120));
    await tester.pumpAndSettle();
    return r;
  }

  testWidgets('a the list: one named place, two waiting, each with Remove', (tester) async {
    final r = await page(tester);
    expect(find.text('Remove'), findsNWidgets(2));
    await snap(tester, folder, 'a-list');
    await r.dispose(tester);
  });

  testWidgets('b the confirm', (tester) async {
    final r = await page(tester);
    await tester.tap(find.byKey(const ValueKey('watch-remove-place:x')));
    await tester.pumpAndSettle();
    await snap(tester, folder, 'b-confirm');
    await r.dispose(tester);
  });
}

// A device shows and fetches weather only for the watched places it HAS. A watch from a linked device whose saved place is not on this
// device is kept in the setting (it still syncs on) but is not listed, not shown and not fetched, and there is no "waiting for this
// place" row. When the place arrives (Notebooks sharing switched on) its weather appears with no tap and no restart.

import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/event_loop.dart';
import 'support/settings_rig.dart';
import 'support/weather_screen_kit.dart';

const _cabin = SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43.1, lon: -114.2);

bool _fetchedFor(SettingsRig r, String key) => r.liveCore.fetches.any((f) => '${f['place']}'.contains(key));

void main() {
  testWidgets('a watch whose place is not here: kept in the setting, not listed, not fetched, no waiting row', (tester) async {
    final r = await SettingsRig.create(tester);
    await useScreenSources(tester, r, ['openmeteo-forecast']);
    r.settings.setWatched('place:cabin', true);
    r.settings.setWatched('place:x', true);
    r.liveCore.saved = [_cabin];
    await r.show(tester, WeatherPage(deps: r.deps));
    await tester.pumpAndSettle();
    expect(r.settings.watchedPlaces, containsAll(['place:cabin', 'place:x']), reason: 'nothing is lost: it still syncs on');
    await tester.runAsync(() async {
      final listed = [for (final p in await r.weather.watchedPlaces()) p.id];
      expect(listed, contains('place:cabin'));
      expect(listed, isNot(contains('place:x')));
      await r.weather.updateNow(force: true);
    });
    expect(_fetchedFor(r, 'cabin'), isTrue);
    expect(_fetchedFor(r, 'x'), isFalse, reason: 'a place this device does not have is not fetched');
    expect(find.text('waiting for this place'), findsNothing);
    expect(find.text('A saved place'), findsNothing);
    expect(find.byKey(const ValueKey('watch-place:x')), findsNothing);
    expect(find.byKey(const ValueKey('watch-place:cabin')), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('the place arrives: it is listed and fetched without a tap or a restart', (tester) async {
    final r = await SettingsRig.create(tester);
    await useScreenSources(tester, r, ['openmeteo-forecast']);
    r.settings.setWatched('here', false);
    r.settings.setWatched('place:cabin', true);
    r.liveCore.saved = const [];
    await r.show(tester, WeatherPage(deps: r.deps));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('watch-place:cabin')), findsNothing);
    expect(_fetchedFor(r, 'cabin'), isFalse);
    // Notebooks sharing is switched on: the saved place comes in
    r.liveCore.saved = [_cabin];
    await tester.runAsync(() => r.weather.savedPlacesChanged());
    // the page reads the places again (the settings file is written for real): wait for the row, never for a stretch of time
    await pumpWidgetsUntil(tester, () => find.byKey(const ValueKey('watch-place:cabin')).evaluate().isNotEmpty, what: 'the arrived place listed');
    await pumpWidgetsUntil(tester, () => _fetchedFor(r, 'cabin'), what: 'the arrived place fetched');
    expect(find.byKey(const ValueKey('watch-place:cabin')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('watch-place:cabin')), matching: find.text('Cabin')), findsOneWidget);
    expect(_fetchedFor(r, 'cabin'), isTrue, reason: 'its weather is fetched by itself');
    await r.dispose(tester);
  });
}

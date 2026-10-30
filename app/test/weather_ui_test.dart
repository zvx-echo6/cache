import 'package:cache/screens/settings/catalogues_page.dart';
import 'package:cache/screens/settings/places_page.dart';
import 'package:cache/screens/settings/source_page.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/curated.dart';
import 'package:cache/weather/places.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_fakes.dart';

Finder rowWith(String title) => find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;

Switch switchIn(WidgetTester tester, String title) => tester.widget<Switch>(find.descendant(of: rowWith(title), matching: find.byType(Switch)));

const secret = 'SENTINEL-KEY-77b0e2-do-not-leak';

/// A tall screen, so every source row is built.
void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('Weather and alerts', () {
    testWidgets('one line for the age with a small refresh button; the catalogue\'s featured sources, the rest under More sources; places', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      expect(find.text('Weather and alerts'), findsOneWidget);
      expect(find.text('Nothing switched on yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('weather-refresh')), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      expect(find.text('What Cache watches for your places. All free; some need a free key you get from the provider.'), findsOneWidget);
      for (final t in ['Weather alerts (NWS, by point)', 'Weather forecast (Open-Meteo)', 'Wildfires near the place (WFIGS)', 'Earthquakes near the place (USGS)']) {
        expect(find.text(t), findsOneWidget, reason: t);
        expect(switchIn(tester, t).value, isFalse, reason: '$t starts off');
      }
      // Each row says what the source gives and who provides it.
      expect(find.text('What Weather forecast (Open-Meteo) gives · Open-Meteo'), findsOneWidget);
      // A featured source that needs a key has "Get key" on its row.
      expect(find.text('Satellite fire detections near the place (NASA FIRMS)'), findsOneWidget);
      expect(find.byKey(const ValueKey('get-key-firms-viirs-near')), findsOneWidget);
      // The rest, under More sources.
      expect(find.text('Space weather: Kp index'), findsNothing);
      expect(find.text('More sources'), findsOneWidget);
      expect(find.text('3 more'), findsOneWidget);
      // Weather alerts and fires have their own icons.
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('Where I am'), findsOneWidget, reason: 'the Places summary');
      expect(find.text('Advanced'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('a keyless source is switched on with its switch: it is registered with the core and in the policy', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      const t = 'Wildfires near the place (WFIGS)';
      await tester.tap(find.descendant(of: rowWith(t), matching: find.byType(Switch)));
      await tester.pump();
      await tester.pump();
      expect(switchIn(tester, t).value, isTrue);
      expect(r.weather.registeredIds, {'wfigs-incidents-near'});
      expect(r.liveCore.policies.last!['enabled_sources'], ['wfigs-incidents-near']);
      expect(find.text('Not updated yet'), findsOneWidget);
      await tester.tap(find.descendant(of: rowWith(t), matching: find.byType(Switch)));
      await tester.pump();
      await tester.pump();
      expect(switchIn(tester, t).value, isFalse);
      expect(r.weather.registeredIds, isEmpty);
      await r.dispose(tester);
    });

    testWidgets('Get key on the row: saving checks the key, switches the source on and never shows it again', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.byKey(const ValueKey('get-key-firms-viirs-near')));
      await tester.pumpAndSettle();
      expect(find.text('Get a key from NASA FIRMS'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('get-key')));
      await tester.pump();
      expect(r.opened, ['https://firms.modaps.eosdis.nasa.gov/api/area/']);
      // refused first
      r.liveCore.previewError = const CacheSearchException('key_missing', 'rejected');
      await tester.enterText(find.byKey(const ValueKey('key-field')), secret);
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-error')), findsOneWidget);
      expect(find.textContaining("NASA FIRMS didn't accept this key"), findsOneWidget);
      expect(r.secrets.values, isEmpty);
      // then accepted
      r.liveCore.previewError = null;
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-field')), findsNothing, reason: 'the sheet closed');
      expect(find.byKey(const ValueKey('get-key-firms-viirs-near')), findsNothing);
      expect(switchIn(tester, 'Satellite fire detections near the place (NASA FIRMS)').value, isTrue);
      expect(r.liveCore.keys['firms-viirs-near'], secret);
      // the key is on no screen
      expect(find.textContaining(secret), findsNothing);
      expect(find.textContaining('SENTINEL'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('the refresh button updates and says what happened; on mobile data it still updates', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.descendant(of: rowWith('Weather alerts (NWS, by point)'), matching: find.byType(Switch)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('weather-refresh')));
      await tester.pumpAndSettle();
      expect(find.text('Updated'), findsOneWidget, reason: 'the snack bar');
      expect(find.text('Updated just now'), findsOneWidget, reason: 'the status line');
      expect(r.liveCore.fetches.length, 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      r.probe.change(ConnectionKind.mobile);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('weather-refresh')));
      await tester.pumpAndSettle();
      expect(r.liveCore.fetches.length, 2, reason: 'updates use mobile data');
      await r.dispose(tester);
    });

    testWidgets('old data turns the line into a warning with the age and the reason', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() async {
        await r.weather.setRowOn(kCurated.first, true);
        await r.weather.updateNow();
      });
      r.clock = r.clock.add(const Duration(days: 3));
      r.probe.change(ConnectionKind.none);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Updated 3 days ago · No connection since Monday'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
      await r.dispose(tester);
    });

    testWidgets('Places and More sources open their pages', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.text('Places'));
      await tester.pumpAndSettle();
      expect(find.text('Save a place on the map to add it here.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('More sources'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-sources')), findsOneWidget);
      expect(find.text('Space weather: Kp index'), findsOneWidget);
      expect(find.text('Road conditions (Idaho 511)'), findsOneWidget);
      expect(find.text('Weather alerts (NWS, by point)'), findsNothing, reason: 'featured sources are on the main page');
      await tester.enterText(find.byKey(const ValueKey('search-sources')), 'winter');
      await tester.pump();
      expect(find.text('Winter road conditions (Idaho 511)'), findsOneWidget);
      expect(find.text('Space weather: Kp index'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('search-sources')), 'zzz');
      await tester.pump();
      expect(find.text('No source matches your search.'), findsOneWidget);
      expect(find.text('Add sources from a link'), findsOneWidget);
      await r.dispose(tester);
    });

    for (final theme in CacheThemeId.values) {
      testWidgets('it draws without overflow in ${theme.label}', (tester) async {
        final r = await SettingsRig.create(tester);
        await tester.runAsync(() => r.weather.setRowOn(kCurated.first, true));
        await r.show(tester, WeatherPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Weather forecast (Open-Meteo)'), findsOneWidget);
        await r.show(tester, PlacesPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await r.show(tester, MoreSourcesPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await r.dispose(tester);
      });
    }
  });

  group('Places', () {
    testWidgets('a checklist by name: Where I am, saved places, downloaded regions; ticking is kept in the settings', (tester) async {
      final r = await SettingsRig.create(tester);
      r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9, label: 'Near Stanley')];
      r.regionList = const [WatchRegion(name: 'Idaho', lat: 44.4, lon: -114.6)];
      await r.show(tester, PlacesPage(deps: r.deps));
      await tester.pumpAndSettle();
      for (final t in ['Where I am', 'Cabin', 'Idaho']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('Follows the phone'), findsOneWidget);
      expect(find.text('Near Stanley'), findsOneWidget);
      expect(find.text('Downloaded region'), findsOneWidget);
      expect(tester.widgetList<CheckSquare>(find.byType(CheckSquare)).map((c) => c.checked), [true, false, false]);
      expect(r.settings.watchedPlaces, {'here'});
      await tester.tap(find.text('Cabin'));
      await tester.pump();
      await tester.tap(find.text('Idaho'));
      await tester.pump();
      await tester.tap(find.text('Where I am'));
      await tester.pump();
      expect(r.settings.watchedPlaces, {'place:cabin', 'region:Idaho'});
      await r.dispose(tester);
    });
  });

  group('Places: remove', () {
    testWidgets('a saved place can be removed after a confirm, and is no longer watched', (tester) async {
      final r = await SettingsRig.create(tester);
      r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9)];
      r.regionList = const [WatchRegion(name: 'Idaho', lat: 44.4, lon: -114.6)];
      r.settings.setWatched('place:cabin', true);
      await r.show(tester, PlacesPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove place'), findsOneWidget, reason: 'only saved places can be removed');
      await tester.tap(find.byKey(const ValueKey('remove-place:cabin')));
      await tester.pumpAndSettle();
      expect(find.text('Remove Cabin?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r.liveCore.deleted, isEmpty);
      await tester.tap(find.byKey(const ValueKey('remove-place:cabin')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('confirm-remove-place')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(r.liveCore.deleted, ['cabin']);
      expect(r.settings.watchedPlaces.contains('place:cabin'), isFalse);
      expect(find.text('Cabin'), findsNothing);
      expect(find.text('Idaho'), findsOneWidget);
      await r.dispose(tester);
    });
  });

  group('A data source', () {
    testWidgets('what it gives, who provides it, how often, how old the copy is, the last problem, and its switch', (tester) async {
      final r = await SettingsRig.create(tester);
      r.liveCore.stored['wfigs-incidents-near'] = {'age': '12 minutes old', 'age_seconds': 720, 'expired': false, 'last_error': {'code': 'fetch_failed', 'message': 'HTTP 500: busy'}};
      await tester.runAsync(() => r.weather.setRowOn(kCurated[2], true));
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'wfigs-incidents-near'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.text('Wildfires near the place (WFIGS)'), findsOneWidget);
      expect(find.text('what Wildfires near the place (WFIGS) gives'), findsOneWidget);
      expect(find.text('NIFC WFIGS'), findsOneWidget);
      expect(find.text('US'), findsOneWidget);
      expect(find.text('Every 30 min'), findsOneWidget);
      expect(find.text('Data by NIFC WFIGS'), findsOneWidget);
      expect(find.text('Public domain'), findsOneWidget);
      expect(find.text('Cache connectors'), findsOneWidget);
      expect(find.text('12 minutes old'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('HTTP 500: busy'), findsOneWidget);
      expect(switchIn(tester, 'Use this source').value, isTrue);
      await tester.tap(rowWith('Use this source'));
      await tester.pumpAndSettle();
      expect(r.weather.isOn('wfigs-incidents-near'), isFalse);
      await r.dispose(tester);
    });

    testWidgets('a source that needs a key shows Get key in place of the switch; with a key it shows Replace', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'));
      await tester.pumpAndSettle();
      expect(find.text('Needs your own key'), findsOneWidget);
      expect(find.text('Get key'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      await tester.tap(find.text('Get key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('key-field')), secret);
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(find.text('Replace'), findsOneWidget);
      expect(find.text('Saved on this phone, not shown again'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(switchIn(tester, 'Use this source').value, isTrue);
      await r.dispose(tester);
    });
  });

  group('A key on its source', () {
    testWidgets('a saved key is never shown, and is replaced or removed (after asking) on its source', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.weather.saveKey(r.weather.sourceById('firms-viirs-near')!, secret));
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'));
      await tester.pumpAndSettle();
      expect(find.textContaining(secret), findsNothing);
      // replace
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('key-field')), '$secret-2');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(r.liveCore.keys['firms-viirs-near'], '$secret-2');
      expect(find.text('Key replaced'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      // remove
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      expect(find.textContaining('turns off'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('firms'), isTrue);
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove-key')));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('firms'), isFalse);
      expect(r.secrets.values, isEmpty);
      expect(r.liveCore.keys['firms-viirs-near'], isNull);
      expect(find.text('Get key'), findsOneWidget);
      await r.dispose(tester);
    });
  });

  group('Add sources from a link', () {
    const other = 'https://example.org/c/';

    Future<void> enterLink(WidgetTester tester, String link) async {
      await tester.enterText(find.byKey(const ValueKey('catalogue-link')), link);
      await tester.tap(find.byKey(const ValueKey('check-link')));
      await tester.pumpAndSettle();
    }

    testWidgets('a link is checked and shown before it is added; adding keeps it; removing takes it off', (tester) async {
      final r = await SettingsRig.create(tester);
      r.web.serve(
        other,
        buildCatalogue(id: 'friends', title: 'Friends catalogue', base: other, connectors: [entry('river-x', 'hydrology', 'River X', provider: 'Friends'), entry('bad-one', 'weather', 'Bad one')]),
      );
      r.liveCore.invalid.add('bad-one');
      await r.show(tester, CataloguesPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Cache connectors'), findsOneWidget, reason: 'the main catalogue');
      expect(find.textContaining('11 sources'), findsOneWidget);
      await enterLink(tester, '${other}catalogue.json');
      expect(find.byKey(const ValueKey('preview-title')), findsOneWidget);
      expect(find.text('Friends catalogue'), findsOneWidget);
      expect(find.textContaining('This adds 1 source.'), findsOneWidget);
      expect(find.text('River X · Friends · US'), findsOneWidget);
      expect(find.text('Left out (1)'), findsOneWidget);
      expect(find.textContaining('bad-one: items[0].label'), findsOneWidget);
      expect(r.weather.sourceById('river-x'), isNull, reason: 'not kept yet');
      await tester.tap(find.byKey(const ValueKey('add-catalogue')));
      await tester.pumpAndSettle();
      expect(r.weather.sourceById('river-x'), isNotNull);
      expect(find.text('Friends catalogue'), findsOneWidget, reason: 'now in the list');
      expect(find.text('Friends catalogue added'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove-catalogue')));
      await tester.pumpAndSettle();
      expect(r.weather.sourceById('river-x'), isNull);
      expect(r.settings.extraCatalogues, isEmpty);
      await r.dispose(tester);
    });

    testWidgets('a link that is not https, not a catalogue, or unreachable says so', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, CataloguesPage(deps: r.deps));
      await enterLink(tester, 'http://example.org/c.json');
      expect(find.byKey(const ValueKey('link-error')), findsOneWidget);
      expect(find.textContaining('https://'), findsWidgets);
      r.web.files['https://example.org/not.json'] = 'hello'.codeUnits;
      await enterLink(tester, 'https://example.org/not.json');
      expect(find.textContaining("didn't give a connector catalogue"), findsOneWidget);
      r.web.offline = true;
      await enterLink(tester, 'https://example.org/x.json');
      expect(find.textContaining("Couldn't reach"), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('on mobile data the check goes ahead (updates use any connection)', (tester) async {
      final r = await SettingsRig.create(tester);
      r.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends catalogue', base: other, connectors: [entry('river-x', 'hydrology', 'River X')]));
      r.probe.change(ConnectionKind.mobile);
      await r.show(tester, CataloguesPage(deps: r.deps));
      await enterLink(tester, '${other}catalogue.json');
      expect(find.byKey(const ValueKey('preview-title')), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('the main catalogue\'s address is changed in Advanced (here) and can be put back', (tester) async {
      final r = await SettingsRig.create(tester);
      const mine = 'https://mine.example.org/c/';
      r.web.serve(mine, buildCatalogue(id: 'mine', title: 'Mine', base: mine, connectors: [entry('my-quakes', 'earthquakes', 'My quakes')]));
      await r.show(tester, CataloguesPage(deps: r.deps));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Address'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('catalogue-address')), '${mine}catalogue.json');
      await tester.tap(find.byKey(const ValueKey('save-address')));
      await tester.pumpAndSettle();
      expect(r.settings.catalogueUrl, '${mine}catalogue.json');
      expect(r.weather.sourceById('my-quakes'), isNotNull);
      expect(find.text('Mine'), findsOneWidget);
      await tester.tap(find.text('Address'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use the default'));
      await tester.pumpAndSettle();
      expect(r.settings.catalogueUrl, isNull);
      expect(r.weather.sourceById('usgs-quakes-near'), isNotNull);
      await r.dispose(tester);
    });
  });
}

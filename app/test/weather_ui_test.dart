import 'package:cache/screens/settings/catalogues_page.dart';
import 'package:cache/screens/settings/data_sources_page.dart';
import 'package:cache/screens/settings/keys_page.dart';
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

void main() {
  group('Weather and alerts', () {
    testWidgets('the page of the design: status line, the free switches, the key one, places, Advanced', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      expect(find.text('Weather and alerts'), findsOneWidget);
      expect(find.text('Nothing switched on yet'), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);
      expect(find.text('NEEDS YOUR OWN KEY (FREE)'), findsOneWidget);
      for (final t in ['Weather forecast', 'Weather alerts', 'Wildfires', 'Earthquakes', 'River levels', 'Avalanche']) {
        expect(find.text(t), findsOneWidget, reason: t);
        expect(switchIn(tester, t).value, isFalse, reason: '$t starts off');
      }
      expect(find.text('16 days ahead · Open-Meteo'), findsOneWidget);
      expect(find.text('Warnings and watches · NWS'), findsOneWidget);
      expect(find.text('Fires and their edges · NIFC WFIGS'), findsOneWidget);
      expect(find.text('Satellite fire hotspots'), findsOneWidget);
      expect(find.text('Add key'), findsOneWidget);
      expect(find.text('Where I am'), findsOneWidget, reason: 'the Places summary');
      expect(find.text('Advanced'), findsOneWidget);
      expect(find.text('All data sources, more'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a keyless source is simply switched on: it is registered with the core and in the policy', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(rowWith('Wildfires'));
      await tester.pump();
      await tester.pump();
      expect(switchIn(tester, 'Wildfires').value, isTrue);
      expect(r.weather.registeredIds, {'wfigs-incidents-near', 'wfigs-perimeters-near'});
      expect(r.liveCore.policies.last!['enabled_sources'], ['wfigs-incidents-near', 'wfigs-perimeters-near']);
      expect(find.text('Not updated yet'), findsOneWidget);
      await tester.tap(rowWith('Wildfires'));
      await tester.pump();
      await tester.pump();
      expect(switchIn(tester, 'Wildfires').value, isFalse);
      expect(r.weather.registeredIds, isEmpty);
      await r.dispose(tester);
    });

    testWidgets('a source that needs a key asks for it first; saving checks it, switches the source on and never shows it again', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.text('Add key'));
      await tester.pumpAndSettle();
      expect(find.text('Satellite fire hotspots'), findsNWidgets(2), reason: 'the row and the sheet');
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
      expect(find.text('Add key'), findsNothing);
      expect(switchIn(tester, 'Satellite fire hotspots').value, isTrue);
      expect(find.textContaining('is on'), findsOneWidget);
      expect(r.liveCore.keys['firms-viirs-near'], secret);
      // the key is on no screen
      expect(find.textContaining(secret), findsNothing);
      expect(find.textContaining('SENTINEL'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('Update now: one line says what happened; on mobile data with updates off it offers "Update anyway"', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(rowWith('Weather alerts'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('update-now')));
      await tester.pumpAndSettle();
      expect(find.text('Updated'), findsOneWidget, reason: 'the snack bar');
      expect(find.text('Updated just now'), findsOneWidget, reason: 'the status line');
      expect(r.liveCore.fetches.length, 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      r.settings.setMobileForUpdates(false);
      r.probe.change(ConnectionKind.mobile);
      await tester.pumpAndSettle();
      expect(find.textContaining('Updates paused: mobile data is off for updates'), findsOneWidget);
      r.liveCore.fetchedNew = false;
      await tester.tap(find.byKey(const ValueKey('update-now')));
      await tester.pumpAndSettle();
      expect(r.liveCore.fetches.length, 1, reason: 'nothing was fetched');
      expect(find.textContaining('mobile data is switched off for updates'), findsOneWidget);
      await tester.tap(find.text('Update anyway'));
      await tester.pumpAndSettle();
      expect(r.liveCore.fetches.length, 2);
      await r.dispose(tester);
    });

    testWidgets('a stale status line gives the age and the reason', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() async {
        await r.weather.setRowOn(kCurated.first, true);
        await r.weather.updateNow();
      });
      r.clock = r.clock.add(const Duration(days: 3));
      r.probe.change(ConnectionKind.none);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Last updated 3 days ago · No connection since Monday'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('Places and Advanced open their pages', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.tap(find.text('Places'));
      await tester.pumpAndSettle();
      expect(find.text('Save a place on the map to add it here.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.text('All data sources'), findsOneWidget);
      await r.dispose(tester);
    });

    for (final theme in CacheThemeId.values) {
      testWidgets('it draws without overflow in ${theme.label}', (tester) async {
        final r = await SettingsRig.create(tester);
        await tester.runAsync(() => r.weather.setRowOn(kCurated.first, true));
        await r.show(tester, WeatherPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Weather forecast'), findsOneWidget);
        await r.show(tester, PlacesPage(deps: r.deps), theme: theme);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await r.show(tester, DataSourcesPage(deps: r.deps), theme: theme);
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

  group('All data sources', () {
    testWidgets('searchable, grouped On, Free, Needs your own key; Manage keys and Add sources from a link below', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.weather.setRowOn(kCurated[1], true));
      await r.show(tester, DataSourcesPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Search 11 sources'), findsOneWidget);
      expect(find.text('ON'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);
      expect(find.text('NEEDS YOUR OWN KEY'), findsOneWidget);
      expect(find.text('Weather alerts (NWS, by point)'), findsOneWidget);
      expect(find.text('NWS · every 15 min'), findsOneWidget);
      expect(find.text('Manage keys'), findsOneWidget);
      expect(find.text('None saved on this phone'), findsOneWidget);
      expect(find.text('Add sources from a link'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('search-sources')), 'idaho');
      await tester.pump();
      expect(find.text('Road conditions (Idaho 511)'), findsOneWidget);
      expect(find.text('Winter road conditions (Idaho 511)'), findsOneWidget);
      expect(find.text('Weather alerts (NWS, by point)'), findsNothing);
      expect(find.text('ON'), findsNothing, reason: 'empty groups have no heading');
      await tester.enterText(find.byKey(const ValueKey('search-sources')), 'zzzz');
      await tester.pump();
      expect(find.text('No source matches your search.'), findsOneWidget);
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

    testWidgets('a source that needs a key shows a key button in place of the switch; with a key it shows Replace', (tester) async {
      final r = await SettingsRig.create(tester);
      await r.show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'));
      await tester.pumpAndSettle();
      expect(find.text('Needs your own key'), findsOneWidget);
      expect(find.text('Add key'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      await tester.tap(find.text('Add key'));
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

  group('Manage keys', () {
    testWidgets('saved keys are listed by name, never shown, and can be replaced or removed after asking', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.weather.saveKey(r.weather.sourceById('firms-viirs-near')!, secret));
      await r.show(tester, KeysPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('NASA FIRMS key'), findsOneWidget);
      expect(find.textContaining('Used by Satellite fire detections'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      // replace
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('replace-key')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('key-field')), '$secret-2');
      await tester.tap(find.byKey(const ValueKey('check-and-save')));
      await tester.pumpAndSettle();
      expect(r.liveCore.keys['firms-viirs-near'], '$secret-2');
      expect(find.text('Key replaced'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      // remove
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      expect(find.textContaining('turns off'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('firms'), isTrue);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-remove-key')));
      await tester.pumpAndSettle();
      expect(r.weather.hasKey('firms'), isFalse);
      expect(r.secrets.values, isEmpty);
      expect(r.liveCore.keys['firms-viirs-near'], isNull);
      expect(find.textContaining('No keys are saved'), findsOneWidget);
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

    testWidgets('on mobile data with updates off the check waits for "Check anyway"', (tester) async {
      final r = await SettingsRig.create(tester);
      r.web.serve(other, buildCatalogue(id: 'friends', title: 'Friends catalogue', base: other, connectors: [entry('river-x', 'hydrology', 'River X')]));
      r.settings.setMobileForUpdates(false);
      r.probe.change(ConnectionKind.mobile);
      await r.show(tester, CataloguesPage(deps: r.deps));
      await enterLink(tester, '${other}catalogue.json');
      expect(find.textContaining('mobile data is switched off for updates'), findsOneWidget);
      await tester.tap(find.text('Check anyway'));
      await tester.pumpAndSettle();
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

import 'dart:async';
import 'dart:io';

import 'package:cache/location/position_source.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/weather/curated.dart';
import 'package:cache/weather/places.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

const _stanley = MapPlace(id: 'place:osm:n9', type: 'place', name: 'Stanley', kind: 'Town', address: 'Custer County, ID', lat: 44.2, lon: -114.9);

/// The three switches "Turn on weather" turns on.
Set<String> _three(SettingsRig r) => {for (final c in r.weather.enabledSources) c.id};

const _threeIds = {'openmeteo-forecast', 'nws-alerts-point', 'wfigs-incidents-near', 'wfigs-perimeters-near'};

void main() {
  WeatherTurnOn turnOn(SettingsRig r, {List<MapPlace> found = const []}) => WeatherTurnOn(
    weather: r.weather,
    location: r.location,
    searchPlaces: (q) async => found,
    savePlace: (p) async {
      r.liveCore.saved = [...r.liveCore.saved, SavedPlaceRecord(key: 'stanley', name: p.name, lat: p.lat, lon: p.lon)];
    },
  );

  // Weather always works: the three are on from the start, so the page that offers "Turn on weather" is the one for a location that
  // is not watched (the person switched it off), where the flow asks for the location and watches it.
  testWidgets('Weather, location not watched: "Turn on weather" asks for the location, watches it, keeps forecast, alerts and fires on, and updates',
      (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.notAsked);
    r.settings.setWatched('here', false);
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r), onOpenSettings: () {}));
    await tester.pumpAndSettle();
    expect(find.text('No place is being watched.'), findsOneWidget);
    expect(find.text('Choose a place instead'), findsOneWidget);
    expect(find.text('Open Weather and alerts settings'), findsOneWidget, reason: 'Settings stays reachable');
    await tester.tap(find.byKey(const ValueKey('weather-turn-on')));
    await tester.pumpAndSettle();
    expect(find.text('Use your location?'), findsOneWidget, reason: 'the usual explanation before the system asks');
    await tester.tap(find.byKey(const ValueKey('weather-location-continue')));
    await tester.pumpAndSettle();
    expect(_three(r), _threeIds);
    expect(r.settings.watchedPlaces, contains('here'));
    expect(r.location.fix, isNotNull);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    final snack = find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).join(' | ');
    expect(r.liveCore.fetches, isNotEmpty, reason: 'it updated (snack: $snack, updating: ${r.weather.updating})');
    expect(find.text('No place is being watched.'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('location refused: it offers a place instead; a saved place is watched and updated', (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.deniedForever);
    r.here = null;
    r.settings.setWatched('here', false);
    r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9, label: 'Near Stanley')];
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-turn-on')));
    await tester.pumpAndSettle();
    expect(find.text('Cache could not use your location. Choose a place instead.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-saved-place:cabin')));
    await tester.pumpAndSettle();
    expect(r.settings.watchedPlaces, contains('place:cabin'));
    expect(_three(r), _threeIds);
    expect(r.liveCore.fetches, isNotEmpty);
    await r.dispose(tester);
  });

  testWidgets('"Choose a place instead": a place found by name is saved and watched', (tester) async {
    final r = await SettingsRig.create(tester);
    r.here = null;
    r.settings.setWatched('here', false);
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r, found: [_stanley])));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-choose-place')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('weather-place-search')), 'stanley');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stanley'));
    await tester.pumpAndSettle();
    expect(r.liveCore.saved.map((s) => s.name), ['Stanley']);
    expect(r.settings.watchedPlaces, contains('place:stanley'));
    expect(_three(r), _threeIds);
    await r.dispose(tester);
  });

  testWidgets('"No place is being watched" has the same one-tap fix', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.weather.setRowOn(WeatherTurnOn.rows.first, true));
    r.settings.setWatched('here', false);
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r)));
    await tester.pumpAndSettle();
    expect(find.text('No place is being watched.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-turn-on')));
    await tester.pumpAndSettle();
    if (find.byKey(const ValueKey('weather-location-continue')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('weather-location-continue')));
      await tester.pumpAndSettle();
    }
    expect(r.settings.watchedPlaces, contains('here'));
    expect(find.text('No place is being watched.'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('Weather shows what is on the phone at once, with its age, while the core is busy; the core\'s answer follows', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.weather.setRowOn(WeatherTurnOn.rows.first, true));
    final fetched = r.clock.subtract(const Duration(minutes: 50));
    r.liveCore.stored['openmeteo-forecast'] = {
      'fetched_at': fetched.toIso8601String(),
      'age': 'less than a minute old',
      'expired': false,
      'items': [
        {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'fields': {'Temperature': '43 °F', 'Conditions': 'overcast'}},
      ],
    };
    // Home's card read it once (as at every start).
    await tester.runAsync(() async {
      final here = (await r.weather.watchedPlaces()).first;
      await r.weather.viewFor(here);
    });
    // Now the core is held up (a weather update, map sizes): the screen must not wait for it.
    r.liveCore.busy = Completer<void>();
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r)));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'nothing to wait for: the forecast is on the phone');
    expect(find.textContaining('43 °F'), findsWidgets);
    // The page no longer prints each source's age (one line says when everything was updated); a reading's age is in its
    // detail, which the reading opens.
    await tester.tap(find.byKey(const ValueKey('weather-temperature')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('50 minutes old'), findsOneWidget, reason: 'the age as of now, not as of the last read');
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    r.liveCore.busy!.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.textContaining('43 °F'), findsWidgets);
    await r.dispose(tester);
  });

  testWidgets('Weather while "Where I am" waits for the position says so, and does not offer to turn weather on', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.weather.setRowOn(WeatherTurnOn.rows.first, true));
    r.here = null;
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r), onOpenSettings: () {}));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for your position.'), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-turn-on')), findsNothing, reason: 'weather is on');
    await r.dispose(tester);
  });

  test('saved places: the first look only remembers them; a place saved later is watched; unticking is kept', () async {
    final dir = Directory.systemTemp.createTempSync('seen-places');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = AppSettings(settingsDirOverride: dir);
    await s.init();
    s.noteSavedPlaces(['place:old']);
    expect(s.watchedPlaces, {'here'});
    s.noteSavedPlaces(['place:old', 'place:cabin']);
    expect(s.watchedPlaces, {'here', 'place:cabin'});
    s.setWatched('place:cabin', false);
    s.noteSavedPlaces(['place:old', 'place:cabin']);
    expect(s.watchedPlaces, {'here'});
    final again = AppSettings(settingsDirOverride: dir);
    await again.init();
    again.noteSavedPlaces(['place:old', 'place:cabin', 'place:lake']);
    expect(again.watchedPlaces, {'here', 'place:lake'}, reason: 'what was seen is kept in the settings file');
  });

  testWidgets('a place saved on the map shows up watched in Settings > Weather and alerts > Places', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(r.weather.placeChoices);
    r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9)];
    final w = await tester.runAsync(r.weather.watchedPlaces);
    expect(w!.map((p) => p.id), containsAll(['here', 'place:cabin']));
    expect(w.firstWhere((p) => p.id == 'place:cabin').kind, PlaceKind.saved);
    await r.dispose(tester);
  });

  testWidgets('Weather page: one watched place still shows its name; Update now downloads again even a fresh copy', (tester) async {
    final r = await SettingsRig.create(tester);
    await tester.runAsync(() => r.weather.setRowOn(kCurated.firstWhere((c) => c.title == 'Weather forecast'), true));
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r)));
    await tester.pumpAndSettle();
    // The place is named in the top card (it was a chip): the page says which place it is about, for a single place too.
    expect(find.descendant(of: find.byKey(const ValueKey('weather-place')), matching: find.text('Current location')), findsOneWidget);
    // (opening the screen already ran the update that was due, not forced: only the person's tap is looked at here)
    r.liveCore.fetches.clear();
    await tester.tap(find.text('Update now'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(r.liveCore.fetches, isNotEmpty);
    expect(r.liveCore.fetches.every((f) => f['force'] == true), isTrue, reason: "a person's Update now skips the refresh interval");
    await r.dispose(tester);
  });

  // Search as you type: the Choose a place sheet searches after a short pause, without Enter.
  const hilo = MapPlace(id: 'place:osm:n1', type: 'place', name: 'Hilo Town', kind: 'Town', address: 'Test County', lat: 19.7, lon: -155.1);
  const hiPlace = MapPlace(id: 'place:osm:n2', type: 'place', name: 'Hi Village', kind: 'Town', address: 'Other County', lat: 20.0, lon: -155.0);

  Future<SettingsRig> openSheet(WidgetTester tester, Future<List<MapPlace>> Function(String) search) async {
    final r = await SettingsRig.create(tester);
    r.here = null;
    r.settings.setWatched('here', false);
    r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.2, lon: -114.9, label: 'Near Stanley')];
    final t = WeatherTurnOn(weather: r.weather, location: r.location, searchPlaces: search, savePlace: (p) async {});
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: t));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-choose-place')));
    await tester.pumpAndSettle();
    return r;
  }

  testWidgets('place search: typing without Enter shows the results after the pause', (tester) async {
    final r = await openSheet(tester, (q) async => q == 'Hilo' ? [hilo] : []);
    await tester.enterText(find.byKey(const ValueKey('weather-place-search')), 'Hilo');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-found-place:osm:n1')), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('place search: an older answer arriving last never replaces the newest results', (tester) async {
    final hi = Completer<List<MapPlace>>();
    final r = await openSheet(tester, (q) => q == 'Hi' ? hi.future : Future.value([hilo]));
    final field = find.byKey(const ValueKey('weather-place-search'));
    await tester.enterText(field, 'Hi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(field, 'Hilo');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    hi.complete([hiPlace]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-found-place:osm:n1')), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-found-place:osm:n2')), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('place search: clearing the field shows the saved list again', (tester) async {
    final r = await openSheet(tester, (q) async => [hilo]);
    final field = find.byKey(const ValueKey('weather-place-search'));
    await tester.enterText(field, 'Hilo');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-found-place:osm:n1')), findsOneWidget);
    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-found-place:osm:n1')), findsNothing);
    expect(find.byKey(const ValueKey('weather-saved-place:cabin')), findsOneWidget);
    await r.dispose(tester);
  });
}

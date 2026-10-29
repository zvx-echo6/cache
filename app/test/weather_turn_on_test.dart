import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/settings/app_settings.dart';
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

  testWidgets('Weather, nothing on: "Turn on weather" switches on forecast, alerts and fires for Where I am, asks for the location and updates',
      (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.notAsked);
    await r.show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(r), onOpenSettings: () {}));
    await tester.pumpAndSettle();
    expect(find.text('Weather is off.'), findsOneWidget);
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
    expect(r.liveCore.fetches, isNotEmpty, reason: 'it updated');
    expect(find.text('Weather is off.'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('location refused: it offers a place instead; a saved place is watched and updated', (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.deniedForever);
    r.here = null;
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

  testWidgets('Home: the Weather card offers "Turn on weather" while weather is off', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    await r.show(tester, HomeScreen(layout: layout, weather: r.weather, turnOn: turnOn(r), onOpenAsk: () {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-turn-on')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-turn-on')));
    await tester.pumpAndSettle();
    if (find.byKey(const ValueKey('weather-location-continue')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('weather-location-continue')));
      await tester.pumpAndSettle();
    }
    expect(_three(r), _threeIds);
    expect(find.byKey(const ValueKey('weather-turn-on')), findsNothing, reason: 'weather is set up now');
    layout.dispose();
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
}

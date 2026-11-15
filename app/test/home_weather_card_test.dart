// Home's Weather and alerts card as a widget: what it shows when a card made earlier is shown later, how its lines are laid
// out, and its mark for alert data that is past its time. Every place is made up.

import 'dart:async';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/location/position_source.dart' show LocationPermissionState;
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/settings/app_settings.dart' show kWatchHere;
import 'package:cache/weather/weather_state.dart' show kWeatherHereOff;
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_screen_kit.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Widget _home(SettingsRig r, LayoutState layout, {bool turnOn = false}) => HomeScreen(
  layout: layout,
  weather: r.weather,
  turnOn: turnOn ? WeatherTurnOn(weather: r.weather, location: r.location) : null,
  onAsk: (_) {},
  onOpenSettings: () {},
  onOpenShortcut: (_) {},
);

Finder _inCard(Finder what) => find.descendant(of: find.byKey(const ValueKey('home-weather')), matching: what);

/// A no-break space: the high and the low of the conditions line are each one piece (homeConditionsLine), so the line reads
/// "Clear sky · High 52 °F, low 31 °F" and breaks only between its parts.
const _nb = '\u00A0';

/// Wednesday 9:00 PM at "Where I am": the forecast with its "Now", and alerts and fires checked with nothing in force (a
/// check speaks for six hours).
Future<void> _evening(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(21, 0);
  r.clock = updated;
  await useScreenSources(tester, r, kUsualSources);
  store(r, 'openmeteo-forecast', storedAnswer(updated, updated, [
    nowItem(updated, temperature: 38, feels: 33, wind: '6 mph NW, gusts 11 mph', conditions: 'clear sky'),
    ...sixteenDays(updated),
  ]));
  for (final id in kUsualSources.skip(1)) {
    store(r, id, {...storedAnswer(updated, updated, const []), 'valid_until': updated.add(const Duration(hours: 6)).toIso8601String()});
  }
}

void main() {
  // The app stays in memory overnight. Home's card kept the answer of 9 PM while the next one was awaited, and showed its
  // temperature as the temperature at 7 AM until the core answered.
  testWidgets('a card made last night is not shown as the weather this morning while the next answer is awaited', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    await _evening(tester, r);
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    expect(find.byKey(const ValueKey('home-temperature')), findsOneWidget);
    expect(find.text('38 °F'), findsOneWidget);
    expect(find.text('Clear sky · High${_nb}52$_nb°F, low${_nb}31$_nb°F'), findsOneWidget);
    expect(_inCard(find.byIcon(Icons.check_circle_outline)), findsOneWidget, reason: 'checked a moment ago, nothing in force: a tick');
    expect(find.byKey(const ValueKey('home-alerts-expired')), findsNothing);

    // Thursday 7:00 AM: Home is drawn again and asks the core, which has not answered yet.
    r.clock = DateTime(2026, 11, 12, 7, 0);
    r.liveCore.busy = Completer<void>();
    await r.show(tester, _home(r, layout));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-temperature')), findsNothing, reason: 'the 9 PM reading is not the temperature at 7 AM');
    expect(find.text('38 °F'), findsNothing);
    expect(find.text('Thu Nov 12 · Light rain · High${_nb}49$_nb°F, low${_nb}34$_nb°F'), findsOneWidget, reason: 'today\'s forecast under its own label');
    expect(find.text('Current location · 10 hours old'), findsOneWidget);
    // The check of alerts from last night no longer speaks for now: the Weather screen's mark for that, not a tick.
    expect(find.text('No alerts known, data expired'), findsOneWidget);
    expect(_inCard(find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
    expect(find.byKey(const ValueKey('home-alerts-expired')), findsOneWidget);
    expect(_inCard(find.byIcon(Icons.check_circle_outline)), findsNothing);

    r.liveCore.busy!.complete();
    await _settle(tester, 2);
    layout.dispose();
    await r.dispose(tester);
  });

  // At a phone's width the conditions with the day's high and low were cut off beside the temperature ("… low 31 …").
  testWidgets('the conditions with the high and low may take a second line', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    await _evening(tester, r);
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    final line = tester.widget<Text>(find.text('Clear sky · High${_nb}52$_nb°F, low${_nb}31$_nb°F'));
    expect(line.maxLines, 2);
    // The card shows the line homeConditionsLine makes: the same words, and a second line never starts inside the high or the
    // low (condition_case_test.dart lays the line out at every width).
    expect(line.data!.replaceAll(_nb, ' '), 'Clear sky · High 52 °F, low 31 °F');
    layout.dispose();
    await r.dispose(tester);
  });

  // Weather always works (owner, 2026-11-15). The card never says "Not set up yet" or "Weather is off" because no source is on (the
  // defaults come back); the one state where weather does not work is a location that is not watched.
  testWidgets('with no source on in the settings the defaults are on and the card is not off', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    await tester.runAsync(() async {
      r.settings.replaceLiveSourcesOn(const <String>{});
      await r.weather.sourcesChanged();
    });
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    expect(r.weather.enabledSources, isNotEmpty);
    expect(find.text(kWeatherHereOff), findsNothing);
    expect(find.text('Weather is off'), findsNothing);
    expect(find.text('Not set up yet'), findsNothing);
    expect(find.byKey(const ValueKey('weather-watch-here')), findsNothing);
    expect(find.byKey(const ValueKey('weather-off-turn-on')), findsNothing);
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('your location not watched and no other place: the card says weather is off, with Watch my location; a tap watches it', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    r.settings.setWatched(kWatchHere, false);
    expect(r.weather.nothingWatched, isTrue);
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    expect(_inCard(find.text(kWeatherHereOff)), findsOneWidget);
    expect(kWeatherHereOff, "Weather is off: your location isn't watched");
    expect(_inCard(find.byKey(const ValueKey('weather-watch-here'))), findsOneWidget);
    expect(_inCard(find.text('Watch my location')), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-off-turn-on')), findsNothing, reason: 'not the Turn on of Settings');

    await tester.tap(find.byKey(const ValueKey('weather-watch-here')));
    await _settle(tester);
    expect(r.settings.watchedPlaces, contains(kWatchHere));
    expect(r.weather.nothingWatched, isFalse);
    expect(find.text(kWeatherHereOff), findsNothing);
    expect(find.byKey(const ValueKey('weather-watch-here')), findsNothing);
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('another place is watched while your location is not: the card is not off', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43.1, lon: -114.2)];
    await tester.runAsync(() => r.weather.placeChoices());
    r.settings.setWatched('place:cabin', true);
    r.settings.setWatched(kWatchHere, false);
    await r.show(tester, _home(r, layout));
    await _settle(tester);
    expect(r.weather.nothingWatched, isFalse);
    expect(find.text(kWeatherHereOff), findsNothing);
    expect(find.byKey(const ValueKey('weather-watch-here')), findsNothing);
    layout.dispose();
    await r.dispose(tester);
  });

  // Home's card waits for a position (your location is watched and the phone has none). Without the location permission one button,
  // Use my location, asks for it; with the permission the fix is on its way and there is nothing to ask for.
  testWidgets('waiting for a position: Use my location shows only without the location permission', (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.notAsked);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    r.here = null;
    for (final lacking in [LocationPermissionState.notAsked, LocationPermissionState.denied]) {
      r.location.permission = lacking;
      await r.show(tester, _home(r, layout, turnOn: true));
      await _settle(tester);
      expect(r.weather.waitingForPosition, isTrue);
      expect(_inCard(find.text('Waiting for your position')), findsOneWidget);
      expect(_inCard(find.byKey(const ValueKey('weather-use-location'))), findsOneWidget, reason: '$lacking');
      expect(_inCard(find.text('Use my location')), findsOneWidget);
      expect(find.byKey(const ValueKey('weather-turn-on')), findsNothing, reason: 'the one button, not Turn on weather');
    }
    // The permission is given and the fix is not in yet: nothing to ask for.
    r.location.permission = LocationPermissionState.granted;
    await r.show(tester, _home(r, layout, turnOn: true));
    await _settle(tester);
    expect(_inCard(find.text('Waiting for your position')), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-use-location')), findsNothing);
    expect(find.byKey(const ValueKey('weather-turn-on')), findsNothing);
    // The position is known: no button either, whatever the permission says.
    r.location.permission = LocationPermissionState.notAsked;
    r.here = (lat: 42.54, lon: -113.79);
    await r.show(tester, _home(r, layout, turnOn: true));
    await _settle(tester);
    expect(find.byKey(const ValueKey('weather-use-location')), findsNothing);
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('Use my location asks for the permission; refused, the card stays as it was', (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.notAsked);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    r.here = null;
    r.position.grant = false;
    await r.show(tester, _home(r, layout, turnOn: true));
    await _settle(tester);
    expect(r.position.asked, 0);
    await tester.tap(find.byKey(const ValueKey('weather-use-location')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Use your location?'), findsOneWidget, reason: 'the usual reason first, the way Turn on weather asks');
    await tester.tap(find.byKey(const ValueKey('weather-location-continue')));
    await _settle(tester);
    expect(r.position.asked, 1, reason: 'the system was asked once, through the location service');
    expect(r.location.permission, LocationPermissionState.denied);
    expect(_inCard(find.text('Waiting for your position')), findsOneWidget, reason: 'as it was');
    expect(_inCard(find.byKey(const ValueKey('weather-use-location'))), findsOneWidget, reason: 'and it can be asked again');
    expect(find.byType(SnackBar), findsNothing, reason: 'no new words');
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('Use my location, permission given: the card goes on to the forecast as the position arrives', (tester) async {
    final r = await SettingsRig.create(tester, permission: LocationPermissionState.notAsked);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    r.here = null;
    // the phone's position reaches the weather part once the location service reads it
    r.position.onCurrent = () => r.here = (lat: 42.54, lon: -113.79);
    await r.show(tester, _home(r, layout, turnOn: true));
    await _settle(tester);
    expect(_inCard(find.text('Waiting for your position')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-use-location')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('weather-location-continue')));
    await _settle(tester, 10);
    expect(r.position.asked, 1);
    expect(r.location.permission, LocationPermissionState.granted);
    expect(r.location.fix, isNotNull);
    expect(r.weather.waitingForPosition, isFalse);
    expect(find.text('Waiting for your position'), findsNothing);
    expect(find.byKey(const ValueKey('weather-use-location')), findsNothing);
    layout.dispose();
    await r.dispose(tester);
  });
}

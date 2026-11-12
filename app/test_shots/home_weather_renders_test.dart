// Home's Weather and alerts card, drawn by the Home screen's own widgets for review of the weather it says is "now" (the
// reading rule it shares with the Weather screen, weather/place_summary.dart readingOf). At 390 x 844, light and dark:
//   fresh                      a reading taken 12 minutes ago
//   old-reading                last night's reading the next morning, from what the app kept, before the core answers
//   periods-with-temperatures  no "Now" (Open-Meteo's has ended), and NWS by point's periods, each with a temperature
//   periods-only               NWS by point alone: periods with temperatures and no other forecast
// Every place is made up.
// flutter test test_shots/home_weather_renders_test.dart --update-goldens  (pictures in test_shots/home-weather/)
// Not part of the test suite.

import 'dart:async';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/weather_screen_kit.dart';
import 'shot_kit.dart';

const _out = 'home-weather';

const Size _phone = Size(390, 844);

const List<CacheThemeId> _themes = [CacheThemeId.light, CacheThemeId.dark];

Future<void> _settle(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// Home as the app opens it, with the Weather and alerts card fed by the rig's weather.
Future<void> _show(WidgetTester tester, SettingsRig r, LayoutState layout, CacheThemeId theme) async {
  phone(tester, size: _phone, ratio: 3);
  await tester.pumpWidget(shotApp(
    HomeScreen(layout: layout, weather: r.weather, onOpenWeather: () {}, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}),
    theme: theme,
  ));
  await _settle(tester);
}

Future<LayoutState> _layout(WidgetTester tester, SettingsRig r) async {
  final layout = LayoutState(settingsDirOverride: r.dir);
  await tester.runAsync(layout.init);
  return layout;
}

/// One 12-hour period of the Weather Service's forecast by point, as the source lists it: its name, when it starts and the
/// temperature forecast for it.
Map<String, dynamic> _nwsPeriod(int number, String name, DateTime starts, int temperature, String wind, String summary) => {
  'address': 'live:nws-forecast-point/x/$number',
  'label': name,
  'time': starts.toIso8601String(),
  'fields': {'Temperature': '$temperature °F', 'Wind': wind, 'Chance of precipitation': '10%', 'Summary': summary},
};

/// Wednesday evening's forecast by point: tonight, Thursday and Thursday night.
List<Map<String, dynamic>> _nwsPeriods() => [
  _nwsPeriod(1, 'Tonight', DateTime(2026, 11, 11, 18), 31, '5 mph W', 'Mostly Clear'),
  _nwsPeriod(2, 'Thursday', DateTime(2026, 11, 12, 6), 49, '10 mph SW', 'Light Rain Likely'),
  _nwsPeriod(3, 'Thursday Night', DateTime(2026, 11, 12, 18), 34, '5 mph S', 'Mostly Cloudy'),
];

void main() {
  setUpAll(loadShotFonts);

  testWidgets('a fresh reading', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = await _layout(tester, r);
    // Wednesday 2:26 PM, updated at 2:14 PM
    await sceneQuietDay(tester, r);
    for (final theme in _themes) {
      await _show(tester, r, layout, theme);
      await snap(tester, _out, 'fresh-${theme.name}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('a reading older than the rule allows: last night\'s, the next morning, before the core answers', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = await _layout(tester, r);
    // Wednesday 9:00 PM: updated, and Home shows it once (so the app keeps it)
    final updated = wednesday(21, 0);
    r.clock = updated;
    await useScreenSources(tester, r, kUsualSources);
    store(r, 'openmeteo-forecast', storedAnswer(updated, updated, [
      nowItem(updated, temperature: 38, feels: 33, wind: '6 mph NW, gusts 11 mph', conditions: 'clear sky'),
      ...sixteenDays(updated),
    ]));
    for (final id in kUsualSources.skip(1)) {
      // a check of alerts and fires speaks for six hours
      store(r, id, {...storedAnswer(updated, updated, const []), 'valid_until': updated.add(const Duration(hours: 6)).toIso8601String()});
    }
    await tester.runAsync(() async {
      await r.weather.updateNow();
      await r.weather.homeCard();
    });
    // Thursday 7:00 AM: the app is opened, and the core has not answered yet
    r.clock = DateTime(2026, 11, 12, 7, 0);
    r.liveCore.busy = Completer<void>();
    for (final theme in _themes) {
      await _show(tester, r, layout, theme);
      await snap(tester, _out, 'old-reading-${theme.name}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    r.liveCore.busy!.complete();
    await _settle(tester, 2);
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('no "Now", and a forecast in periods with temperatures (NWS by point)', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = await _layout(tester, r);
    // Wednesday 6:30 PM. Open-Meteo was downloaded at 2:14 PM, so its "Now" has ended and the core leaves it out; the forecast by
    // point was downloaded at 6:10 PM.
    final shown = wednesday(18, 30), forecastAt = wednesday(14, 14), byPointAt = wednesday(18, 10);
    r.clock = shown;
    await useScreenSources(tester, r, [...kUsualSources, 'nws-forecast-point']);
    store(r, 'openmeteo-forecast', storedAnswer(shown, forecastAt, sixteenDays(forecastAt)));
    store(r, 'nws-forecast-point', storedAnswer(shown, byPointAt, _nwsPeriods()));
    for (final id in kUsualSources.skip(1)) {
      store(r, id, storedAnswer(shown, byPointAt, const []));
    }
    await tester.runAsync(() => r.weather.updateNow());
    for (final theme in _themes) {
      await _show(tester, r, layout, theme);
      await snap(tester, _out, 'periods-with-temperatures-${theme.name}');
    }

    // the forecast by point alone: no other forecast is switched on
    await tester.runAsync(() => r.weather.setSourceOn(r.weather.sourceById('openmeteo-forecast')!, false));
    for (final theme in _themes) {
      await _show(tester, r, layout, theme);
      await snap(tester, _out, 'periods-only-${theme.name}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    await r.dispose(tester);
  });
}

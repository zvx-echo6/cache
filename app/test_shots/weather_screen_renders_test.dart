// The redesigned Weather screen, drawn by its own widgets for the owner to approve (design: the Weather screen redesign note and
// its mock-up). At phone width (430 x 932) in the four themes: a quiet day, a serious day, no connection with stored data, and
// Places open. One Linux desktop window (1440 x 900) in Parchment. And, in Parchment, one picture of every other state and of
// every sheet, so each new word can be read where it shows. Every place, office and event is made up.
// flutter test test_shots/weather_screen_renders_test.dart --update-goldens  (pictures in test_shots/weather-screen/)
// Not part of the test suite.

import 'package:cache/desktop/desktop_shell.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/weather_screen_kit.dart';
import 'shot_kit.dart';

const _out = 'weather-screen';

const Size _phone = Size(430, 932);

/// A phone as tall as the whole page, to see what is under the first screen.
const Size _long = Size(430, 1760);

const Size _desktop = Size(1440, 900);

Future<void> _settle(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// The Weather screen as the app opens it: with the way to Settings, "Ask about this" and a place chooser.
Widget _screen(SettingsRig r) => WeatherScreen(
  weather: r.weather,
  turnOn: WeatherTurnOn(weather: r.weather, location: r.location),
  onOpenSettings: () {},
  onAsk: (_) {},
);

Future<void> _show(WidgetTester tester, SettingsRig r, CacheThemeId theme, {Size size = _phone}) async {
  phone(tester, size: size, ratio: 3);
  await tester.pumpWidget(shotApp(_screen(r), theme: theme));
  await _settle(tester);
}

/// Writes the picture; an error the screen raised while drawing is printed beside its name, and the picture is still written.
Future<void> _snap(WidgetTester tester, String name) async {
  final e = tester.takeException();
  // ignore: avoid_print
  print('WEATHER-SHOT $name');
  if (e != null) {
    // ignore: avoid_print
    print('WEATHER-EXC $name: ${e.toString().split('\n').where((l) => l.trim().isNotEmpty).take(3).join(' | ')}');
  }
  await snap(tester, _out, name);
}

Future<void> _tap(WidgetTester tester, Finder what) async {
  await tester.tap(what);
  await _settle(tester);
}

void main() {
  setUpAll(loadShotFonts);

  // ---- the four states, in the four themes -------------------------------------------------------------------------------

  testWidgets('a quiet day, four themes', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneQuietDay(tester, r);
    for (final theme in CacheThemeId.values) {
      await _show(tester, r, theme);
      await _snap(tester, 'quiet-${theme.name}');
    }
    await r.dispose(tester);
  });

  testWidgets('a serious day, four themes', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneSeriousDay(tester, r);
    for (final theme in CacheThemeId.values) {
      await _show(tester, r, theme);
      await _snap(tester, 'serious-${theme.name}');
    }
    await r.dispose(tester);
  });

  testWidgets('no connection, stored data, four themes', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneOfflineDays(tester, r);
    for (final theme in CacheThemeId.values) {
      await _show(tester, r, theme);
      await _snap(tester, 'offline-${theme.name}');
    }
    await r.dispose(tester);
  });

  testWidgets('Places open, four themes', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneSeveralPlaces(tester, r);
    for (final theme in CacheThemeId.values) {
      await _show(tester, r, theme);
      await _tap(tester, find.byKey(const ValueKey('weather-place')));
      await _snap(tester, 'places-${theme.name}');
    }
    await r.dispose(tester);
  });

  // ---- the Linux desktop window ------------------------------------------------------------------------------------------

  testWidgets('the serious day in a Linux desktop window, Parchment', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneSeriousDay(tester, r);
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    phone(tester, size: _desktop, ratio: 1);
    await tester.pumpWidget(shotApp(
      DesktopShell(module: ModuleId.weather, onHome: () {}, onModule: (_) {}, onModuleOptions: (c, m) {}, child: _screen(r)),
      theme: CacheThemeId.parchment,
      insets: EdgeInsets.zero,
      desktop: true,
    ));
    await _settle(tester, 12);
    await _snap(tester, 'desktop-serious-parchment');
    await tester.pumpWidget(const SizedBox());
    debugLinuxUi = null;
    await r.dispose(tester);
  });

  // ---- every other state and sheet, once, in Parchment -------------------------------------------------------------------

  const parchment = CacheThemeId.parchment;

  testWidgets('more: the serious day (the whole page, an event\'s detail, a source\'s items, the credits, a long title)', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneSeriousDay(tester, r);
    await _show(tester, r, parchment, size: _long);
    await _snap(tester, 'more-serious-whole-page');

    await _show(tester, r, parchment);
    await _tap(tester, find.text('Red Flag Warning'));
    await _snap(tester, 'more-event-detail');

    await _show(tester, r, parchment, size: _long);
    await _tap(tester, find.text('Earthquakes near the place (USGS)'));
    await _snap(tester, 'more-source-items');

    await _show(tester, r, parchment, size: _long);
    await _tap(tester, find.byKey(const ValueKey('weather-credits')));
    await _snap(tester, 'more-credits');

    // an emergency alert's name is its headline, which can be long: it wraps, and the rows after it are still on the first screen
    final updated = wednesday(15, 14), shown = wednesday(15, 26);
    store(r, 'ipaws-alerts-near', storedAnswer(shown, updated, [
      ipawsAlert(
        'ev2',
        'Evacuation order for everyone north of the river road, from the Tamber Flat bridge to the Alder Valley junction',
        'Evacuation Immediate',
        'extreme',
        updated,
        DateTime(2026, 11, 12, 6),
        by: 'Tamber County Office of Emergency Management',
        area: 'Tamber Flat; Alder Valley; the river road north of the bridge',
      ),
    ]));
    await _show(tester, r, parchment);
    await _snap(tester, 'more-long-title');
    await r.dispose(tester);
  });

  testWidgets('more: the quiet day (all sixteen days, the reading\'s detail)', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneQuietDay(tester, r);
    await _show(tester, r, parchment, size: _long);
    await _tap(tester, find.byKey(const ValueKey('weather-all-days')));
    await _snap(tester, 'more-all-days');

    await _show(tester, r, parchment);
    await _tap(tester, find.byKey(const ValueKey('weather-temperature')));
    await _snap(tester, 'more-reading-detail');
    await r.dispose(tester);
  });

  testWidgets('more: no connection for under three hours (the reading with the time it was taken)', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneQuietDay(tester, r);
    r.clock = wednesday(16, 0);
    await goOffline(tester, r);
    await _show(tester, r, parchment);
    await _snap(tester, 'more-offline-under-three-hours');
    await r.dispose(tester);
  });

  testWidgets('more: something serious at another place', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneSeveralPlaces(tester, r);
    await _show(tester, r, parchment);
    await _tap(tester, find.byKey(const ValueKey('weather-place')));
    await _tap(tester, find.byKey(const ValueKey('weather-place-place:cabin')));
    await _snap(tester, 'more-serious-elsewhere');
    await r.dispose(tester);
  });

  testWidgets('more: many fires and satellite detections', (tester) async {
    final r = await SettingsRig.create(tester);
    await sceneManyFires(tester, r);
    await _show(tester, r, parchment);
    await _snap(tester, 'more-many-fires');
    await _tap(tester, find.byKey(const ValueKey('weather-more-fires')));
    await _snap(tester, 'more-many-fires-the-rest');
    await r.dispose(tester);
  });

  testWidgets('more: a first run, a source without its key, a source that did not update', (tester) async {
    final r = await SettingsRig.create(tester);
    r.clock = wednesday(14, 14);
    await useScreenSources(tester, r, kUsualSources);
    await _show(tester, r, parchment);
    await _snap(tester, 'more-first-run');
    await r.dispose(tester);

    final k = await SettingsRig.create(tester);
    await sceneQuietDay(tester, k);
    await tester.runAsync(() => k.weather.setSourceOn(k.weather.sourceById('firms-viirs-near')!, true));
    await _show(tester, k, parchment);
    await _snap(tester, 'more-needs-a-key');
    await k.dispose(tester);

    final f = await SettingsRig.create(tester);
    await sceneQuietDay(tester, f);
    final updated = wednesday(14, 14), shown = wednesday(14, 26);
    // not since yesterday evening: its last check is also too old to speak for now
    store(f, 'ipaws-alerts-near', storedAnswer(shown, DateTime(2026, 11, 10, 18, 40), const [], expired: true, error: 'the service answered HTTP 503'));
    await _show(tester, f, parchment);
    await _snap(tester, 'more-one-source-not-updated');
    store(f, 'wfigs-incidents-near', storedAnswer(shown, updated, const [], error: 'the service answered HTTP 503'));
    await _show(tester, f, parchment);
    await _snap(tester, 'more-two-sources-not-updated');
    await f.dispose(tester);
  });

  testWidgets('more: no alert source on, no forecast source on, a forecast that has run out', (tester) async {
    final r = await SettingsRig.create(tester);
    final updated = wednesday(14, 14), shown = wednesday(14, 26);
    r.clock = updated;
    await useScreenSources(tester, r, ['openmeteo-forecast']);
    store(r, 'openmeteo-forecast', storedAnswer(shown, updated, [
      nowItem(updated, temperature: 45, feels: 41, wind: '8 mph NW, gusts 15 mph', conditions: 'partly cloudy'),
      ...sixteenDays(updated),
    ]));
    await updatedThenShownAt(tester, r, shown);
    await _show(tester, r, parchment);
    await _snap(tester, 'more-alerts-not-switched-on');

    await tester.runAsync(() async {
      await r.weather.setSourceOn(r.weather.sourceById('openmeteo-forecast')!, false);
      await r.weather.setSourcesOn([for (final id in kUsualSources.skip(1)) r.weather.sourceById(id)!], true);
    });
    for (final id in kUsualSources.skip(1)) {
      store(r, id, storedAnswer(shown, updated, const []));
    }
    await _show(tester, r, parchment);
    await _snap(tester, 'more-no-forecast-switched-on');

    await tester.runAsync(() => r.weather.setSourceOn(r.weather.sourceById('openmeteo-forecast')!, true));
    store(r, 'openmeteo-forecast', storedAnswer(shown, DateTime(2026, 10, 20, 9), const [], expired: true));
    await _show(tester, r, parchment);
    await _snap(tester, 'more-forecast-run-out');
    await r.dispose(tester);
  });

  testWidgets('more: the whole-page states (weather off, waiting for a position, no place watched)', (tester) async {
    final r = await SettingsRig.create(tester);
    await _show(tester, r, parchment);
    await _snap(tester, 'more-weather-off');

    await useScreenSources(tester, r, kUsualSources);
    r.here = null;
    await _show(tester, r, parchment);
    await _snap(tester, 'more-waiting-for-a-position');

    r.settings.setWatched('here', false);
    await _show(tester, r, parchment);
    await _snap(tester, 'more-no-place-watched');
    await r.dispose(tester);
  });
}

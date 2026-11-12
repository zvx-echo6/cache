import 'package:cache/chat/ask_about.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/alert_watch.dart' show AlertFocus;
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_screen_kit.dart';

// The Weather screen: what each state shows, the order of "Happening nearby", and Places. The data is the kit's made-up scenes;
// the order itself is also checked without widgets in place_summary_test.dart.

/// The rig on a phone-wide and very tall screen, so the whole page is built and every row can be found.
Future<SettingsRig> _rig(WidgetTester tester) async {
  final r = await SettingsRig.create(tester);
  tester.view.physicalSize = const Size(430, 3200);
  tester.view.devicePixelRatio = 1;
  return r;
}

/// Opens the screen anew (a key of its own each time, so a second look in one test starts from nothing shown).
Future<void> _open(WidgetTester tester, SettingsRig r, {List<AskAbout>? asked, List<String>? opened, WeatherTurnOn? turnOn}) async {
  await r.show(tester, WeatherScreen(key: UniqueKey(), weather: r.weather, turnOn: turnOn, onAsk: asked?.add, onOpenSettings: opened == null ? null : () => opened.add('settings')));
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

String? _textAt(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data;

Finder _in(String key, Finder what) => find.descendant(of: find.byKey(ValueKey(key)), matching: what);

final _dark = cacheTokens[CacheThemeId.dark]!;

void main() {
  testWidgets('a quiet day: the weather first, one calm line, then the days', (tester) async {
    final r = await _rig(tester);
    await sceneQuietDay(tester, r);
    await _open(tester, r);

    // the top card: the place, the reading at size, four facts of now and today, and how fresh it is
    expect(find.text('Where I am'), findsOneWidget);
    expect(_textAt(tester, 'weather-temperature'), '45 °F');
    expect(find.text('Feels like 41 °F'), findsOneWidget);
    for (final name in ['Daytime high', 'Low (early morning)', 'Wind', 'Chance of rain']) {
      expect(find.text(name), findsOneWidget, reason: 'the source\'s own name for the fact');
    }
    expect(find.text('8 mph NW, gusts 15 mph'), findsOneWidget);
    expect(_textAt(tester, 'weather-freshness'), 'Updated 12 min ago');
    expect(find.text('Update now'), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-as-of')), findsNothing, reason: 'a reading 12 minutes old needs no "as of"');
    expect(find.byKey(const ValueKey('weather-plain-line')), findsNothing, reason: 'nothing is wrong, so nothing is said');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Happening nearby: one calm line, naming what was checked and when
    expect(find.text('No alerts or fires nearby'), findsOneWidget);
    expect(find.text('Checked 12 min ago'), findsOneWidget);

    // the order of the page: the weather, what is happening, the forecast
    expect(_top(tester, 'Where I am'), lessThan(_top(tester, 'Happening nearby')));
    expect(_top(tester, 'Happening nearby'), lessThan(_top(tester, 'Forecast')));

    // the forecast: one line per day, today first, seven shown
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Wed Nov 11'), findsNothing, reason: 'today is called Today');
    expect(find.text('Thu Nov 12'), findsOneWidget);
    expect(find.text('Tue Nov 17'), findsOneWidget);
    expect(find.text('Wed Nov 18'), findsNothing);
    for (final column in ['Rain', 'High', 'Low']) {
      expect(find.text(column), findsOneWidget);
    }
    expect(find.textContaining('Stored through'), findsNothing, reason: 'said only while the forecast cannot be renewed');
    await tester.tap(find.text('All 16 days'));
    await tester.pumpAndSettle();
    expect(find.text('Thu Nov 26'), findsOneWidget);
    expect(find.text('All 16 days'), findsNothing);

    // the credits: one small line for everything shown, and the sheet behind it
    expect(find.textContaining('Weather data by Open-Meteo.com (CC BY 4.0)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-credits')));
    await tester.pumpAndSettle();
    expect(find.text('Weather credits'), findsOneWidget);
    expect(find.text('Weather forecast (Open-Meteo)'), findsOneWidget);
    expect(find.text('CC BY 4.0 (free API: non-commercial use)'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a day opens the detail sheet with all of its values, and so does the reading', (tester) async {
    final r = await _rig(tester);
    await sceneQuietDay(tester, r);
    await _open(tester, r);
    await tester.tap(find.text('Thu Nov 12'));
    await tester.pumpAndSettle();
    expect(find.text('Weather forecast (Open-Meteo) · Where I am · 12 minutes old'), findsOneWidget, reason: 'the source and the age live in the detail');
    for (final name in ['Daytime high', 'Low (early morning)', 'Chance of rain', 'Precipitation', 'Snow', 'Wind max', 'Conditions']) {
      expect(find.text(name), findsWidgets);
    }
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-temperature')));
    await tester.pumpAndSettle();
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('Feels like'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a serious day: serious alerts and fires first, then other alerts, then other fires, then one row per other source', (tester) async {
    final r = await _rig(tester);
    await sceneSeriousDay(tester, r);
    final asked = <AskAbout>[];
    await _open(tester, r, asked: asked);

    const order = [
      'Happening nearby',
      'Evacuation order for the Tamber Flat area', // extreme
      'Red Flag Warning', // severe
      'Tamber Flat fire', // within 10 miles
      'Wind Advisory', // an alert that is not serious
      'East Fork fire', // a fire that is not serious
      'Earthquakes near the place (USGS)', // a kind the app does not rank: one row for the source
      'Forecast',
    ];
    final tops = [for (final t in order) _top(tester, t)];
    expect(tops, [...tops]..sort(), reason: 'top to bottom: $order');
    expect(find.byKey(const ValueKey('weather-calm')), findsNothing);
    expect(find.byKey(const ValueKey('weather-more-fires')), findsNothing);

    // a row says how serious, until when and where, in the service's own words
    expect(find.text('Extreme · until Thu 6 AM'), findsOneWidget);
    expect(find.text('Issued by Tamber County Sheriff'), findsOneWidget);
    expect(find.text('Severe · until Thu 9 PM'), findsOneWidget);
    expect(find.text('Tamber County; Alder Valley'), findsOneWidget);
    expect(find.text('Moderate · until 11 PM'), findsOneWidget, reason: 'it ends today: the time alone');
    expect(find.text('6.2 mi NE · Size 1,240 acres · Contained 10%'), findsOneWidget, reason: 'a fire\'s distance comes first');
    expect(find.text('31 mi N · Size 266 acres · Contained 60%'), findsOneWidget);
    expect(find.text('2 listed · M 2.1 - 14 km N of Wrenhollow'), findsOneWidget);
    expect(find.text('Tamber Flat fire perimeter'), findsNothing, reason: 'a fire and its mapped edge are one row');

    // serious events are written in the emergency colour; the word or the distance is there too
    for (final serious in ['Evacuation order for the Tamber Flat area', 'Red Flag Warning', 'Tamber Flat fire']) {
      expect(tester.widget<Text>(find.text(serious)).style?.color, _dark.emergency, reason: serious);
    }
    for (final other in ['Wind Advisory', 'East Fork fire', 'Earthquakes near the place (USGS)']) {
      expect(tester.widget<Text>(find.text(other)).style?.color, _dark.text, reason: other);
    }

    // tapping an event opens the detail sheet, with the source, the place and the age, and "Ask about this"
    await tester.tap(find.text('Red Flag Warning'));
    await tester.pumpAndSettle();
    expect(find.text('Weather alerts (NWS, by point) · Where I am · 12 minutes old'), findsOneWidget);
    expect(find.text('Expires'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ask-about-this')));
    await tester.pumpAndSettle();
    expect(asked.single.label, 'Red Flag Warning');
    expect(asked.single.sourceId, 'nws-alerts-point');
    expect(asked.single.place, 'Where I am');

    // the row of a source opens its items
    await tester.tap(find.text('Earthquakes near the place (USGS)'));
    await tester.pumpAndSettle();
    expect(find.text('M 2.4 - 30 km E of Wrenhollow'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('many fires: the nearest three, then "N more fires"; detections that share a name are one row', (tester) async {
    final r = await _rig(tester);
    await sceneManyFires(tester, r);
    await _open(tester, r);

    const order = ['Satellite fire detection (high confidence)', 'Quill fire', 'East Fork fire', 'Osprey Bend fire', '2 more fires'];
    final tops = [for (final t in order) _top(tester, t)];
    expect(tops, [...tops]..sort(), reason: 'the serious detections, the nearest three fires, then the rest behind one row');
    expect(find.text('3 listed · nearest 8 mi NE'), findsOneWidget);
    expect(find.text('Wren fire'), findsNothing);
    expect(find.text('Harrow fire'), findsNothing);
    await tester.tap(find.text('2 more fires'));
    await tester.pumpAndSettle();
    expect(find.text('Wren fire'), findsOneWidget);
    expect(find.text('Harrow fire'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Satellite fire detection (high confidence)'));
    await tester.pumpAndSettle();
    expect(find.text('Satellite fire detection (high confidence)'), findsNWidgets(5), reason: 'the row, the sheet\'s title and its three detections');
    await r.dispose(tester);
  });

  testWidgets('no connection for two days: no temperature for now, the stored forecast, and a check too old to speak for now', (tester) async {
    final r = await _rig(tester);
    await sceneOfflineDays(tester, r);
    await _open(tester, r);

    // the reading has ended: the forecast for today stands in, and no temperature is shown as now
    expect(find.byKey(const ValueKey('weather-temperature')), findsNothing);
    expect(find.text('Forecast for today, Fri Nov 13'), findsOneWidget);
    expect(find.text('Light snow'), findsWidgets);
    for (final name in ['Daytime high', 'Low (early morning)', 'Chance of rain', 'Precipitation', 'Snow', 'Wind max']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(_textAt(tester, 'weather-freshness'), 'Updated 2 days ago · No connection since Wednesday');
    expect(find.byKey(const ValueKey('weather-plain-line')), findsNothing, reason: 'without a connection the top card says why');

    // the last check cannot speak for now: no calm line, and what was known is dated
    expect(find.byKey(const ValueKey('weather-calm')), findsNothing);
    expect(find.text('Last checked 2 days ago. Needs a connection for anything newer.'), findsOneWidget);
    expect(find.text('East Fork fire'), findsOneWidget);
    expect(find.text('As of Wed 2:14 PM'), findsOneWidget);

    // the days that remain, and how far they run
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Thu Nov 12'), findsNothing, reason: 'a day that has passed');
    expect(find.text('Stored through Thu Nov 26'), findsOneWidget);
    expect(find.text('All 14 days'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('no connection for under three hours: the reading with the time it was taken, and the calm line with its age', (tester) async {
    final r = await _rig(tester);
    await sceneQuietDay(tester, r);
    r.clock = wednesday(16, 0);
    await goOffline(tester, r);
    await _open(tester, r);
    expect(_textAt(tester, 'weather-temperature'), '45 °F');
    expect(_textAt(tester, 'weather-as-of'), 'As of 2:14 PM');
    expect(_textAt(tester, 'weather-freshness'), 'Updated 1 hour ago · No connection since today');
    expect(find.text('No alerts or fires nearby'), findsOneWidget);
    expect(find.text('Checked 1 hour ago'), findsOneWidget);
    expect(find.text('Stored through Thu Nov 26'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a first run with nothing downloaded says what is not known', (tester) async {
    final r = await _rig(tester);
    await useScreenSources(tester, r, kUsualSources);
    await _open(tester, r);
    expect(find.text('Where I am'), findsOneWidget);
    expect(find.text('No forecast yet'), findsOneWidget);
    expect(_textAt(tester, 'weather-freshness'), 'Not updated yet');
    expect(find.text('Update now'), findsOneWidget);
    expect(find.text('Not checked yet'), findsOneWidget);
    expect(find.text('No alerts or fires nearby'), findsNothing, reason: 'nothing was checked');
    expect(find.text('Forecast'), findsNothing);
    expect(find.byKey(const ValueKey('weather-temperature')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the core answered: nothing is downloaded');
    expect(find.byKey(const ValueKey('weather-plain-line')), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('a source that is on without its key: one plain line names it and leads to Settings', (tester) async {
    final r = await _rig(tester);
    await sceneQuietDay(tester, r);
    await tester.runAsync(() => r.weather.setSourceOn(r.weather.sourceById('firms-viirs-near')!, true));
    final opened = <String>[];
    await _open(tester, r, opened: opened);
    expect(_in('weather-plain-line', find.text('Satellite fire detections near the place (NASA FIRMS) needs a key')), findsOneWidget);
    expect(find.text('No alerts or fires nearby'), findsOneWidget, reason: 'the sources that were checked still speak');
    await tester.tap(find.byKey(const ValueKey('weather-plain-line')));
    await tester.pump();
    expect(opened, ['settings']);
    await r.dispose(tester);
  });

  testWidgets('a source that did not update at the last try is named, with since when; several are counted and named', (tester) async {
    final r = await _rig(tester);
    await sceneQuietDay(tester, r);
    final updated = wednesday(14, 14), shown = wednesday(14, 26);
    store(r, 'nws-alerts-point', storedAnswer(shown, updated, const [], error: 'the service answered HTTP 503'));
    await _open(tester, r);
    expect(_in('weather-plain-line', find.text('Weather alerts (NWS, by point) has not updated since 2:14 PM')), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsNothing, reason: 'why is in Settings, not here');

    store(r, 'ipaws-alerts-near', storedAnswer(shown, updated, const [], error: 'the service answered HTTP 503'));
    await _open(tester, r);
    expect(_in('weather-plain-line', find.text('2 sources have not updated: Weather alerts (NWS, by point), Emergency alerts')), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('no alert or fire source on: the plain line says so; no forecast source on: the top card says so', (tester) async {
    final r = await _rig(tester);
    r.clock = wednesday(14, 14);
    await useScreenSources(tester, r, ['openmeteo-forecast']);
    store(r, 'openmeteo-forecast', storedAnswer(wednesday(14, 26), wednesday(14, 14), sixteenDays(wednesday(14, 14))));
    await updatedThenShownAt(tester, r, wednesday(14, 26));
    final opened = <String>[];
    await _open(tester, r, opened: opened);
    expect(_in('weather-plain-line', find.text('Alerts and fires are not switched on')), findsOneWidget);
    expect(find.text('Happening nearby'), findsNothing, reason: 'nothing that gives events is on');
    expect(find.text('Forecast'), findsOneWidget);

    await tester.runAsync(() async {
      await r.weather.setSourceOn(r.weather.sourceById('openmeteo-forecast')!, false);
      await r.weather.setSourceOn(r.weather.sourceById('nws-alerts-point')!, true);
    });
    store(r, 'nws-alerts-point', storedAnswer(wednesday(14, 26), wednesday(14, 14), const []));
    await _open(tester, r, opened: opened);
    expect(find.text('No forecast is switched on'), findsOneWidget);
    expect(find.text('Forecast'), findsNothing);
    expect(find.text('No alerts nearby'), findsOneWidget, reason: 'no fire source is on: the line speaks for alerts alone');
    await tester.tap(find.text('No forecast is switched on'));
    await tester.pump();
    expect(opened, ['settings']);
    await r.dispose(tester);
  });

  testWidgets('a forecast whose every day has passed, and a forecast with nothing in it, say so', (tester) async {
    final r = await _rig(tester);
    r.clock = wednesday(14, 14);
    await useScreenSources(tester, r, ['openmeteo-forecast', 'nws-alerts-point']);
    store(r, 'nws-alerts-point', storedAnswer(wednesday(14, 14), wednesday(14, 14), const []));
    store(r, 'openmeteo-forecast', storedAnswer(wednesday(14, 14), DateTime(2026, 10, 1, 9), const [], expired: true));
    await _open(tester, r);
    expect(find.text('Forecast expired, needs a connection'), findsOneWidget);
    expect(find.text('Every day of this forecast has passed.'), findsOneWidget);

    store(r, 'openmeteo-forecast', storedAnswer(wednesday(14, 14), wednesday(14, 2), const []));
    await _open(tester, r);
    expect(find.text('No forecast.'), findsOneWidget);
    expect(find.text('Forecast'), findsNothing);
    await r.dispose(tester);
  });

  testWidgets('nothing switched on: the whole-page state, with the way to Settings', (tester) async {
    final r = await _rig(tester);
    final opened = <String>[];
    await _open(tester, r, opened: opened);
    expect(find.text('Nothing is switched on yet.'), findsOneWidget);
    expect(find.text('Nothing switched on yet'), findsOneWidget, reason: 'the status line');
    await tester.tap(find.text('Open Weather and alerts settings'));
    await tester.pump();
    expect(opened, ['settings']);
    await r.dispose(tester);
  });

  testWidgets('Places: every watched place with its temperature and the worst thing happening there', (tester) async {
    final r = await _rig(tester);
    await sceneSeveralPlaces(tester, r);
    await _open(tester, r);
    expect(find.byKey(const ValueKey('weather-serious-elsewhere')), findsNothing, reason: 'the serious events are at the place on screen');

    await tester.tap(find.byKey(const ValueKey('weather-place')));
    await tester.pumpAndSettle();
    expect(find.text('Places'), findsOneWidget);
    // where the phone is: the most serious event first, and how many more are ranked
    final worst = _in('weather-place-here', find.text('Evacuation order for the Tamber Flat area · +4 more'));
    expect(worst, findsOneWidget);
    expect(tester.widget<Text>(worst).style?.color, _dark.emergency);
    expect(_in('weather-place-here', find.text('58 °F')), findsOneWidget);
    expect(_in('weather-place-here', find.byIcon(Icons.check)), findsOneWidget, reason: 'the place on screen is marked');
    // an alert that is not serious
    final advisory = _in('weather-place-place:cabin', find.text('Wind Advisory'));
    expect(advisory, findsOneWidget);
    expect(tester.widget<Text>(advisory).style?.color, _dark.secondary);
    expect(_in('weather-place-place:cabin', find.text('49 °F')), findsOneWidget);
    expect(_in('weather-place-place:cabin', find.byIcon(Icons.check)), findsNothing);
    // nothing in force
    expect(_in('weather-place-place:trailhead', find.text('No alerts or fires nearby')), findsOneWidget);
    expect(_in('weather-place-place:trailhead', find.text('31 °F')), findsOneWidget);
    // nothing stored: it says so, and shows no temperature
    expect(_in('weather-place-place:lake-house', find.text('Nothing downloaded yet')), findsOneWidget);
    expect(_in('weather-place-place:lake-house', find.textContaining('°F')), findsNothing);
    expect(find.byKey(const ValueKey('weather-add-place')), findsNothing, reason: 'offered only where a place can be chosen');

    // tapping a place shows it; something serious elsewhere is one line under its name, and leads there
    await tester.tap(find.byKey(const ValueKey('weather-place-place:cabin')));
    await tester.pumpAndSettle();
    expect(find.text('Places'), findsNothing);
    expect(_in('weather-place', find.text('Cabin')), findsOneWidget);
    expect(_textAt(tester, 'weather-temperature'), '49 °F');
    expect(find.text('Wind Advisory'), findsOneWidget);
    expect(_in('weather-serious-elsewhere', find.text('Serious at Where I am: Evacuation order for the Tamber Flat area')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-serious-elsewhere')));
    await tester.pumpAndSettle();
    expect(_in('weather-place', find.text('Where I am')), findsOneWidget);
    expect(_textAt(tester, 'weather-temperature'), '58 °F');
    await r.dispose(tester);
  });

  testWidgets('Places, "Add a place": the place is watched and no source is switched on for it', (tester) async {
    final r = await _rig(tester);
    r.clock = wednesday(14, 14);
    await useScreenSources(tester, r, ['openmeteo-forecast']);
    store(r, 'openmeteo-forecast', storedAnswer(wednesday(14, 14), wednesday(14, 14), sixteenDays(wednesday(14, 14))));
    r.liveCore.saved = const [SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43.1, lon: -114.2)];
    r.settings.setWatched('place:cabin', false);
    final turnOn = WeatherTurnOn(weather: r.weather, location: r.location);
    await _open(tester, r, turnOn: turnOn);
    await tester.tap(find.byKey(const ValueKey('weather-place')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-place-place:cabin')), findsNothing, reason: 'not watched yet');
    await tester.tap(find.byKey(const ValueKey('weather-add-place')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a place'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weather-saved-place:cabin')));
    await tester.pumpAndSettle();
    expect(r.settings.watchedPlaces, contains('place:cabin'));
    expect({for (final c in r.weather.enabledSources) c.id}, {'openmeteo-forecast'}, reason: 'the sources stay as the person has them');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-place')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-place-place:cabin')), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('"Where I am" moved: once its sources are fetched for the new position, the page shows them', (tester) async {
    final r = await _rig(tester);
    await sceneQuietDay(tester, r);
    await _open(tester, r);
    expect(_textAt(tester, 'weather-temperature'), '45 °F');
    // the phone moves about six kilometres: its data is kept under another key (what a fetch for it brings is put in the fake
    // core here; the page must not read it before the app has fetched)
    final updated = wednesday(14, 14), shown = wednesday(14, 26);
    final there = [
      nowItem(shown, temperature: 51, feels: 48, wind: '6 mph N, gusts 9 mph', conditions: 'clear sky'),
      ...sixteenDays(updated),
    ];
    store(r, 'openmeteo-forecast', storedAnswer(shown, shown, there), placeKey: 'at:42.60,-113.79');
    r.here = (lat: 42.60, lon: -113.79);
    r.weather.positionChanged();
    await tester.pumpAndSettle();
    expect(_textAt(tester, 'weather-temperature'), '45 °F', reason: 'until the fetch for the new position, what was shown stays');
    // the position has settled: the app fetches for it by itself, and the page reads the place again
    await tester.pump(const Duration(seconds: 46));
    await tester.pumpAndSettle();
    expect(r.weather.hereFetchedAt, isNotNull);
    expect(_textAt(tester, 'weather-temperature'), '51 °F');
    await r.dispose(tester);
  });

  testWidgets('a tapped alert pop-up opens its item; one that has ended says so', (tester) async {
    final r = await _rig(tester);
    await sceneSeriousDay(tester, r);
    await _open(tester, r);
    r.weather.focus.value = const AlertFocus(placeId: 'here', address: 'live:nws-alerts-point/x/urn:oid:2.49.0.1.840.0.wa1.001.1');
    await tester.pumpAndSettle();
    expect(find.text('Weather alerts (NWS, by point) · Where I am · 12 minutes old'), findsOneWidget);
    expect(find.text('Wind Advisory'), findsNWidgets(2), reason: 'the row and the sheet');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    r.weather.focus.value = const AlertFocus(placeId: 'here', address: 'live:nws-alerts-point/x/gone');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('That alert has ended or is no longer in the data.'), findsOneWidget);
    await r.dispose(tester);
  });
}

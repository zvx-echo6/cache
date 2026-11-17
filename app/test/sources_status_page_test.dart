import 'dart:async';

import 'package:cache/settings/data_policy.dart' show ConnectionKind;
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/settings/source_page.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/screens/settings/widgets.dart' show RowButton;
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/source_health.dart' show SourceFailure;
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_fakes.dart';
import 'support/weather_screen_kit.dart';

// Settings > Weather and alerts says what each source is doing: a summary, then groups (Needs attention, Working, Off).

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const _wfigs = 'wfigs-incidents-near';
const _firms = 'firms-viirs-near';
const _usgs = 'usgs-quakes-near';

/// Every featured source on and working (the keys saved), nothing failing.
Future<void> _calm(WidgetTester tester, SettingsRig r) async {
  await tester.runAsync(() async {
    final w = r.weather;
    r.liveCore.fetchErrors.clear();
    r.liveCore.stored.clear();
    await r.webSearch.saveKey('k');
    await w.saveKey(w.sourceById('idaho511-events')!, 'k');
    await w.saveKey(w.sourceById(_firms)!, 'k');
    await w.setSourcesOn([for (final c in w.sources) if (c.featured && !w.isOwn(c)) c], true);
    await w.updateNow(force: true);
  });
}

/// Two need attention (Firms has no key; Wildfires does not answer and its saved copy is out of date) and one is off (Earthquakes).
Future<void> _mixed(WidgetTester tester, SettingsRig r) async {
  await tester.runAsync(() async {
    final w = r.weather;
    await r.webSearch.saveKey('k');
    await w.saveKey(w.sourceById('idaho511-events')!, 'k');
    await w.setSourcesOn([for (final c in w.sources) if (c.featured && !w.isOwn(c) && c.id != _usgs) c], true);
    await w.setSourceOn(w.sourceById(_usgs)!, false);
    await w.updateNow(force: true);
    r.clock = r.clock.add(const Duration(hours: 3));
    r.liveCore.stored[_wfigs] = {'age': '3 hours old', 'age_seconds': 10800, 'fetched_at': '2026-10-26T09:00:00-06:00', 'expired': true};
    r.liveCore.fetchErrors[_wfigs] = const CacheSearchException('fetch_failed', 'Io: timed out reading response');
    await w.updateNow(force: true);
  });
}

/// The colour a status sentence is drawn in.
Color? _colourOf(WidgetTester tester, String sentence) {
  final t = tester.widget<Text>(find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == sentence));
  return (t.textSpan! as TextSpan).children!.whereType<TextSpan>().first.style?.color;
}

double _top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

void main() {
  group('Weather and alerts: what each source is doing', () {
    testWidgets('mixed: the summary, the groups in order, and the right button on each problem', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('2 need attention · 1 off'), findsOneWidget);
      expect(find.text('Last checked just now'), findsOneWidget);
      // a group's label is drawn in capitals
      expect(_top(tester, 'NEEDS ATTENTION'), lessThan(_top(tester, 'WORKING')));
      expect(_top(tester, 'WORKING'), lessThan(_top(tester, 'OFF')));
      expect(_top(tester, 'OFF'), lessThan(_top(tester, 'More sources')));
      expect(find.text('NASA FIRMS needs a free key.'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-key-$_firms')), findsOneWidget);
      expect(find.text('Add key'), findsOneWidget);
      expect(find.text("NIFC WFIGS didn't answer. Showing what Cache saved 3 hours ago."), findsOneWidget);
      expect(find.byKey(const ValueKey('try-again-$_wfigs')), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Replace key'), findsNothing);
      expect(find.textContaining('HTTP'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('calm: "All N sources working" and no group headers', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      final n = r.weather.enabledSources.length + 1; // and Web search
      expect(find.text('All $n sources working'), findsOneWidget);
      for (final h in ['NEEDS ATTENTION', 'WORKING', 'OFF']) {
        expect(find.text(h), findsNothing, reason: h);
      }
      expect(find.text('Add key'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('no connection: one notice, and the rows do not show a network error', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await tester.runAsync(() async {
        r.probe.change(ConnectionKind.none);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('No connection. Showing what was saved.'), findsOneWidget);
      expect(find.text('Not answering'), findsNothing);
      expect(find.text('Try again'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('Add key opens the key sheet', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-key-$_firms')));
      await tester.pumpAndSettle();
      expect(find.text('Get a key from NASA FIRMS'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('the Settings row says how many need attention, or that all work', (tester) async {
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await tester.pump();
      expect(find.text('2 need attention'), findsOneWidget);
      await _calm(tester, r);
      await tester.pump();
      expect(find.text('All ${r.weather.enabledSources.length + 1} working'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a source that is on is listed and counted whether or not it is featured; one that is off stays under More sources', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('2 need attention · 1 off'), findsOneWidget);
      expect(find.byKey(const ValueKey('source-swpc-kp')), findsNothing, reason: 'off, not featured: under More sources');
      expect(find.text('More sources'), findsOneWidget);
      await tester.runAsync(() async {
        await r.weather.setSourceOn(r.weather.sourceById('swpc-kp')!, true);
        r.liveCore.stored['swpc-kp'] = {'age': '3 hours old', 'age_seconds': 10800, 'fetched_at': '2026-10-26T09:00:00-06:00', 'expired': true};
        r.liveCore.fetchErrors['swpc-kp'] = const CacheSearchException('fetch_failed', 'HTTP 500');
        await r.weather.updateNow(force: true);
      });
      await tester.pumpAndSettle();
      expect(find.text('3 need attention · 1 off'), findsOneWidget);
      expect(find.byKey(const ValueKey('source-swpc-kp')), findsOneWidget, reason: 'on, not featured: listed');
      expect(find.byKey(const ValueKey('try-again-swpc-kp')), findsOneWidget);
      expect(find.textContaining('HTTP'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('a failed download says nothing of HTTP on the page, the source page or the Weather screen', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await sceneQuietDay(tester, r);
      await tester.runAsync(() async {
        await r.weather.setSourceOn(r.weather.sourceById(_usgs)!, true);
        r.liveCore.fetchErrors[_usgs] = const CacheSearchException('fetch_failed', 'HTTP 500');
        await r.weather.updateNow(force: true);
      });
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP'), findsNothing);
      expect(find.textContaining('answered'), findsNothing);
      await r.show(tester, SourcePage(deps: r.deps, sourceId: _usgs));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP'), findsNothing);
      await r.show(tester, WeatherScreen(key: UniqueKey(), weather: r.weather));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP'), findsNothing);
      expect(find.textContaining('answered HTTP'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('the Weather screen\'s source line opens this page', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await sceneQuietDay(tester, r);
      await tester.runAsync(() => r.weather.setSourceOn(r.weather.sourceById(_firms)!, true));
      await r.show(
        tester,
        Builder(
          builder: (context) => WeatherScreen(
            weather: r.weather,
            onOpenSettings: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WeatherPage(deps: r.deps))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('weather-plain-line')));
      await tester.pumpAndSettle();
      expect(find.text('NEEDS ATTENTION'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-key-$_firms')), findsOneWidget);
      await r.dispose(tester);
    });
  });

  group('Try again on one source', () {
    /// Lets the (fake) core and the files answer: real time, then a frame.
    Future<void> settleReal(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }

    testWidgets('fetches just that source, not every source', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      r.liveCore.fetches.clear();
      r.liveCore.fetchErrors.remove(_wfigs);
      await tester.tap(find.byKey(const ValueKey('try-again-$_wfigs')));
      await settleReal(tester);
      await tester.pumpAndSettle();
      expect(r.liveCore.fetches, isNotEmpty);
      expect({for (final f in r.liveCore.fetches) f['source']}, {_wfigs});
      await r.dispose(tester);
    });

    testWidgets('that row says Updating (a spinner) while it runs and the others stay as they are; then it shows its result', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      r.liveCore.fetchErrors.remove(_wfigs);
      r.liveCore.fetchGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('try-again-$_wfigs')));
      await settleReal(tester);
      final row = find.byKey(const ValueKey('source-$_wfigs'));
      expect(find.descendant(of: row, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Updating')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('source-openmeteo-forecast')), matching: find.byType(Switch)), findsOneWidget, reason: 'the others are not updating');
      expect(find.byKey(const ValueKey('try-again-$_wfigs')), findsNothing);
      r.liveCore.fetchGate!.complete();
      await settleReal(tester);
      await tester.pumpAndSettle();
      expect(find.descendant(of: row, matching: find.byType(CircularProgressIndicator)), findsNothing);
      expect(find.descendant(of: row, matching: find.textContaining('Working')), findsOneWidget);
      expect(find.text('1 need attention · 1 off'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a source that fails again goes back to Not answering', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('try-again-$_wfigs')));
      await settleReal(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('try-again-$_wfigs')), findsOneWidget);
      expect(find.text('2 need attention · 1 off'), findsOneWidget);
      await r.dispose(tester);
    });
  });

  group('Limit reached is quiet', () {
    testWidgets('a source at its limit: not counted, listed under Working, no button, not in the warning colour', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _mixed(tester, r);
      await tester.runAsync(() async {
        r.liveCore.fetchErrors[_wfigs] = const CacheSearchException('fetch_failed', 'HTTP 429 (rate limited; gave up after retrying)');
        await r.weather.updateNow(force: true);
      });
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      const sentence = 'NIFC WFIGS says it has reached its limit. Cache tries again later.';
      expect(find.text('1 need attention · 1 off'), findsOneWidget, reason: 'only Firms (no key) is counted');
      expect(find.text(sentence), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('source-$_wfigs')), matching: find.byType(RowButton)), findsNothing);
      final row = tester.getTopLeft(find.byKey(const ValueKey('source-$_wfigs'))).dy;
      expect(row, greaterThan(_top(tester, 'WORKING')));
      expect(row, lessThan(_top(tester, 'OFF')));
      final k = tester.element(find.byKey(const ValueKey('source-$_wfigs'))).t;
      expect(_colourOf(tester, sentence), isNot(k.warning));
      expect(_colourOf(tester, 'Limit reached'), isNot(k.warning));
      await r.dispose(tester);
    });
  });

  group('Web search in the same list', () {
    const row = ValueKey('source-web-search');
    const rejected = '{"ok":false,"error":{"type":"key_missing","detail":"web search key rejected"}}';
    const limit = '{"ok":false,"error":{"type":"fetch_failed","detail":"HTTP 429 (rate limited)"}}';
    const results = '[1] Cache (web, fetched now) - a result';

    testWidgets('no key and switched off: Off, with its switch; the switch opens the Kagi key sheet', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      await tester.runAsync(r.webSearch.removeKey);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.byKey(row), findsOneWidget);
      expect(find.text('Web search'), findsOneWidget);
      expect(_top(tester, 'OFF'), lessThan(tester.getTopLeft(find.byKey(row)).dy));
      expect(find.text('${r.weather.enabledSources.length} need attention'), findsNothing);
      await tester.tap(find.descendant(of: find.byKey(row), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(find.text('Get a key from Kagi'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a key and no search yet, or a search that worked: Working', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(row), matching: find.textContaining('Working')), findsOneWidget);
      r.webSearch.noteSearch(results);
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(row), matching: find.textContaining('Working')), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('the last search was refused (a rejected key): Key not accepted, counted, with Replace key', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      r.webSearch.noteSearch(rejected);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('1 need attention'), findsOneWidget);
      expect(find.text('Kagi no longer accepts the saved key.'), findsOneWidget);
      expect(_colourOf(tester, 'Kagi no longer accepts the saved key.'), tester.element(find.byKey(row)).t.warning);
      expect(_top(tester, 'NEEDS ATTENTION'), lessThan(tester.getTopLeft(find.byKey(row)).dy));
      await tester.tap(find.byKey(const ValueKey('replace-key-web-search')));
      await tester.pumpAndSettle();
      expect(find.text('Get a key from Kagi'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('the last search hit its limit: Limit reached, not counted, no button; a later good search clears it', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      r.webSearch.noteSearch(limit);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Kagi says it has reached its limit. Cache tries again later.'), findsOneWidget);
      final k = tester.element(find.byKey(row)).t;
      expect(_colourOf(tester, 'Kagi says it has reached its limit. Cache tries again later.'), isNot(k.warning), reason: 'quiet, not a warning');
      expect(find.text('NEEDS ATTENTION'), findsNothing);
      expect(find.byKey(const ValueKey('replace-key-web-search')), findsNothing);
      r.webSearch.noteSearch(results);
      await tester.pumpAndSettle();
      expect(find.text('Kagi says it has reached its limit. Cache tries again later.'), findsNothing);
      await r.dispose(tester);
    });

    testWidgets('switched on with no key (a synced setting): Needs a key, with Add key', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      await tester.runAsync(r.webSearch.removeKey);
      r.settings.setWebSearchOn(true);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('Kagi needs a key.'), findsOneWidget, reason: 'a paid service, so not "free"');
      expect(find.byKey(const ValueKey('add-key-web-search')), findsOneWidget);
      expect(find.text('1 need attention'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('a new key, or removing it, forgets the last search', (tester) async {
      final r = await SettingsRig.create(tester);
      await tester.runAsync(() => r.webSearch.saveKey('k'));
      r.webSearch.noteSearch(rejected);
      expect(r.webSearch.lastFailure, SourceFailure.keyRejected);
      await tester.runAsync(() => r.webSearch.saveKey('k2'));
      expect(r.webSearch.lastFailure, SourceFailure.none);
      await r.dispose(tester);
    });
  });

  group('Your own sources in the same list', () {
    const id = 'my-gauge';

    Future<void> addOwn(WidgetTester tester, SettingsRig r, {bool on = true}) async {
      await tester.runAsync(() async {
        await r.weather.replaceOwnSources([
          {'entry': entry(id, 'hydrology', 'My gauge', provider: 'Me')..['description'] = 'Water level in my creek', 'definition': miniDefinition(id, title: 'My gauge', provider: 'Me')},
        ]);
        if (on) await r.weather.setSourceOn(r.weather.sourceById(id)!, true);
        await r.weather.updateNow(force: true);
      });
    }

    testWidgets('one that is on is listed with the same row as the others, and counted', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      final before = r.weather.enabledSources.length + 1;
      await addOwn(tester, r);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.text('All ${before + 1} sources working'), findsOneWidget);
      final row = find.byKey(const ValueKey('source-$id'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('Working · updated')), findsOneWidget);
      expect(find.textContaining('Your source'), findsNothing, reason: 'the old row line is gone');
      await r.dispose(tester);
    });

    testWidgets('one that is off is not in the list; one that does not answer needs attention with Try again', (tester) async {
      tall(tester);
      final r = await SettingsRig.create(tester);
      await _calm(tester, r);
      await addOwn(tester, r, on: false);
      await r.show(tester, WeatherPage(deps: r.deps));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('source-$id')), findsNothing, reason: 'off and not featured: under More sources');
      await tester.runAsync(() async {
        await r.weather.setSourceOn(r.weather.sourceById(id)!, true);
        await r.weather.updateNow(force: true);
        r.clock = r.clock.add(const Duration(hours: 3));
        r.liveCore.stored[id] = {'age': '3 hours old', 'age_seconds': 10800, 'fetched_at': '2026-10-26T09:00:00-06:00', 'expired': true};
        r.liveCore.fetchErrors[id] = const CacheSearchException('fetch_failed', 'Io: timed out reading response');
        await r.weather.updateNow(force: true);
      });
      await tester.pumpAndSettle();
      expect(find.text('1 need attention'), findsOneWidget);
      expect(find.byKey(const ValueKey('try-again-$id')), findsOneWidget);
      expect(find.text("Me didn't answer. Showing what Cache saved 3 hours ago."), findsOneWidget);
      await r.dispose(tester);
    });
  });
}

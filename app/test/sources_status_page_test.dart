import 'package:cache/settings/data_policy.dart' show ConnectionKind;
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
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
      expect(_top(tester, 'Needs attention'), lessThan(_top(tester, 'Working')));
      expect(_top(tester, 'Working'), lessThan(_top(tester, 'Off')));
      expect(_top(tester, 'Off'), lessThan(_top(tester, 'More sources')));
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
      final n = r.weather.enabledSources.length;
      expect(find.text('All $n sources working'), findsOneWidget);
      for (final h in ['Needs attention', 'Working', 'Off']) {
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
      expect(find.text('All ${r.weather.enabledSources.length} working'), findsOneWidget);
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
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-key-$_firms')), findsOneWidget);
      await r.dispose(tester);
    });
  });
}

// Weather shown: opening the Weather screen or Home's weather card runs an update that is due (and only that), and the iPhone's
// background sync round also updates weather when due.

import 'dart:async';

import 'package:cache/background/sync_background.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_screen_kit.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  group('the Weather screen', () {
    testWidgets('opened with stale weather, it updates', (tester) async {
      final r = await SettingsRig.create(tester);
      await useScreenSources(tester, r, kUsualSources);
      r.liveCore.fetches.clear();
      await r.show(tester, WeatherScreen(weather: r.weather));
      await _settle(tester);
      expect(r.liveCore.fetches, isNotEmpty, reason: 'never updated: due');
      await r.dispose(tester);
    });

    testWidgets('opened with fresh weather, nothing is fetched', (tester) async {
      final r = await SettingsRig.create(tester);
      await useScreenSources(tester, r, kUsualSources);
      await tester.runAsync(() => r.weather.updateNow());
      r.liveCore.fetches.clear();
      await r.show(tester, WeatherScreen(weather: r.weather));
      await _settle(tester);
      expect(r.liveCore.fetches, isEmpty);
      await r.dispose(tester);
    });
  });

  group("Home's weather card", () {
    Widget home(SettingsRig r, LayoutState layout) =>
        HomeScreen(layout: layout, weather: r.weather, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {});

    testWidgets('built with stale weather, it updates', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      await useScreenSources(tester, r, kUsualSources);
      r.liveCore.fetches.clear();
      await r.show(tester, home(r, layout));
      await _settle(tester);
      expect(r.liveCore.fetches, isNotEmpty);
      await r.dispose(tester);
    });

    testWidgets('built with fresh weather, nothing is fetched', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      await useScreenSources(tester, r, kUsualSources);
      await tester.runAsync(() => r.weather.updateNow());
      r.liveCore.fetches.clear();
      await r.show(tester, home(r, layout));
      await _settle(tester);
      expect(r.liveCore.fetches, isEmpty);
      await r.dispose(tester);
    });
  });

  group("the iPhone's background sync round", () {
    test('updates weather when due, after the sync', () async {
      final order = <String>[];
      final out = await syncRefreshRun(
        ios: true,
        sync: () async {
          order.add('sync');
          return 'done';
        },
        weather: () async => order.add('weather'),
      );
      expect(out, 'done');
      expect(order, ['sync', 'weather']);
    });

    test('on Android it is only the sync round (WorkManager has its own weather job)', () async {
      var weather = 0;
      final out = await syncRefreshRun(ios: false, sync: () async => 'done', weather: () async => weather++);
      expect(out, 'done');
      expect(weather, 0);
    });

    test('a weather update that throws does not fail the sync round', () async {
      final out = await syncRefreshRun(ios: true, sync: () async => '2 new in 1 folder', weather: () async => throw StateError('no'));
      expect(out, '2 new in 1 folder');
    });

    test('weather still runs when the sync round is skipped', () async {
      var weather = 0;
      final out = await syncRefreshRun(ios: true, sync: () async => 'skipped: Cache is open', weather: () async => weather++);
      expect(out, 'skipped: Cache is open');
      expect(weather, 1);
    });
  });
}

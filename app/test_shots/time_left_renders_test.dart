// The guidance bar's time left and arrival clock, for the owner to compare before and after the time left takes in the drive's pace.
// The same made-up drive is fed in each picture: a route the plan counts at 20 m/s, driven at 14 m/s, so the plan's time left runs
// short of the real one. Three moments: 8 minutes in, after 3 minutes stopped in a queue, and near the end. The test uses only what
// both versions have (NavState with a clock, GuidanceBar, the fake core), so it runs unchanged on either.
// flutter test test_shots/time_left_renders_test.dart --update-goldens  (pictures in test_shots/time_left/)

import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/guidance_panels.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import 'shot_kit.dart';

const _out = 'time_left';

Widget _page(NavState nav, String caption) => Builder(
      builder: (context) => Scaffold(
        body: Stack(children: [
          Positioned(
            left: 16,
            right: 16,
            top: 80,
            child: Text(caption, style: const TextStyle(fontSize: 16, color: Color(0xFF444444))),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ListenableBuilder(listenable: nav, builder: (context, _) => GuidanceBar(nav: nav, fmt: const Fmt(UnitSystem.imperial))),
          ),
        ]),
      ),
    );

void main() {
  setUpAll(() async {
    await loadShotFonts();
  });

  testWidgets('time left, mid-route, after a stop, near arrival', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    final dir = Directory.systemTemp.createTempSync('time-left-renders-');
    final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final route = fakeRouteJson(name: 'Shoshone Falls Park');
    final total = (route['distance_m'] as num).toDouble();
    var now = DateTime(2026, 10, 26, 12);
    var along = 0.0;
    final backend = FakeBackend()
      ..onRoute = ((to, mode, from) async => MapRoute.fromJson(route))
      ..onProgress = ((r, lat, lon) async {
        final j = fakeProgressJson(route, (along / total).clamp(0.0, 0.97));
        // The fake's 'remaining' map is typed for numbers only, so it is rebuilt as a map of anything to add the arrival time.
        final rem = Map<String, dynamic>.from(j['remaining'] as Map);
        rem['eta'] = now.add(Duration(seconds: rem['duration_s'] as int)).toUtc().toIso8601String();
        j['remaining'] = rem;
        return MapProgress.fromJson(j);
      });
    final gps = FakeNavPosition();
    final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), clock: () => now);
    // One fix every 10 seconds, [metres] further along the route than the last.
    Future<void> step(double metres) async {
      now = now.add(const Duration(seconds: 10));
      along += metres;
      await tester.runAsync(() async {
        gps.controller.add(fixAt(42.5, -113.8, heading: 90));
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }

    Future<void> shot(String name, String caption) async {
      await tester.pumpWidget(shotApp(_page(nav, caption), theme: CacheThemeId.light, insets: const EdgeInsets.only(top: 47, bottom: 34)));
      await tester.pump();
      await snap(tester, _out, name);
    }

    try {
      await tester.runAsync(() async {
        await location.init();
        // A known position, as the branch's own tests have it, so the route can be worked out from it and guidance starts on it.
        location.publish(fixAt(42.5, -113.8));
        await nav.openDirections(const MapPlace(id: 'place:osm:w7', type: 'place', name: 'Shoshone Falls Park', kind: 'Park', address: 'Twin Falls, ID', lat: 42.5944, lon: -114.4003, matched: 'name'));
        await nav.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      expect(nav.progress, isNotNull, reason: 'guidance is on the route');
      expect(nav.route!.distanceM, greaterThan(5000));
      await step(0);
      for (var i = 0; i < 48; i++) {
        await step(140);
      }
      await shot('1-mid-route', 'Mid-route: 8 minutes driven at 14 m/s; the route is planned at 20 m/s.');
      for (var i = 0; i < 18; i++) {
        await step(0);
      }
      await shot('2-stopped', 'Stopped in a queue for 3 minutes, the same drive.');
      while (along < total * 0.9) {
        await step(140);
      }
      await shot('3-near-arrival', 'Near the end of the same drive, 90% along the route.');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      nav.dispose();
      location.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    }
  });
}

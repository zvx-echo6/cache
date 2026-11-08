import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/guidance_camera.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/test_layer_engine.dart';

void main() {
  group('where the position sits while guiding', () {
    test('a phone held upright: 72% of the way down, centred across', () {
      final a = guidanceAnchor(const Size(390, 844), side: false);
      expect(a.dx, 195);
      expect(a.dy, closeTo(844 * 0.72, 0.01));
    });

    test('a short phone keeps it clear of the guidance bar', () {
      final a = guidanceAnchor(const Size(360, 600), side: false);
      expect(a.dy, 600 - 190);
      expect(a.dy, greaterThan(300));
    });

    test('side by side (landscape, tablet, computer): right of the left column, 70% down', () {
      final land = guidanceAnchor(const Size(844, 390), side: true);
      expect(land.dx, (12 + 380 + 12 + 844) / 2);
      expect(land.dy, closeTo(390 * 0.70, 0.01));
      final wide = guidanceAnchor(const Size(1440, 900), side: true, leftInset: 0);
      expect(wide.dx, (404 + 1440) / 2);
      expect(wide.dy, closeTo(630, 0.01));
    });

    test('never above the middle', () {
      final a = guidanceAnchor(const Size(390, 300), side: false);
      expect(a.dy, 150);
    });
  });

  test('the camera centre puts the position on its anchor at any heading', () {
    const map = Size(390, 844);
    final anchor = guidanceAnchor(map, side: false);
    for (final bearing in [0.0, 37.0, 90.0, 180.0, 271.0]) {
      final (lat, lon) = cameraCentreFor(42.56, -114.46, bearing: bearing, zoom: 16.5, map: map, anchor: anchor);
      final p = screenPointFor(42.56, -114.46, centreLat: lat, centreLon: lon, bearing: bearing, zoom: 16.5, map: map);
      expect(p.dx, closeTo(anchor.dx, 0.5), reason: 'bearing $bearing');
      expect(p.dy, closeTo(anchor.dy, 0.5), reason: 'bearing $bearing');
    }
    // Heading north, the centre is north of the position (the road ahead fills the screen above it).
    final (lat, lon) = cameraCentreFor(42.56, -114.46, bearing: 0, zoom: 16, map: map, anchor: anchor);
    expect(lat, greaterThan(42.56));
    expect(lon, closeTo(-114.46, 1e-9));
  });

  testWidgets('guiding heading-up moves the camera ahead of the position; following outside guidance keeps it centred', (tester) async {
    // A phone held upright (stacked layout), wide enough for the test font's square letters.
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('guidance-camera-');
    final originalPlatform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine();
    final maps = MapsState(engine: engine, settingsDirOverride: dir);
    final route = fakeRouteJson();
    final backend = FakeBackend()
      ..onRoute = ((to, mode, from) async => MapRoute.fromJson(route))
      ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.2)));
    final gps = FakeNavPosition();
    final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
    final camera = CameraController();
    try {
      await tester.runAsync(() async {
        await location.init();
        await engine.start();
      });
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: MapsScreen(location: location, maps: maps, nav: nav, themeId: CacheThemeId.dark, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
      ));
      for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      map.onMapCreated!(camera);
      map.onStyleLoadedCallback!();
      await tester.pump();

      Map<String, dynamic> lastPosition() {
        final u = camera.cameras.lastWhere((c) => (c as List).first == 'newCameraPosition') as List;
        return (u[1] as Map).cast<String, dynamic>();
      }

      // Following north-up, not guiding: the camera is on the position.
      maps.setFollow(FollowMode.follow);
      location.publish(fixAt(42.56, -114.46, heading: 90));
      await tester.pump();
      expect(lastPosition()['target'], [42.56, -114.46]);

      // Guiding: heading-up, and the position sits 72% of the way down.
      await tester.runAsync(() async {
        await nav.openDirections(const MapPlace(id: 'p', type: 'place', name: 'Hospital', kind: '', address: '', lat: 42.5, lon: -113.5, matched: ''));
        await nav.start();
      });
      expect(maps.follow, FollowMode.headingUp);
      location.publish(fixAt(42.56, -114.46, heading: 90));
      await tester.pump();
      final c = lastPosition();
      final target = (c['target'] as List).cast<double>();
      final size = tester.getSize(find.byType(MapLibreMap));
      final p = screenPointFor(42.56, -114.46, centreLat: target[0], centreLon: target[1], bearing: (c['bearing'] as num).toDouble(), zoom: (c['zoom'] as num).toDouble(), map: size);
      expect(p.dx, closeTo(size.width / 2, 0.5));
      expect(p.dy, closeTo(size.height * 0.72, 0.5));
      // Heading east: the centre is east of the position.
      expect(target[1], greaterThan(-114.46));

      // Guidance over (the map then shows the place); following again, the camera is back on the position.
      await tester.runAsync(() => nav.end());
      await tester.pump();
      maps.setFollow(FollowMode.headingUp);
      location.publish(fixAt(42.561, -114.461, heading: 90));
      await tester.pump();
      expect(nav.guiding, isFalse);
      expect(lastPosition()['target'], [42.561, -114.461]);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      MapLibrePlatform.createInstance = originalPlatform;
      camera.dispose();
      nav.dispose();
      maps.dispose();
      location.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    }
  });
}

import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/overview/overview_camera.dart';
import 'package:cache/nav/overview/route_overview.dart';
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

/// A profile along the fake route (about 24.6 km east along 42.5N): up 120 m, then down 60 m; [gapFrom]..[gapTo] has no data.
ElevationProfile fixtureProfile({double? gapFrom, double? gapTo}) {
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= 24000; x += 40) {
    d.add(x);
    final h = x < 12000 ? 1200 + x * 0.01 : 1320 - (x - 12000) * 0.005;
    e.add(gapFrom != null && x >= gapFrom && x <= gapTo! ? double.nan : h);
  }
  return ElevationProfile.fromSamples(d, e);
}

/// Records what was asked for; makes no picture (the map is a platform view, not drawn in tests).
class FakeSnapshotter implements RouteSnapshotter {
  final List<OverviewCamera> asked = [];

  @override
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio}) async {
    asked.add(camera);
    return null;
  }
}

class _Rig {
  _Rig(this.nav, this.maps, this.location, this.elevation, this.snapshots);
  final NavState nav;
  final MapsState maps;
  final LocationService location;
  final RouteElevation elevation;
  final FakeSnapshotter snapshots;
}

Future<void> _withGuidance(WidgetTester tester, {required Size size, required Future<void> Function(_Rig rig) body, ElevationProfile? profile}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final dir = Directory.systemTemp.createTempSync('nav-elevation-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final route = fakeRouteJson(name: 'Pine Hollow Trailhead');
  final backend = FakeBackend()
    ..onRoute = ((to, mode, from) async => MapRoute.fromJson(route))
    ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.25)));
  final gps = FakeNavPosition();
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
  final elevation = RouteElevation(loader: (r) async => profile ?? fixtureProfile());
  final snapshots = FakeSnapshotter();
  final camera = CameraController();
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: MapsScreen(
        location: location,
        maps: maps,
        nav: nav,
        themeId: CacheThemeId.light,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: elevation,
        snapshotter: snapshots,
      ),
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    location.publish(fixAt(42.5, -113.79, heading: 90));
    await tester.runAsync(() async {
      await nav.openDirections(const MapPlace(id: 'place:osm:n4', type: 'place', name: 'Pine Hollow Trailhead', kind: 'Park', address: '', lat: 42.5, lon: -113.5, matched: 'name'));
      await nav.start();
      gps.controller.add(fixAt(42.5, -113.78, heading: 90));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await body(_Rig(nav, maps, location, elevation, snapshots));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    camera.dispose();
    nav.dispose();
    elevation.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('a tap on the inset swaps the views; the live map is the same map, moved into the corner', (tester) async {
    await _withGuidance(tester, size: const Size(390, 844), body: (rig) async {
      expect(find.byKey(const ValueKey('route-inset')), findsOneWidget);
      expect(find.bySemanticsLabel('Swap to the whole route'), findsOneWidget);
      expect(find.byKey(const ValueKey('route-overview-full')), findsNothing);
      expect(find.byType(MapLibreMap), findsOneWidget);
      final live = tester.state(find.byType(MapLibreMap));
      expect(tester.getSize(find.byType(MapLibreMap)), const Size(390, 844));
      // The corner's picture was asked for once, fitted to the inset (112 less its border).
      expect(rig.snapshots.asked.single.size, const Size(108, 108));

      await tester.tap(find.byKey(const ValueKey('route-inset')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('route-overview-full')), findsOneWidget);
      expect(find.bySemanticsLabel('Swap to the close-up'), findsOneWidget);
      expect(find.byType(MapLibreMap), findsOneWidget);
      expect(identical(tester.state(find.byType(MapLibreMap)), live), isTrue, reason: 'the live map moved; it was not made again');
      final corner = tester.getRect(find.byKey(const ValueKey('route-inset')));
      final map = tester.getRect(find.byType(MapLibreMap));
      expect(map.size, const Size(108, 108));
      expect(map.center.dx, closeTo(corner.center.dx, 0.5));
      expect(map.center.dy, closeTo(corner.center.dy, 0.5));
      // The full-screen picture is rendered at the screen's size.
      expect(rig.snapshots.asked.last.size, const Size(390, 844));

      await tester.tap(find.byKey(const ValueKey('route-inset')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('route-overview-full')), findsNothing);
      expect(identical(tester.state(find.byType(MapLibreMap)), live), isTrue);
      expect(tester.getSize(find.byType(MapLibreMap)), const Size(390, 844));
    });
  });

  testWidgets('on a phone the inset hides while the elevation panel is pulled up', (tester) async {
    await _withGuidance(tester, size: const Size(390, 844), body: (rig) async {
      expect(find.byKey(const ValueKey('elevation-handle')), findsOneWidget);
      expect(find.byKey(const ValueKey('elevation-panel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('elevation-handle')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('elevation-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('elevation-chart')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-inset')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('elevation-handle')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('elevation-panel')), findsNothing);
      expect(find.byKey(const ValueKey('route-inset')), findsOneWidget);
    });
  });

  testWidgets('swapped on a phone, pulling the panel up hides the small live map too', (tester) async {
    await _withGuidance(tester, size: const Size(390, 844), body: (rig) async {
      await tester.tap(find.byKey(const ValueKey('route-inset')));
      await _settle(tester);
      rig.elevation.setOpen(true);
      await _settle(tester);
      expect(find.byKey(const ValueKey('route-inset')), findsNothing);
      // Kept (not made again) but not shown.
      expect(find.byType(MapLibreMap, skipOffstage: false), findsOneWidget);
      expect(find.byType(MapLibreMap), findsNothing);
    });
  });

  testWidgets('on a tablet the inset stays while the panel is up', (tester) async {
    await _withGuidance(tester, size: const Size(1440, 900), body: (rig) async {
      expect(tester.getSize(find.byKey(const ValueKey('route-inset'))), const Size(160, 160));
      await tester.tap(find.byKey(const ValueKey('elevation-handle')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('elevation-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-inset')), findsOneWidget);
    });
  });

  testWidgets('a phone held sideways has the 96-point inset', (tester) async {
    await _withGuidance(tester, size: const Size(844, 390), body: (rig) async {
      expect(tester.getSize(find.byKey(const ValueKey('route-inset'))), const Size(96, 96));
    });
  });

  testWidgets('no elevation data: the handle stays and the panel says so in one line', (tester) async {
    await _withGuidance(tester, size: const Size(390, 844), profile: ElevationProfile.none(24000), body: (rig) async {
      expect(find.byKey(const ValueKey('elevation-handle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('elevation-handle')));
      await _settle(tester);
      expect(find.text('No elevation data for this route.'), findsOneWidget);
      expect(find.byKey(const ValueKey('elevation-chart')), findsNothing);
    });
  });

  testWidgets('partial data: the chart is drawn and the missing part is named', (tester) async {
    await _withGuidance(tester, size: const Size(390, 844), profile: fixtureProfile(gapFrom: 15000, gapTo: 18000), body: (rig) async {
      rig.elevation.setOpen(true);
      await _settle(tester);
      expect(find.byKey(const ValueKey('elevation-chart')), findsOneWidget);
      expect(find.byKey(const ValueKey('elevation-missing')), findsOneWidget);
      expect(find.textContaining('No elevation data for 1.9 mi of this route'), findsOneWidget);
    });
  });

  group('the distance rule for the dot on the picture', () {
    test('about 2 pixels, or a turn, and at most twice a second', () {
      final g = RedrawGate();
      final t0 = DateTime(2026, 11, 8, 12);
      expect(g.decide(const Offset(10, 10), 90, t0), Duration.zero);
      g.drawn(const Offset(10, 10), 90, t0);
      // Less than 2 pixels and a small turn: nothing.
      expect(g.decide(const Offset(11.2, 10.8), 95, t0.add(const Duration(seconds: 3))), isNull);
      // 2 pixels, but only 200 ms later: wait out the half second.
      expect(g.decide(const Offset(12, 10), 90, t0.add(const Duration(milliseconds: 200))), const Duration(milliseconds: 300));
      // 2 pixels after a second: now.
      expect(g.decide(const Offset(12, 10), 90, t0.add(const Duration(seconds: 1))), Duration.zero);
      // Standing still but turned 10 degrees: now.
      expect(g.decide(const Offset(10, 10), 100, t0.add(const Duration(seconds: 1))), Duration.zero);
      // Across north: 355 to 5 is a 10 degree turn.
      g.drawn(const Offset(10, 10), 355, t0);
      expect(g.decide(const Offset(10, 10), 5, t0.add(const Duration(seconds: 1))), Duration.zero);
    });

    test('how often the dot moves follows the speed and the picture\'s scale, never faster than twice a second', () {
      // A 5 km route in the 108-point corner picture: about 50 m a point, so 2 points is about 100 m.
      final cam = OverviewCamera.fit(south: 42.5, west: -113.80, north: 42.505, east: -113.74, size: const Size(108, 108));
      double seconds(double speedMps) {
        final s = kOverviewRedrawPixels * cam.metresPerPixel / speedMps;
        return s < kOverviewMinInterval.inMilliseconds / 1000 ? kOverviewMinInterval.inMilliseconds / 1000 : s;
      }

      expect(seconds(1.4), greaterThan(30)); // walking: every several seconds or more
      expect(seconds(30), inInclusiveRange(1, 6)); // highway
      // The close-up in the corner (zoom 16): the half-second cap while driving.
      final close = OverviewCamera(lat: 42.5, lon: -113.8, zoom: 16, size: const Size(108, 108));
      expect(kOverviewRedrawPixels * close.metresPerPixel / 30, lessThan(0.5));
    });

    test('the picture fits the route inside its padding, and the dot is placed with the same camera', () {
      final cam = OverviewCamera.fit(south: 42.0, west: -114.0, north: 42.5, east: -113.0, size: const Size(390, 844), padding: const EdgeInsets.fromLTRB(32, 150, 32, 210));
      final sw = cam.project(42.0, -114.0), ne = cam.project(42.5, -113.0);
      expect(sw.dx, closeTo(32, 1));
      expect(ne.dx, closeTo(390 - 32, 1));
      // The height has room to spare; the box is centred in the padded area.
      expect((sw.dy + ne.dy) / 2, closeTo(150 + (844 - 150 - 210) / 2, 1));
    });
  });
}

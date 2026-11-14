import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart' show kPositionSource;
import 'package:cache/nav/guidance_camera.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/guide_anchor.dart';
import 'support/test_layer_engine.dart';
import '../test_shots/shot_kit.dart' show loadShotFonts, shotApp;

/// The camera the screen last gave the map (a move with or without animation).
Map<String, dynamic> lastCamera(CameraController camera) {
  final u = camera.cameras.lastWhere((c) => (c as List).first == 'newCameraPosition') as List;
  return (u[1] as Map).cast<String, dynamic>();
}

/// Where ([lat], [lon]) is on a map of [map] size seen by [c] (a camera the screen gave the map).
Offset seenAt(Map<String, dynamic> c, double lat, double lon, Size map) {
  final t = (c['target'] as List).cast<num>();
  return screenPointFor(lat, lon, centreLat: t[0].toDouble(), centreLon: t[1].toDouble(), bearing: (c['bearing'] as num).toDouble(), zoom: (c['zoom'] as num).toDouble(), map: map);
}

/// Where the screen draws the position's marker now (the point of the position source).
(double, double) markerOf(CameraController camera) {
  final f = (camera.sources[kPositionSource]!['features'] as List).cast<Map<String, dynamic>>().firstWhere((f) => f['geometry']['type'] == 'Point');
  final c = (f['geometry']['coordinates'] as List).cast<num>();
  return (c[1].toDouble(), c[0].toDouble());
}

/// The Maps screen on a screen of [size] points at [ratio] pixels a point, guiding along the fake route after showing it (so a
/// route was fitted into view before Start, as on the phone). [body] is given the rig once the first guidance fix is in.
/// With [fixesAfterStart] false the map is given no fix after Start: the phone stands still (its last fix is from before).
Future<void> guiding(WidgetTester tester, {required Size size, required double ratio, required Future<void> Function(GuideRig rig) body, bool fixesAfterStart = true}) async {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  // The style template is read through the asset bundle, which keeps the read an earlier test started (it never finishes in
  // this one): read it afresh, or the map never appears.
  rootBundle.clear();
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
    // The phone's own font (the test font's square letters are far wider: the position chip shown before Start would not fit
    // beside the map's buttons on a narrow phone), and no safe area.
    await tester.pumpWidget(shotApp(
      MapsScreen(location: location, maps: maps, nav: nav, themeId: CacheThemeId.dark, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
      theme: CacheThemeId.dark,
      insets: EdgeInsets.zero,
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    location.publish(fixAt(42.5, -113.8, heading: 90));
    await tester.pump();
    await tester.runAsync(() => nav.openDirections(const MapPlace(id: 'p', type: 'place', name: 'Place 1', kind: '', address: '', lat: 42.5, lon: -113.5, matched: '')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      await nav.start();
      // Standing still, the position stream gives nothing after Start (a fix here is published to the location too, and the
      // map would follow it as any fix, not from Start): the last fix stays the one from before, at 42.5, -113.8.
      if (fixesAfterStart) gps.controller.add(fixAt(42.5, -113.79, heading: 90));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    final rig = GuideRig(tester, camera, location, nav, maps, gps, backend, route);
    rig.camerasBeforeStart = camera.cameras.length;
    if (!fixesAfterStart) {
      await body(rig);
      return;
    }
    await tester.pump();
    // The first fix moves the map there; the same fix again glides in place, with the screen as it is laid out by then.
    await rig.fix(42.5, -113.79, 90);
    await rig.fix(42.5, -113.79, 90);
    await body(rig);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    camera.dispose();
    nav.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

class GuideRig {
  GuideRig(this.tester, this.camera, this.location, this.nav, this.maps, this.gps, this.backend, this.route);

  final WidgetTester tester;
  final CameraController camera;
  final LocationService location;
  final NavState nav;
  final MapsState maps;
  final FakeNavPosition gps;
  final FakeBackend backend;
  final Map<String, dynamic> route;

  Size get mapSize => tester.getSize(find.byType(MapLibreMap));

  /// How many camera moves the screen had asked for when Start was tapped.
  int camerasBeforeStart = 0;

  /// A fix reaches the map, and the glide to it runs to its end.
  Future<void> fix(double lat, double lon, double heading) async {
    location.publish(fixAt(lat, lon, heading: heading));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 160));
    }
  }

  /// Where the last camera puts ([lat], [lon]).
  Offset seen(double lat, double lon) => seenAt(lastCamera(camera), lat, lon, mapSize);
}

void main() {
  setUpAll(loadShotFonts);

  group('the free map and the anchor', () {
    test('a phone: between the banner and the guidance bar; centred across, 72% of the way down', () {
      const map = Size(390, 800);
      final free = guidanceFreeMap(map, const GuideCovers(top: 150, bottom: 690));
      expect(free, const Rect.fromLTRB(0, 150, 390, 690));
      final a = guidanceAnchor(free);
      expect(a.dx, 195);
      expect(a.dy, closeTo(150 + 540 * kGuideDown, 1e-9));
    });

    test('side by side: right of the column, clear of the safe area', () {
      const map = Size(1280, 800);
      final free = guidanceFreeMap(map, const GuideCovers(left: 404), safe: const EdgeInsets.only(top: 24, bottom: 16));
      expect(free, const Rect.fromLTRB(404, 24, 1280, 784));
      final a = guidanceAnchor(free);
      expect(a.dx, (404 + 1280) / 2);
      expect(a.dy, closeTo(24 + 760 * kGuideDown, 1e-9));
    });

    test('the pieces in the corners (scale, credits, mini map, buttons) do not move it', () {
      const free = Rect.fromLTRB(0, 150, 384, 640);
      final tiles = [
        const Rect.fromLTRB(12, 560, 132, 590), // the scale, bottom left
        const Rect.fromLTRB(12, 596, 260, 624), // the credits under it
        const Rect.fromLTRB(260, 470, 372, 582), // the mini map, bottom right
        const Rect.fromLTRB(324, 160, 372, 268), // the buttons, top right
      ];
      expect(guidanceAnchor(free, tiles: tiles, reach: 20), guidanceAnchor(free, reach: 20));
      expect(guidanceAnchor(free, tiles: tiles, reach: 20).dx, 192);
    });

    test('a piece it would be under lifts it above that piece, never above the middle; only then is it moved across', () {
      const free = Rect.fromLTRB(0, 100, 400, 600); // anchor 400 down
      final low = [const Rect.fromLTRB(150, 420, 250, 500)];
      final a = guidanceAnchor(free, tiles: low, reach: 20);
      expect(a.dx, 200);
      expect(a.dy, 420 - 20 - kGuideClear);
      final tall = [const Rect.fromLTRB(150, 300, 260, 500)];
      final b = guidanceAnchor(free, tiles: tall, reach: 20);
      expect(b.dy, 350); // the middle
      expect(b.dx, 150 - 20 - kGuideClear); // more room on the left
      expect(Rect.fromCircle(center: b, radius: 20).overlaps(tall.single), isFalse);
    });

    test('nothing over the map: the whole map', () {
      final free = guidanceFreeMap(const Size(390, 844), const GuideCovers());
      expect(free, const Rect.fromLTRB(0, 0, 390, 844));
      expect(guidanceAnchor(free), Offset(195, 844 * kGuideDown));
    });
  });

  test('the camera centre puts the position on its anchor at any heading', () {
    const map = Size(390, 844);
    final anchor = guidanceAnchor(guidanceFreeMap(map, const GuideCovers(top: 140, bottom: 700)));
    for (final bearing in [0.0, 37.0, 90.0, 180.0, 271.0]) {
      final (lat, lon) = cameraCentreFor(42.56, -114.46, bearing: bearing, zoom: 16.5, map: map, anchor: anchor);
      final p = screenPointFor(42.56, -114.46, centreLat: lat, centreLon: lon, bearing: bearing, zoom: 16.5, map: map);
      expect(p.dx, closeTo(anchor.dx, 0.5), reason: 'bearing $bearing');
      expect(p.dy, closeTo(anchor.dy, 0.5), reason: 'bearing $bearing');
    }
  });

  group('the glide from fix to fix', () {
    test('even pace, the short way round', () {
      const a = (lat: 42.0, lon: -114.0, bearing: 350.0), b = (lat: 42.001, lon: -113.999, bearing: 10.0);
      final g = GuideGlide(from: a, to: b, duration: const Duration(seconds: 1));
      final mid = g.at(const Duration(milliseconds: 500));
      expect(mid.lat, closeTo(42.0005, 1e-9));
      expect(mid.lon, closeTo(-113.9995, 1e-9));
      expect(mid.bearing % 360, closeTo(0, 1e-9));
      expect(g.at(const Duration(seconds: 2)), b);
      expect(g.doneAt(const Duration(seconds: 1)), isTrue);
    });

    test('takes the time the fixes come apart, within bounds', () {
      expect(glideDuration(null), const Duration(seconds: 1));
      expect(glideDuration(const Duration(milliseconds: 900)), const Duration(milliseconds: 900));
      expect(glideDuration(const Duration(milliseconds: 40)), kGlideShortest);
      expect(glideDuration(const Duration(seconds: 5)), kGlideLongest);
    });
  });

  testWidgets('guiding heading-up: no padding left from the route preview, the position on its anchor, steady from fix to fix', (tester) async {
    await guiding(tester, size: const Size(384, 832), ratio: 2.8125, body: (rig) async {
      final camera = rig.camera;
      expect(rig.maps.follow, FollowMode.headingUp);
      // The route was fitted into view before Start (that fit's padding stays on the map on Android): the screen then gave the
      // map no padding, and has not changed it since.
      expect(camera.cameras.any((c) => (c as List).first == 'newLatLngBounds'), isTrue);
      expect(camera.padding, EdgeInsets.zero);
      final padsAtStart = camera.insets.length;
      final layout = GuideLayout.read(tester);
      final at = rig.seen(42.5, -113.79);
      expect(at.dx, closeTo(layout.anchor.dx, 0.5));
      expect(at.dy, closeTo(layout.anchor.dy, 0.5));
      expect(at.dx, closeTo(layout.free.center.dx, 0.5), reason: 'centred across the free map');
      expect((at.dy - layout.free.top) / layout.free.height, closeTo(kGuideDown, 0.002));
      final zoom = (lastCamera(camera)['zoom'] as num).toDouble();
      expect(zoom, 16);

      // Fixes along the road, each with a progress answer: the position stays on the same spot, the padding and the zoom do not
      // change.
      var lon = -113.79;
      for (var i = 1; i <= 4; i++) {
        lon += 0.0002;
        rig.backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(rig.route, 0.2 + 0.01 * i));
        await tester.runAsync(() async {
          rig.gps.controller.add(fixAt(42.5, lon, heading: 90));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await rig.fix(42.5, lon, 90 + i * 3.0);
        final p = rig.seen(42.5, lon);
        expect(p.dx, closeTo(at.dx, 0.5), reason: 'fix $i');
        expect(p.dy, closeTo(at.dy, 0.5), reason: 'fix $i');
        expect((lastCamera(camera)['zoom'] as num).toDouble(), zoom, reason: 'fix $i');
      }
      expect(camera.insets.length, padsAtStart, reason: 'the padding is not set again between fixes');
      expect(camera.moves, isNotEmpty, reason: 'fixes after the first glide');
    });
  });

  testWidgets('during a glide the marker is where the camera puts the position: it does not jump ahead and slide back', (tester) async {
    await guiding(tester, size: const Size(390, 844), ratio: 3, body: (rig) async {
      final camera = rig.camera;
      final at = rig.seen(42.5, -113.79);
      // The next fix, 30 m on and turning a little.
      rig.location.publish(fixAt(42.5, -113.7896, heading: 100));
      await tester.pump();
      // At once the marker is still where the camera has it (not at the new fix ahead of it).
      var (mLat, mLon) = markerOf(camera);
      var p = seenAt(lastCamera(camera), mLat, mLon, rig.mapSize);
      expect(p.dx, closeTo(at.dx, 0.5));
      expect(p.dy, closeTo(at.dy, 0.5));
      // Part of the way along, the camera and the marker have moved together.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      (mLat, mLon) = markerOf(camera);
      expect(mLon, greaterThan(-113.79));
      expect(mLon, lessThan(-113.7896));
      p = seenAt(lastCamera(camera), mLat, mLon, rig.mapSize);
      expect(p.dx, closeTo(at.dx, 0.5));
      expect(p.dy, closeTo(at.dy, 0.5));
      // At the end, the new fix is on the spot.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 160));
      }
      (mLat, mLon) = markerOf(camera);
      expect(mLon, closeTo(-113.7896, 1e-9));
      p = rig.seen(42.5, -113.7896);
      expect(p.dx, closeTo(at.dx, 0.5));
      expect(p.dy, closeTo(at.dy, 0.5));
    });
  });

  testWidgets('Start with the phone standing still: the guidance view at once from the last fix, not the route preview kept', (tester) async {
    await guiding(tester, size: const Size(384, 832), ratio: 2.8125, fixesAfterStart: false, body: (rig) async {
      // No fix after Start; two frames (32 ms) later the map has been asked for the guidance view.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final after = rig.camera.cameras.skip(rig.camerasBeforeStart).where((c) => (c as List).first == 'newCameraPosition');
      expect(after, isNotEmpty, reason: 'the map kept the route preview after Start');
      expect(rig.maps.follow, FollowMode.headingUp);
      final layout = GuideLayout.read(tester);
      final at = rig.seen(42.5, -113.8);
      expect(at.dx, closeTo(layout.free.center.dx, 0.5));
      expect(at.dy, closeTo(layout.anchor.dy, 2));
      expect((lastCamera(rig.camera)['bearing'] as num).toDouble(), 90);
    });
  });

  testWidgets('Find me after moving the map while guiding: back to the guidance view and its spot, heading up; north up keeps the spot', (tester) async {
    await guiding(tester, size: const Size(384, 832), ratio: 2.8125, body: (rig) async {
      final at = rig.seen(42.5, -113.79);
      // A finger moving the map stops the following (what the map's listener does on a drag).
      rig.maps.setFollow(FollowMode.free);
      await tester.pump();
      await tester.tap(find.byTooltip('Find me'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 160));
      }
      expect(rig.maps.follow, FollowMode.headingUp);
      var p = rig.seen(42.5, -113.79);
      expect(p.dx, closeTo(at.dx, 0.5));
      expect(p.dy, closeTo(at.dy, 0.5));
      // Fixes after it keep it there.
      await rig.fix(42.5, -113.7896, 95);
      p = rig.seen(42.5, -113.7896);
      expect(p.dx, closeTo(at.dx, 0.5));
      expect(p.dy, closeTo(at.dy, 0.5));
      // North up while guiding: the map turns north, the position keeps its spot.
      await tester.tap(find.byTooltip('Following you, heading up. Tap for north up'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 160));
      }
      expect(rig.maps.follow, FollowMode.follow);
      expect((lastCamera(rig.camera)['bearing'] as num).toDouble(), 0);
      p = rig.seen(42.5, -113.7896);
      expect(p.dx, closeTo(at.dx, 0.5));
      expect(p.dy, closeTo(at.dy, 0.5));
    });
  });

  testWidgets('guidance over: following again, the camera is back on the position, with no padding', (tester) async {
    await guiding(tester, size: const Size(390, 844), ratio: 3, body: (rig) async {
      await tester.runAsync(() => rig.nav.end());
      await tester.pump();
      rig.maps.setFollow(FollowMode.headingUp);
      rig.location.publish(fixAt(42.561, -114.461, heading: 90));
      await tester.pump();
      expect(rig.nav.guiding, isFalse);
      expect(lastCamera(rig.camera)['target'], [42.561, -114.461]);
      expect(rig.camera.padding, EdgeInsets.zero);
    });
  });

  // Every size and pixel ratio: the position is centred across the free map and the same fraction down it (or lifted clear of
  // a corner piece, never under one). Upright phones (including the Galaxy S22's 360 and 384 wide at its ratios, and the Pixel
  // 8's 412 at 2.625), a 600 wide small tablet, phones sideways, and a tablet both ways (side by side from 800 wide).
  final screens = <(Size, List<double>)>[
    (const Size(320, 568), [2.0, 2.625]),
    (const Size(360, 780), [2.625, 3.0]),
    (const Size(384, 832), [2.0, 2.625, 2.8125, 3.0, 3.5]),
    (const Size(390, 844), [2.0, 2.625, 2.8125, 3.0, 3.5]),
    (const Size(412, 915), [2.625, 3.5]),
    (const Size(600, 960), [2.0, 2.625]),
    (const Size(780, 360), [2.625, 3.0]),
    (const Size(832, 384), [2.8125]),
    (const Size(844, 390), [2.625, 3.0]),
    (const Size(915, 412), [2.625]),
    (const Size(1024, 1366), [2.0]),
    (const Size(1366, 1024), [2.0]),
  ];
  for (final (size, ratios) in screens) {
    for (final ratio in ratios) {
      testWidgets('${size.width.round()}x${size.height.round()} at $ratio: centred across the free map, the same way down it', (tester) async {
        await guiding(tester, size: size, ratio: ratio, body: (rig) async {
          final layout = GuideLayout.read(tester);
          final at = rig.seen(42.5, -113.79);
          expect(at.dx, closeTo(layout.anchor.dx, 0.5));
          expect(at.dy, closeTo(layout.anchor.dy, 0.5));
          expect(at.dx, closeTo(layout.free.center.dx, 0.5), reason: 'centred across ${layout.free}');
          final down = (at.dy - layout.free.top) / layout.free.height;
          expect(down, lessThanOrEqualTo(kGuideDown + 0.002));
          expect(down, greaterThanOrEqualTo(0.5 - 0.002));
          final lifted = down < kGuideDown - 0.002;
          for (final t in layout.tiles) {
            expect(Rect.fromCircle(center: at, radius: GuideLayout.reach).overlaps(t), isFalse, reason: 'under $t');
          }
          // Lifted only when a corner piece is where it would be.
          if (lifted) {
            final plain = Offset(layout.free.center.dx, layout.free.top + layout.free.height * kGuideDown);
            expect(layout.tiles.any((t) => Rect.fromCircle(center: plain, radius: GuideLayout.reach + kGuideClear).overlaps(t)), isTrue);
          }
          expect(rig.camera.padding, EdgeInsets.zero);
        });
      });
    }
  }
}

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart' show Fix;
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart' show kPinSelectedReach, kPositionDotReach;
import 'package:cache/maps/ui/vehicle_arrow.dart';
import 'package:cache/maps/ui/map_widgets.dart' show AttributionChip, MapButton, ScaleBarWidget;
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/overview/overview_camera.dart';
import 'package:cache/nav/ui/route_panel.dart' show DirectionsHeader, RoutePanel;
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'support/test_layer_engine.dart';

/// Suppress the platform surface; drive its public readiness callbacks ourselves.
class NoSurface extends MapLibrePlatform {
  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) => const SizedBox();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CameraController extends ChangeNotifier implements MapLibreMapController {
  final List<dynamic> cameras = [];
  final Map<String, Map<String, dynamic>> sources = {};
  @override
  Future<void> forceOnlineMode() async {}
  @override
  Future<void> addImage(
    String name,
    Uint8List bytes, [
    bool sdf = false,
  ]) async {}
  @override
  Future<void> setGeoJsonSource(String id, Map<String, dynamic> geojson) async {
    sources[id] = geojson;
  }

  @override
  Future<bool?> animateCamera(CameraUpdate update, {Duration? duration}) async {
    cameras.add(update.toJson());
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Where the map package keeps the paddings of a fit, read from its own encoding of a known one (left 11, top 12, right 13,
/// bottom 14), so the tests do not depend on their order.
final List<dynamic> _fitProbe =
    CameraUpdate.newLatLngBounds(LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(1, 1)), left: 11, top: 12, right: 13, bottom: 14).toJson() as List<dynamic>;

/// The padding of the fit [u] (a recorded camera update) that the known fit has as [probe].
double _fitPad(List<dynamic> u, double probe) => (u[_fitProbe.indexOf(probe)] as num).toDouble();

/// The fits among the camera moves the screen asked for, in order.
List<List<dynamic>> _fitsOf(CameraController camera) => camera.cameras.cast<List<dynamic>>().where((u) => u.first == 'newLatLngBounds').toList();

/// The camera a map of [map] points comes to after the fit [u] (a recorded camera update): the box the screen asked for inside
/// its paddings, by the same web-mercator fit the map makes.
OverviewCamera _cameraAfter(List<dynamic> u, Size map) {
  List<double> pair(Object? v) => [for (final n in v as List) (n as num).toDouble()];
  final a = pair((u[1] as List)[0]), b = pair((u[1] as List)[1]);
  return OverviewCamera.fit(
    south: math.min(a[0], b[0]),
    west: math.min(a[1], b[1]),
    north: math.max(a[0], b[0]),
    east: math.max(a[1], b[1]),
    size: map,
    padding: EdgeInsets.fromLTRB(_fitPad(u, 11), _fitPad(u, 12), _fitPad(u, 13), _fitPad(u, 14)),
  );
}

/// Where the bounding box of [route] falls on a map of [map] points after the fit [u] (a recorded camera update).
Rect _routeBoxOnMap(List<dynamic> u, MapRoute route, Size map) {
  final b = route.bounds;
  final cam = _cameraAfter(u, map);
  return Rect.fromPoints(cam.project(b[2], b[1]), cam.project(b[0], b[3]));
}

/// The Maps screen in a window of [size] points showing [route] before starting (as a route opened from elsewhere is shown),
/// once the screen has fitted it into view: [check] is given the last fit the screen asked for and the map's size. With
/// [position] the phone has a position, so the position chip shows. The screen has [ratio] pixels per point.
Future<void> _withFittedRoute(WidgetTester tester, {required Size size, required Map<String, dynamic> route, Fix? position, double ratio = 1, required void Function(List<dynamic> fit, Size map) check}) async {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  // The style template is read through the asset bundle, which keeps the read an earlier test started (it never finishes in
  // this one): read it afresh, or the map never appears.
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('route-fit-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final nav = NavState(backend: FakeBackend(), location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  final camera = CameraController();
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: MapsScreen(location: location, maps: maps, nav: nav, themeId: CacheThemeId.light, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
      ),
    );
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(MapLibreMap), findsOneWidget, reason: 'the map did not appear');
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    if (position != null) location.publish(position);
    expect(nav.previewSnapshot(MapRoute.fromJson(route)), isTrue);
    for (var i = 0; i < 100 && _fitsOf(camera).isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    // The panel may grow once more (the elevation arrives): the last fit is the one that stands.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(nav.phase, NavPhase.previewing);
    final fits = _fitsOf(camera);
    expect(fits, isNotEmpty, reason: 'the route was not fitted into view');
    check(fits.last, tester.getSize(find.byType(MapLibreMap)));
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

void main() {
  testWidgets(
    'preloaded snapshot fits on first style readiness and GPS cannot steal its preview',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('route-camera-');
      final originalPlatform = MapLibrePlatform.createInstance;
      MapLibrePlatform.createInstance = () => NoSurface();
      final location = LocationService(
        source: FakeSource(),
        settingsDirOverride: dir,
      );
      final engine = TestLayerEngine();
      final maps = MapsState(engine: engine, settingsDirOverride: dir);
      final backend = FakeBackend();
      final gps = FakeNavPosition();
      final nav = NavState(
        backend: backend,
        location: location,
        speaker: FakeSpeaker(),
        positionSource: gps,
        fmt: const Fmt(UnitSystem.imperial),
      );
      final camera = CameraController();
      try {
        await tester.runAsync(() async {
          await location.init();
          await engine.start();
        });
        maps.setFollow(FollowMode.follow);
        final snapshot = MapRoute.fromJson(
          fakeRouteJson(id: 'preloaded-exact'),
        );
        nav.previewSnapshot(
          snapshot,
        ); // Before MapsScreen has a listener or controller.
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(CacheThemeId.dark),
            home: MapsScreen(
              location: location,
              maps: maps,
              nav: nav,
              themeId: CacheThemeId.dark,
              glyphsLoader: () async =>
                  'file:///test/fonts/{fontstack}/{range}.pbf',
            ),
          ),
        );
        await tester.pump();
        for (
          var i = 0;
          i < 100 && find.byType(MapLibreMap).evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(find.byType(MapLibreMap), findsOneWidget);
        final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
        nav.selectRoute(0);
        nav.closeSearch(); // A notification before the controller must not consume the pending fit.
        expect(camera.cameras, isEmpty);
        map.onMapCreated!(camera);
        nav.closeSearch(); // Still no style.
        expect(camera.cameras, isEmpty);
        map.onStyleLoadedCallback!();
        for (var i = 0; i < 100 && camera.cameras.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        final bounds = snapshot.bounds;
        // The window is 800 wide: the header and the panel are in the column on the left, and the scale and the credits are
        // all that covers the map's foot. The route is fitted clear of both.
        final sideRight = tester.getRect(find.byType(DirectionsHeader)).right;
        final mapSize = tester.getSize(find.byType(MapLibreMap));
        final foot = mapSize.height - tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
        // The map's buttons are on the right: the route is fitted clear of them too.
        final buttons = mapSize.width - tester.getRect(find.byType(MapButton).first).left;
        expect(camera.cameras, [
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(bounds[0], bounds[1]),
              northeast: LatLng(bounds[2], bounds[3]),
            ),
            left: sideRight + kRouteFitGap,
            right: buttons + kRouteFitGap,
            top: 120,
            bottom: foot + kRouteFitGap,
          ).toJson(),
        ]);
        expect(maps.follow, FollowMode.free);
        expect(nav.phase, NavPhase.previewing);
        expect(nav.route!.raw, snapshot.raw);
        expect(backend.calls, isEmpty);
        expect(gps.starts, 0);
        expect(
          camera.sources.values.any(
            (s) => (s['features'] as List).any(
              (f) => f['geometry']['type'] == 'LineString',
            ),
          ),
          isTrue,
        );
        location.publish(fixAt(43, -114));
        await tester.pump();
        expect(camera.cameras, hasLength(1));
        nav.closeSearch();
        await tester.pump();
        expect(camera.cameras, hasLength(1)); // No duplicate fitting.
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        MapLibrePlatform.createInstance = originalPlatform;
        camera.dispose();
        nav.dispose();
        maps.dispose();
        location.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );

  test('the room around a fitted route follows what covers the map, and the map keeps room for the route', () {
    const phone = Size(390, 844);
    // (From 800 wide, and when nothing over the map could be read. A phone has its two free rectangles: the test below.)
    // With no column on the left: at the foot what is covered there, and a gap; the other edges as they are.
    expect(routeFitPadding(screen: phone, map: phone, coveredFoot: 380), const EdgeInsets.fromLTRB(48, 120, 48, 396));
    expect(routeFitPadding(screen: phone, map: phone, coveredFoot: 582).bottom, 582 + kRouteFitGap);
    // A cover that leaves no room: the map keeps the least room for the route (with no room at all it would not move).
    const low = Size(700, 400);
    expect(routeFitPadding(screen: low, map: low, coveredFoot: 390).bottom, 400 - kRouteFitTop - kRouteFitLeast);
    expect(kRouteFitTop + routeFitPadding(screen: low, map: low, coveredFoot: 390).bottom, lessThan(400));
    expect(routeFitPadding(screen: const Size(700, 100), map: const Size(700, 100), coveredFoot: 90).bottom, 0);
    // From 800 wide: clear of the column on the left, and at the foot only what the scale and the credits cover.
    const wide = Size(1200, 800);
    expect(routeFitPadding(screen: wide, map: wide, coveredFoot: 74, coveredLeft: 392), const EdgeInsets.fromLTRB(408, 120, 48, 90));
    // A column that leaves no room beside it: the map keeps the least room there too.
    const narrow = Size(480, 800);
    expect(routeFitPadding(screen: narrow, map: narrow, coveredFoot: 74, coveredLeft: 392).left, 480 - kRouteFitSide - kRouteFitLeast);
    // The map's buttons on the right: clear of them too, with a column on the left or without.
    expect(routeFitPadding(screen: phone, map: phone, coveredFoot: 380, coveredRight: 60), const EdgeInsets.fromLTRB(48, 120, 76, 396));
    expect(routeFitPadding(screen: wide, map: wide, coveredFoot: 74, coveredLeft: 392, coveredRight: 60), const EdgeInsets.fromLTRB(408, 120, 76, 90));
    // No room for both sides: the buttons are cleared, and the column gives way down to the least room for the route.
    expect(routeFitPadding(screen: narrow, map: narrow, coveredFoot: 74, coveredLeft: 392, coveredRight: 60), const EdgeInsets.fromLTRB(480 - 76 - kRouteFitLeast, 120, 76, 90));
    // Nothing shown at the foot to read: half the screen, at most 420, as before.
    expect(routeFitPadding(screen: const Size(800, 600), map: const Size(800, 600)).bottom, 300);
    expect(routeFitPadding(screen: const Size(1600, 1200), map: const Size(1600, 1200)).bottom, 420);
  });

  test('on a phone a route goes into the free rectangle that shows it larger: a tall one beside the position chip, a wide one under it', () {
    const map = Size(430, 932);
    const header = Rect.fromLTRB(12, 66, 418, 114), chip = Rect.fromLTRB(12, 124, 192, 179), buttons = Rect.fromLTRB(370, 124, 418, 232);
    // Drive: under the scale and the credits, the panel with one route and its elevation.
    const drive = MapCovers(
      header: header,
      chip: chip,
      buttons: buttons,
      scale: Rect.fromLTRB(12, 430, 120, 471),
      credits: Rect.fromLTRB(12, 477, 335, 505),
      panel: Rect.fromLTRB(12, 513, 418, 932),
    );
    // The strip: the whole width under the chip and the buttons, above the scale. The column: between the chip and the
    // buttons, from the header down to the credits (the scale is beside it, not under it). Each less the gap beside a cover
    // (16) and the wider room at a bare edge of the map (32: the strip's two sides).
    expect((kRouteFitGap, kRouteFitBareEdge), (16.0, 32.0));
    expect(freeMapRects(map, drive), (const Rect.fromLTRB(32, 248, 398, 414), const Rect.fromLTRB(208, 130, 354, 461)));
    expect(routeFitRect(map: map, covers: drive, spanX: 3, spanY: 1), const Rect.fromLTRB(32, 248, 398, 414), reason: 'a wide route takes the strip');
    expect(routeFitRect(map: map, covers: drive, spanX: 1, spanY: 3), const Rect.fromLTRB(208, 130, 354, 461), reason: 'a tall route takes the column');
    // Off-road: the panel is taller, and the strip between the buttons and the scale has no room left (its top is under its
    // foot). Every route goes into the column, which still has its room.
    const offroad = MapCovers(
      header: header,
      chip: chip,
      buttons: buttons,
      scale: Rect.fromLTRB(12, 257, 120, 298),
      credits: Rect.fromLTRB(12, 304, 335, 332),
      panel: Rect.fromLTRB(12, 340, 418, 932),
    );
    expect(freeMapRects(map, offroad), (const Rect.fromLTRB(32, 248, 398, 241), const Rect.fromLTRB(208, 130, 354, 288)));
    expect(routeFitRect(map: map, covers: offroad, spanX: 1, spanY: 3), const Rect.fromLTRB(208, 130, 354, 288));
    expect(routeFitRect(map: map, covers: offroad, spanX: 3, spanY: 1), const Rect.fromLTRB(208, 130, 354, 288));
    // A piece that is not shown takes no room. No position yet (no chip): the column starts at the map's left edge (a bare
    // edge now), where the scale is under it, and the strip starts under the buttons.
    const noChip = MapCovers(header: header, buttons: buttons, scale: Rect.fromLTRB(12, 430, 120, 471), credits: Rect.fromLTRB(12, 477, 335, 505), panel: Rect.fromLTRB(12, 513, 418, 932));
    expect(freeMapRects(map, noChip), (const Rect.fromLTRB(32, 248, 398, 414), const Rect.fromLTRB(32, 130, 354, 414)));
    // Neither chip nor buttons: both start under the header and run from one bare edge to the other.
    expect(freeMapRects(map, const MapCovers(header: header, panel: Rect.fromLTRB(12, 513, 418, 932))), (const Rect.fromLTRB(32, 130, 398, 497), const Rect.fromLTRB(32, 130, 398, 497)));
    // No scale and no credits: down to the panel. Nothing at the foot: down to the map's foot.
    expect(freeMapRects(map, const MapCovers(header: header, chip: chip, buttons: buttons, panel: Rect.fromLTRB(12, 513, 418, 932))).$2, const Rect.fromLTRB(208, 130, 354, 497));
    expect(freeMapRects(map, const MapCovers(header: header, chip: chip, buttons: buttons)), (const Rect.fromLTRB(32, 248, 398, 900), const Rect.fromLTRB(208, 130, 354, 900)));
    // Nothing over the map at all: the wider room on every side.
    expect(freeMapRects(map, const MapCovers()), (const Rect.fromLTRB(32, 32, 398, 900), const Rect.fromLTRB(32, 32, 398, 900)));
    // Credits that do not reach across to the column are beside it too: it goes down to the panel.
    expect(freeMapRects(map, const MapCovers(header: header, chip: chip, buttons: buttons, scale: Rect.fromLTRB(12, 430, 120, 471), credits: Rect.fromLTRB(12, 477, 47, 505), panel: Rect.fromLTRB(12, 513, 418, 932))).$2,
        const Rect.fromLTRB(208, 130, 354, 497));
    // No room in either (a short window with the panel over nearly all of it): the map still gets the least room to fit into
    // (with none it does not move at all), inside the map.
    const short = Size(430, 300);
    final least = routeFitRect(
      map: short,
      covers: const MapCovers(header: Rect.fromLTRB(12, 12, 418, 60), chip: Rect.fromLTRB(12, 70, 192, 125), buttons: Rect.fromLTRB(370, 70, 418, 178), panel: Rect.fromLTRB(12, 130, 418, 300)),
      spanX: 1,
      spanY: 1,
    );
    expect(math.min(least.width, least.height), greaterThanOrEqualTo(kRouteFitLeast));
    expect((Offset.zero & short).contains(least.topLeft) && least.right <= short.width && least.bottom <= short.height, isTrue);
  });

  testWidgets('from 800 wide the route is fitted clear of the column on the left, with no more room at the foot than is covered', (tester) async {
    await _withFittedRoute(tester, size: const Size(1200, 800), route: fakeRouteJson(id: 'fit-wide'), check: (fit, map) {
      // The column on the left: the header, and under it the panel.
      final sideRight = tester.getRect(find.byType(DirectionsHeader)).right;
      expect(tester.getRect(find.byType(RoutePanel)).right, sideRight);
      expect(sideRight, greaterThan(300), reason: 'the panel is not in a column on the left');
      expect(_fitPad(fit, 11), greaterThanOrEqualTo(sideRight), reason: 'the route may be under the column on the left');
      expect(_fitPad(fit, 11), sideRight + kRouteFitGap);
      // The foot: only the scale and the credits are there, so no more room is left than they cover (it used to be half the
      // window, as if the panel were at the foot).
      final covered = map.height - tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
      expect(covered, lessThan(200));
      expect(_fitPad(fit, 14), covered + kRouteFitGap);
      expect(_fitPad(fit, 12), kRouteFitTop);
    });
  });

  testWidgets('on a phone with Off-road chosen the route is fitted above the panel, the scale and the credits', (tester) async {
    // An off-road route on foot, with a stretch of open ground: the panel has the off-road choices and the off-road note.
    await _withFittedRoute(tester, size: const Size(390, 844), route: fakeRouteJson(id: 'fit-offroad', offroad: true, mode: 'offroad_foot'), check: (fit, map) {
      expect(find.byKey(const ValueKey('land-strict')), findsOneWidget, reason: 'Off-road is not chosen');
      final bottom = _fitPad(fit, 14);
      // The scale is the top of what covers the map's foot: under it the credits and the panel.
      final covered = map.height - tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
      expect(covered, greaterThan(420), reason: 'with Off-road chosen the panel covers more than the room the fit used to leave');
      // No position, so no chip: nothing is on the left, a bare edge of the map, and the route keeps the wider room from it.
      expect(bottom, greaterThanOrEqualTo(covered), reason: 'the route\'s lower end is under the panel or the credits');
      expect(_fitPad(fit, 11), kRouteFitBareEdge);
      expect(_fitPad(fit, 13), greaterThanOrEqualTo(kRouteFitGap));
      expect(_fitPad(fit, 12) + bottom, lessThan(map.height), reason: 'the fit leaves the map no room');
    });
  });

  // A phone with Off-road chosen and a position: over the map are the header, the position chip, the map's buttons, the scale,
  // the credits and the panel, and what is free is a strip above the scale and a column between the chip and the buttons.
  for (final tall in [true, false]) {
    testWidgets('on a phone with Off-road chosen a ${tall ? 'tall' : 'wide'} route is wholly in the free ${tall ? 'column beside the position chip' : 'strip above the scale'}, with nothing of it under what is over the map', (tester) async {
      final json = fakeRouteJson(id: tall ? 'fit-tall' : 'fit-across', offroad: true, mode: 'offroad_foot');
      // The tall one: the same route with its line turned to run north (as many points, so its parts still fit it).
      if (tall) json['geometry'] = encodePolyline6([for (var i = 0; i <= 40; i++) GeoPoint(42.5 + 0.02 * i / 40, -113.8 + 0.004 * math.sin(i / 40 * math.pi))]);
      final route = MapRoute.fromJson(json);
      // A position whose text is short: in a test every letter is a square as wide as the text is tall, and a longer position
      // would make the chip reach the buttons, with no column between them.
      await _withFittedRoute(tester, size: const Size(430, 932), route: json, position: fixAt(1, 2), check: (fit, map) {
        expect(find.byKey(const ValueKey('land-strict')), findsOneWidget, reason: 'Off-road is not chosen');
        final chip = tester.getRect(find.ancestor(of: find.text('1.00000, 2.00000'), matching: find.byType(Container)).first);
        final layers = tester.getRect(find.byType(MapButton).first), findMe = tester.getRect(find.byType(MapButton).last);
        final over = {
          'the header': tester.getRect(find.byType(DirectionsHeader)),
          'the position chip': chip,
          'the Layers button': layers,
          'the Find me button': findMe,
          'the scale': tester.getRect(find.byType(ScaleBarWidget)),
          'the credits': tester.getRect(find.byType(AttributionChip)),
          'the panel': tester.getRect(find.byType(RoutePanel)),
        };
        expect(chip.right, lessThan(layers.left - 2 * kRouteFitGap), reason: 'there is no column between the chip and the buttons to test');
        final box = _routeBoxOnMap(fit, route, map);
        expect(box.left >= 0 && box.top >= 0 && box.right <= map.width && box.bottom <= map.height, isTrue, reason: 'the route is not wholly on the map: $box');
        for (final MapEntry(key: name, value: rect) in over.entries) {
          expect(rect.overlaps(box.inflate(1)), isFalse, reason: 'part of the route ($box) is under $name ($rect)');
        }
        if (tall) {
          // Between the chip and the buttons, and reaching up beside them, where only the column is free.
          expect(box.left, greaterThanOrEqualTo(chip.right));
          expect(box.right, lessThanOrEqualTo(layers.left));
          expect(box.top, lessThan(chip.bottom), reason: 'the tall route is not in the column');
          expect(box.height, greaterThan(over['the scale']!.top - findMe.bottom), reason: 'the column does not show the tall route larger than the strip would');
        } else {
          // Under the chip and the buttons, wider than the column is, and the wider room in from the map's two bare edges.
          expect(box.top, greaterThanOrEqualTo(math.max(chip.bottom, findMe.bottom)));
          expect(box.width, greaterThan(layers.left - chip.right), reason: 'the wide route is not in the strip');
          // The phone is far from this route, so nothing is drawn at its west end. At its east end is the destination's pin,
          // and it is the pin's edge that is the bare-edge room in.
          expect(box.left, closeTo(kRouteFitBareEdge, 0.01), reason: 'the route\'s west end is not the bare-edge room in from the screen\'s side');
          expect(map.width - box.right, closeTo(kRouteFitBareEdge + kPinSelectedReach, 0.01), reason: 'the pin at the route\'s east end is not the bare-edge room in from the screen\'s side');
        }
      });
    });
  }

  // What the map draws at a route's ends is not on the route's line: the destination's pin reaches 15 points from its middle
  // and the position dot 11, or as far as its heading marker when the heading is known. The fit of the line alone left half of
  // each outside the free rectangle (a start under the header by part of its dot).
  test('a fit counts what is drawn at the route\'s ends: the pin and the position dot are wholly inside the free rectangle', () {
    const map = Size(430, 932);
    // The free column of the test above (Drive), as the room around it.
    const free = Rect.fromLTRB(208, 130, 354, 461);
    final room = EdgeInsets.fromLTRB(free.left, free.top, map.width - free.right, map.height - free.bottom);
    expect((kPinSelectedReach, kPositionDotReach), (15.0, 11.0));
    // The heading marker is the car's arrow (VehicleArrow): the farthest of its tip and its tails from the position, 21.2 points
    // on every screen (a picture drawn at the map's own density).
    expect(VehicleArrow.reach, closeTo(21.21, 0.01));

    // Where the disc of [m] falls on the map after [fit].
    Rect disc(({List<double> bounds, EdgeInsets padding}) fit, RouteEndMark m) {
      final b = fit.bounds;
      final cam = OverviewCamera.fit(south: b[0], west: b[1], north: b[2], east: b[3], size: map, padding: fit.padding);
      return Rect.fromCircle(center: cam.project(m.lat, m.lon), radius: m.reach);
    }

    bool inside(Rect outer, Rect inner) => inner.left >= outer.left - 0.01 && inner.top >= outer.top - 0.01 && inner.right <= outer.right + 0.01 && inner.bottom <= outer.bottom + 0.01;

    // A route that runs south from the phone, straight: the start is at the top of the column, under the header.
    const south = [42.48, -113.8, 42.5, -113.8];
    const dot = RouteEndMark(lat: 42.5, lon: -113.8, reach: 15.52), pin = RouteEndMark(lat: 42.48, lon: -113.8, reach: kPinSelectedReach);
    // The line alone: the dot's upper part is above the rectangle (it was under the header), the pin's lower part below it.
    final lineOnly = (bounds: south, padding: room);
    expect(disc(lineOnly, dot).top, closeTo(free.top - 15.52, 0.01));
    expect(disc(lineOnly, pin).bottom, closeTo(free.bottom + 15, 0.01));
    // Counted: each is inside, and touches the rectangle's edge, so no room is wasted.
    final fit = routeFitWithMarks(map: map, room: room, bounds: south, marks: const [pin, dot]);
    expect(fit.bounds, south);
    expect(inside(free, disc(fit, dot)) && inside(free, disc(fit, pin)), isTrue, reason: '${disc(fit, dot)} and ${disc(fit, pin)} in $free');
    expect(disc(fit, dot).top, closeTo(free.top, 0.01));
    expect(disc(fit, pin).bottom, closeTo(free.bottom, 0.01));
    expect(fit.padding.top - room.top, closeTo(15.52, 0.001));
    expect(fit.padding.bottom - room.bottom, closeTo(15, 0.001));

    // A route with a bend to the east: its ends are on the box's west edge and far from its east edge, which keeps no room.
    const bend = [42.48, -113.8, 42.5, -113.79];
    final bent = routeFitWithMarks(map: map, room: room, bounds: bend, marks: const [pin, dot]);
    expect(bent.padding.left - room.left, closeTo(15.52, 0.001));
    expect(bent.padding.right, room.right);
    expect(inside(free, disc(bent, dot)) && inside(free, disc(bent, pin)), isTrue);

    // The place is a little off the road the route ends on, and the phone a little off the road it starts on: the box grows to
    // hold both, and both are still wholly inside.
    const offDot = RouteEndMark(lat: 42.5004, lon: -113.8006, reach: 11), offPin = RouteEndMark(lat: 42.4797, lon: -113.7995, reach: kPinSelectedReach);
    final off = routeFitWithMarks(map: map, room: room, bounds: south, marks: const [offPin, offDot]);
    expect(off.bounds, [42.4797, -113.8006, 42.5004, -113.7995]);
    expect(inside(free, disc(off, offDot)) && inside(free, disc(off, offPin)), isTrue, reason: '${disc(off, offDot)} and ${disc(off, offPin)} in $free');

    // What the route's own fit does not show on the map is left out: the phone in another town, a place far from where its
    // route ends. The route is not made smaller to bring them in.
    const farDot = RouteEndMark(lat: 1, lon: 2, reach: 11), farPin = RouteEndMark(lat: 42.5, lon: -113.5, reach: kPinSelectedReach);
    final far = routeFitWithMarks(map: map, room: room, bounds: south, marks: const [farPin, farDot]);
    expect(far.bounds, south);
    expect(far.padding, room);
    // Nothing drawn at the ends: the fit of the line, as it was.
    final none = routeFitWithMarks(map: map, room: room, bounds: south, marks: const []);
    expect(none.bounds, south);
    expect(none.padding, room);

    // The least room a panel leaves (48 points each way): the marks give way, and the map still has a box of 24 points to fit.
    final tight = EdgeInsets.fromLTRB(100, 100, map.width - 148, map.height - 148);
    final least = routeFitWithMarks(map: map, room: tight, bounds: south, marks: const [pin, dot]);
    expect(map.width - least.padding.horizontal, closeTo(24, 0.01));
    expect(map.height - least.padding.vertical, closeTo(24, 0.01));
  });

  testWidgets('on a phone a route that runs south from the phone is fitted with the whole of its position dot under the header and the whole of its pin above the foot', (tester) async {
    // The phone is at 1, 2 (a position whose text is short, so there is a column between the chip and the buttons), heading
    // north, and the route runs straight south from it: its start is at the top of the column, where the header is.
    final json = fakeRouteJson(id: 'fit-ends');
    const start = GeoPoint(1, 2), end = GeoPoint(0.98, 2);
    json['geometry'] = encodePolyline6([for (var i = 0; i <= 40; i++) GeoPoint(start.lat + (end.lat - start.lat) * i / 40, start.lon)]);
    json['from'] = {...json['from'] as Map<String, dynamic>, 'lat': start.lat, 'lon': start.lon};
    json['to'] = {...json['to'] as Map<String, dynamic>, 'lat': end.lat, 'lon': end.lon};
    final route = MapRoute.fromJson(json);
    await _withFittedRoute(tester, size: const Size(430, 932), ratio: 3, route: json, position: fixAt(start.lat, start.lon, heading: 0), check: (fit, map) {
      final header = tester.getRect(find.byType(DirectionsHeader));
      final chip = tester.getRect(find.ancestor(of: find.text('1.00000, 2.00000'), matching: find.byType(Container)).first);
      final layers = tester.getRect(find.byType(MapButton).first), findMe = tester.getRect(find.byType(MapButton).last);
      final over = {
        'the header': header,
        'the position chip': chip,
        'the Layers button': layers,
        'the Find me button': findMe,
        'the scale': tester.getRect(find.byType(ScaleBarWidget)),
        'the credits': tester.getRect(find.byType(AttributionChip)),
        'the panel': tester.getRect(find.byType(RoutePanel)),
      };
      expect(chip.right, lessThan(layers.left - 2 * kRouteFitGap), reason: 'there is no column between the chip and the buttons to test');
      final cam = _cameraAfter(fit, map);
      // On this 3x phone the heading marker reaches further than the dot it turns around.
      final dotReach = VehicleArrow.reach;
      expect(dotReach, greaterThan(kPositionDotReach));
      final dot = Rect.fromCircle(center: cam.project(start.lat, start.lon), radius: dotReach);
      final pin = Rect.fromCircle(center: cam.project(end.lat, end.lon), radius: kPinSelectedReach);
      final box = _routeBoxOnMap(fit, route, map);
      expect(box.top, lessThan(chip.bottom), reason: 'the route is not in the column beside the chip');
      expect(box.height, greaterThan(4 * dotReach), reason: 'the column has too little room to test: $box');
      for (final MapEntry(key: what, value: disc) in {'the position dot with its heading marker': dot, 'the destination\'s pin': pin}.entries) {
        expect(disc.left >= 0 && disc.top >= 0 && disc.right <= map.width && disc.bottom <= map.height, isTrue, reason: '$what is not wholly on the map: $disc');
        for (final MapEntry(key: name, value: rect) in over.entries) {
          // Clear of it, and by the gap a fitted route keeps from what covers the map (less a rounding).
          expect(rect.inflate(kRouteFitGap - 0.5).overlaps(disc), isFalse, reason: '$what ($disc) is under $name ($rect), or nearer to it than the gap');
        }
      }
      // The start's dot is exactly the gap under the header. (Fitted by its line alone, the route's start was there, and the
      // upper part of the dot above it.)
      expect(dot.top, closeTo(header.bottom + kRouteFitGap, 0.01));
      expect(box.top, closeTo(header.bottom + kRouteFitGap + dotReach, 0.01));
      expect(dot.left, greaterThanOrEqualTo(chip.right + kRouteFitGap - 0.01), reason: 'the dot touches the position chip');
    });
  });

  testWidgets('from 800 wide the route is fitted clear of the map\'s buttons on the right', (tester) async {
    await _withFittedRoute(tester, size: const Size(1200, 800), route: fakeRouteJson(id: 'fit-buttons'), check: (fit, map) {
      // Layers and Find me, one under the other at the map's right edge: how far in they reach.
      final buttons = map.width - tester.getRect(find.byType(MapButton).first).left;
      expect(tester.getRect(find.byType(MapButton).last).left, tester.getRect(find.byType(MapButton).first).left);
      expect(buttons, greaterThan(kRouteFitSide), reason: 'the buttons reach further in than the room the fit used to leave on the right');
      expect(_fitPad(fit, 13), greaterThanOrEqualTo(buttons), reason: 'an end of the route may be under the map\'s buttons');
      expect(_fitPad(fit, 13), buttons + kRouteFitGap);
    });
  });

  for (final withFix in [true, false]) {
    testWidgets(
      withFix
          ? 'Maps opens on the phone position, not the remembered view, and the search box searches there'
          : 'with no position yet, Maps opens on the remembered view and the search box searches there',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('open-camera-');
        final originalPlatform = MapLibrePlatform.createInstance;
        MapLibrePlatform.createInstance = () => NoSurface();
        final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
        final engine = TestLayerEngine();
        final maps = MapsState(engine: engine, settingsDirOverride: dir);
        final backend = FakeBackend();
        final nav = NavState(
          backend: backend,
          location: location,
          speaker: FakeSpeaker(),
          positionSource: FakeNavPosition(),
          fmt: const Fmt(UnitSystem.imperial),
        );
        GeoPoint? searchedNear;
        backend.onSearch = (q, {near, meaning}) async {
          searchedNear = near;
          return MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: const []);
        };
        try {
          await tester.runAsync(() async {
            await location.init();
            await engine.start();
          });
          // The view left on Idaho Falls last time; the phone is near Twin Falls.
          maps.savedCamera = SavedCamera(43.49, -112.03, 12);
          if (withFix) location.publish(fixAt(42.574, -114.607));
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(CacheThemeId.dark),
              home: MapsScreen(
                location: location,
                maps: maps,
                nav: nav,
                themeId: CacheThemeId.dark,
                glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
              ),
            ),
          );
          await tester.pump();
          // The map's first camera and the search box's centre are the same point (the screen's centre before any move).
          final (lat, lon) = withFix ? (42.574, -114.607) : (43.49, -112.03);
          expect((nav.mapCentre?.lat, nav.mapCentre?.lon), (lat, lon));
          // "Maverik" is searched around the map's centre: the phone's position when it is known.
          nav.onQueryChanged('Maverik');
          await tester.runAsync(() => nav.submitSearch());
          expect((searchedNear?.lat, searchedNear?.lon), (lat, lon));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          MapLibrePlatform.createInstance = originalPlatform;
          nav.dispose();
          maps.dispose();
          location.dispose();
          await tester.runAsync(() => dir.delete(recursive: true));
        }
      },
    );
  }
}

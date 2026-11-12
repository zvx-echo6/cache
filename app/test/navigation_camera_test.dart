import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/ui/map_widgets.dart' show ScaleBarWidget;
import 'package:cache/nav/nav_state.dart';
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
        final foot = tester.getSize(find.byType(MapLibreMap)).height - tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
        expect(camera.cameras, [
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(bounds[0], bounds[1]),
              northeast: LatLng(bounds[2], bounds[3]),
            ),
            left: sideRight + kRouteFitGap,
            right: 48,
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
    // A phone: at the foot what the scale, the credits and the panel cover, and a gap; the other edges as they are.
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
    // Nothing shown at the foot to read: half the screen, at most 420, as before.
    expect(routeFitPadding(screen: const Size(800, 600), map: const Size(800, 600)).bottom, 300);
    expect(routeFitPadding(screen: const Size(1600, 1200), map: const Size(1600, 1200)).bottom, 420);
  });

  testWidgets('from 800 wide the route is fitted clear of the column on the left, with no more room at the foot than is covered', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The style template is read afresh (see the phone test below).
    rootBundle.clear();
    final dir = Directory.systemTemp.createTempSync('route-fit-wide-');
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
      expect(nav.previewSnapshot(MapRoute.fromJson(fakeRouteJson(id: 'fit-wide'))), isTrue);
      for (var i = 0; i < 100 && _fitsOf(camera).isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      final fits = _fitsOf(camera);
      expect(fits, isNotEmpty, reason: 'the route was not fitted into view');
      final size = tester.getSize(find.byType(MapLibreMap));
      // The column on the left: the header, and under it the panel.
      final sideRight = tester.getRect(find.byType(DirectionsHeader)).right;
      expect(tester.getRect(find.byType(RoutePanel)).right, sideRight);
      expect(sideRight, greaterThan(300), reason: 'the panel is not in a column on the left');
      expect(_fitPad(fits.last, 11), greaterThanOrEqualTo(sideRight), reason: 'the route may be under the column on the left');
      expect(_fitPad(fits.last, 11), sideRight + kRouteFitGap);
      // The foot: only the scale and the credits are there, so no more room is left than they cover (it used to be half the
      // window, as if the panel were at the foot).
      final covered = size.height - tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
      expect(covered, lessThan(200));
      expect(_fitPad(fits.last, 14), covered + kRouteFitGap);
      expect(_fitPad(fits.last, 13), kRouteFitSide);
      expect(_fitPad(fits.last, 12), kRouteFitTop);
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

  testWidgets('on a phone with Off-road chosen the route is fitted above the panel, the scale and the credits', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // The style template is read through the asset bundle, which keeps the read the test above started (it never finishes in
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
      // An off-road route on foot, with a stretch of open ground: the panel has the off-road choices and the off-road note.
      expect(nav.previewSnapshot(MapRoute.fromJson(fakeRouteJson(id: 'fit-offroad', offroad: true, mode: 'offroad_foot'))), isTrue);
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
      expect(find.byKey(const ValueKey('land-strict')), findsOneWidget, reason: 'Off-road is not chosen');
      final fits = _fitsOf(camera);
      expect(fits, isNotEmpty, reason: 'the route was not fitted into view');
      final bottom = _fitPad(fits.last, 14);
      // No column on the left on a phone: the sides are as they were.
      expect((_fitPad(fits.last, 11), _fitPad(fits.last, 13)), (kRouteFitSide, kRouteFitSide));
      final height = tester.getSize(find.byType(MapLibreMap)).height;
      // The scale is the top of what covers the map's foot: under it the credits and the panel.
      final covered = height - tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
      expect(covered, greaterThan(420), reason: 'with Off-road chosen the panel covers more than the room the fit used to leave');
      expect(bottom, greaterThanOrEqualTo(covered), reason: 'the route\'s lower end is under the panel or the credits');
      expect(kRouteFitTop + bottom, lessThan(height), reason: 'the fit leaves the map no room');
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

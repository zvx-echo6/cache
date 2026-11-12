import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/ui/map_widgets.dart' show ScaleBarWidget;
import 'package:cache/nav/nav_state.dart';
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
        expect(camera.cameras, [
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(bounds[0], bounds[1]),
              northeast: LatLng(bounds[2], bounds[3]),
            ),
            left: 48,
            right: 48,
            top: 120,
            bottom: 300,
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

  test('the room under a fitted route is what covers the map\'s foot, and the map keeps room for the route', () {
    // The panel in the side column (nothing covers the map's foot): half the screen, at most 420, as before.
    expect(routeFitBottom(screen: 600, map: 600, covered: null), 300);
    expect(routeFitBottom(screen: 1200, map: 1200, covered: null), 420);
    // On a phone: what the scale, the credits and the panel cover, and a gap.
    expect(routeFitBottom(screen: 844, map: 844, covered: 380), 380 + kRouteFitGap);
    expect(routeFitBottom(screen: 844, map: 844, covered: 582), 582 + kRouteFitGap);
    // A cover that leaves no room: the map keeps the least room for the route (with no room at all it would not move).
    expect(routeFitBottom(screen: 400, map: 400, covered: 390), 400 - kRouteFitTop - kRouteFitLeast);
    expect(kRouteFitTop + routeFitBottom(screen: 400, map: 400, covered: 390), lessThan(400));
    expect(routeFitBottom(screen: 100, map: 100, covered: 90), 0);
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
    // Where the map package keeps the bottom padding of a fit, read from its own encoding of a known one.
    final bottomAt = (CameraUpdate.newLatLngBounds(LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(1, 1)), left: 11, top: 12, right: 13, bottom: 14).toJson() as List<dynamic>).indexOf(14.0);
    expect(bottomAt, greaterThan(0));
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
      List<List<dynamic>> fitsOf() => camera.cameras.cast<List<dynamic>>().where((u) => u.first == 'newLatLngBounds').toList();
      for (var i = 0; i < 100 && fitsOf().isEmpty; i++) {
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
      final fits = fitsOf();
      expect(fits, isNotEmpty, reason: 'the route was not fitted into view');
      final bottom = (fits.last[bottomAt] as num).toDouble();
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

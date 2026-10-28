import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
}

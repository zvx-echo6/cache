// Turn-by-turn guidance on the Maps screen for the owner to review (the tester's report: the screen dimmed, the position sat too
// high, the turn banner was too big): a phone upright (390 x 844) and sideways (844 x 390) and a computer window (1440 x 900), in
// the light and the dark theme. The map itself is a platform view and is not drawn; the round marker shows where the camera puts
// the phone's position (worked out here from the camera the screen asked for, with a line across the middle for reference).
// flutter test test_shots/guidance_renders_test.dart --update-goldens  (pictures in test_shots/guidance/)

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/support/test_layer_engine.dart';
import 'shot_kit.dart';

const _out = 'guidance';

/// Where ([lat], [lon]) falls on a map of [map] size for a camera centred on [c] (MapLibre draws the world 512 pixels wide at
/// zoom 0). Kept here so the same test draws the screens before and after the change.
Offset _onScreen(double lat, double lon, Map<String, dynamic> c, Size map) {
  final t = (c['target'] as List).cast<num>();
  final zoom = (c['zoom'] as num).toDouble();
  final b = (c['bearing'] as num).toDouble() * math.pi / 180;
  final mpp = 2 * math.pi * 6378137 * math.cos(lat * math.pi / 180) / (512 * math.pow(2, zoom));
  final north = (t[0] - lat) * 111320;
  final east = (t[1] - lon) * 111320 * math.cos(lat * math.pi / 180);
  final up = north * math.cos(b) + east * math.sin(b);
  final right = -north * math.sin(b) + east * math.cos(b);
  return Offset(map.width / 2 - right / mpp, map.height / 2 + up / mpp);
}

class _Marker extends StatelessWidget {
  const _Marker(this.at);
  final ValueNotifier<Offset?> at;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ValueListenableBuilder<Offset?>(
          valueListenable: at,
          builder: (context, p, _) => LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                // The middle of the map, for reference.
                Positioned(left: 0, right: 0, top: box.maxHeight / 2, child: Container(height: 1, color: const Color(0x667F7F7F))),
                if (p != null)
                  Positioned(
                    left: p.dx - 14,
                    top: p.dy - 14,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF1A73E8), border: Border.all(color: Colors.white, width: 3)),
                      child: const Icon(Icons.navigation, size: 16, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

Future<void> _guidance(WidgetTester tester, {required String name, required Size size, required double ratio, required EdgeInsets insets, required CacheThemeId theme}) async {
  phone(tester, size: size, ratio: ratio);
  // The style's template is read through the asset bundle, which keeps what an earlier picture read; read afresh for each one
  // (a read left over from an earlier test never finishes in this one).
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('guidance-renders-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final route = fakeRouteJson(name: 'Shoshone Falls Park');
  final backend = FakeBackend()
    ..onRoute = ((to, mode, from) async => MapRoute.fromJson(route))
    ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.3)));
  final gps = FakeNavPosition();
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
  final camera = CameraController();
  final marker = ValueNotifier<Offset?>(null);
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(shotApp(
      Stack(children: [
        Positioned.fill(
          child: MapsScreen(location: location, maps: maps, nav: nav, themeId: theme, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
        ),
        Positioned.fill(child: _Marker(marker)),
      ]),
      theme: theme,
      insets: insets,
    ));
    // The screen builds its map once the style is ready (as the guide's pictures wait for it).
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    location.publish(fixAt(42.5629, -114.4609, heading: 90));
    await tester.runAsync(() async {
      await nav.openDirections(const MapPlace(id: 'place:osm:w7', type: 'place', name: 'Shoshone Falls Park', kind: 'Park', address: 'Twin Falls, ID', lat: 42.5944, lon: -114.4003, matched: 'name'));
      await nav.start();
      gps.controller.add(fixAt(42.5629, -114.4609, heading: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final last = camera.cameras.lastWhere((c) => (c as List).first == 'newCameraPosition') as List;
    marker.value = _onScreen(42.5629, -114.4609, (last[1] as Map).cast<String, dynamic>(), tester.getSize(find.byType(MapLibreMap)));
    await tester.pump();
    await snap(tester, _out, '$name-${theme == CacheThemeId.light ? 'light' : 'dark'}');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    marker.dispose();
    camera.dispose();
    nav.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
  });

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('guidance, phone upright, ${theme.name}', (tester) async {
      await _guidance(tester, name: 'phone-390-portrait', size: const Size(390, 844), ratio: 3, insets: const EdgeInsets.only(top: 47, bottom: 34), theme: theme);
    });
    testWidgets('guidance, phone sideways, ${theme.name}', (tester) async {
      await _guidance(tester, name: 'phone-390-landscape', size: const Size(844, 390), ratio: 3, insets: const EdgeInsets.only(left: 47, right: 47, bottom: 21), theme: theme);
    });
    testWidgets('guidance, computer window, ${theme.name}', (tester) async {
      await _guidance(tester, name: 'desktop-1440', size: const Size(1440, 900), ratio: 2, insets: EdgeInsets.zero, theme: theme);
    });
  }
}

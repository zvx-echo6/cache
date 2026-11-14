// The phone's guidance map with the car's arrow as the position marker (VehicleArrow), at a phone's width (390 x 844), in all four
// themes, and a frame with no heading ever known, where the position is the dot.
//   arrow-390-{light,dark,tactical,parchment}.png   guiding, heading known: the arrow, in the theme's position colour with the
//                                                   position ring as its outline, turned by the heading
//   dot-390-light.png                               guiding with no heading ever known: the dot (the car's rule)
//
// The live map is a platform view and is not drawn in a test. In its place a stand-in is drawn from what the screen gives the map:
// the camera it asked for (guidance: map turned to the heading, position low on the screen), the route, the arrow's own image
// (the PNG the screen adds to the style, drawn at the 3x phone's scale), turned as the style turns it (the heading less the map's
// bearing), and the dot when the position feature the screen sets has no heading (the style's filter, tested in
// test/vehicle_arrow_test.dart). Roads and labels are not drawn: the guide's own pictures have the real map.
// flutter test test_shots/phone_arrow_renders_test.dart --update-goldens  (pictures in test_shots/phone_arrow/)

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart' show kHeadingImage, kPositionDotEdge, kPositionDotRadius, kPositionSource;
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

import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import '../test/navigation_camera_test.dart' show NoSurface;
import '../test/support/test_layer_engine.dart';
import 'guide_map_kit.dart' show GuideCamera, GuideMapController;
import 'shot_kit.dart';

const _out = 'phone_arrow';
const double _ratio = 3;

class _Scene {
  const _Scene({required this.route, required this.camera, required this.position, required this.heading, required this.arrow});
  final MapRoute route;
  final GuideCamera camera;
  final ({double lat, double lon}) position;

  /// The position feature's heading: null when it has none (the style then shows the dot).
  final double? heading;
  final ui.Image arrow;
}

class _Surface extends NoSurface {
  _Surface(this.scene, this.palette);
  final ValueListenable<_Scene?> scene;
  final MapPalette palette;

  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) =>
      ValueListenableBuilder<_Scene?>(valueListenable: scene, builder: (context, s, _) => SizedBox.expand(child: CustomPaint(painter: _Painter(s, palette))));
}

class _Painter extends CustomPainter {
  _Painter(this.scene, this.palette);
  final _Scene? scene;
  final MapPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette['land']);
    final s = scene;
    if (s == null) return;
    final pts = [for (final p in s.route.points) s.camera.project(p.lat, p.lon, size)];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    for (final (w, c) in [(9.0, palette['routeCasing']), (6.0, palette['route'])]) {
      canvas.drawPath(path, Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = w..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    }
    final at = s.camera.project(s.position.lat, s.position.lon, size);
    if (s.heading == null) {
      canvas.drawCircle(at, kPositionDotRadius + kPositionDotEdge + 0.0, Paint()..color = palette['positionRing']);
      canvas.drawCircle(at, kPositionDotRadius + 0.0, Paint()..color = palette['position']);
      return;
    }
    // The style turns the image with the map (icon-rotate: heading, rotation-alignment: map), so on the screen it is the heading
    // less the map's bearing. The image's middle is the position; its pixels are the screen's (3 to a point).
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate((s.heading! - s.camera.bearing) * math.pi / 180);
    canvas.scale(1 / _ratio);
    canvas.drawImage(s.arrow, Offset(-s.arrow.width / 2, -s.arrow.height / 2), Paint()..filterQuality = FilterQuality.none);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Painter old) => old.scene != scene;
}

/// A drive east that bends north: where the phone is (a third of the way along) the road runs a little north of east.
final List<GeoPoint> _road = [for (var i = 0; i <= 40; i++) GeoPoint(42.5 + 0.012 * math.pow(i / 40, 3), -113.8 + 0.06 * i / 40)];
const int _at = 28;

/// The way the road runs at [_at], degrees clockwise from north.
double get _roadHeading {
  final a = _road[_at], b = _road[_at + 1];
  final north = (b.lat - a.lat) * 111320;
  final east = (b.lon - a.lon) * 111320 * math.cos(a.lat * math.pi / 180);
  return math.atan2(east, north) * 180 / math.pi;
}

Future<void> _guidance(WidgetTester tester, CacheThemeId theme, {required String name, required bool heading}) async {
  phone(tester, size: const Size(390, 844), ratio: _ratio);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('phone-arrow-renders-');
  final originalPlatform = MapLibrePlatform.createInstance;
  final scene = ValueNotifier<_Scene?>(null);
  MapLibrePlatform.createInstance = () => _Surface(scene, mapPaletteFor(theme));
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final routeJson = {...fakeRouteJson(name: 'Shoshone Falls Park'), 'geometry': encodePolyline6(_road)};
  final backend = FakeBackend()
    ..onRoute = ((to, mode, from) async => MapRoute.fromJson(routeJson))
    ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(routeJson, 0.3)));
  final gps = FakeNavPosition();
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
  final camera = GuideMapController();
  final lat = _road[_at].lat, lon = _road[_at].lon;
  final fixHeading = heading ? _roadHeading : null;
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(shotApp(
      MapsScreen(location: location, maps: maps, nav: nav, themeId: theme, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
      theme: theme,
      insets: const EdgeInsets.only(top: 47, bottom: 34),
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    location.publish(fixAt(lat, lon, heading: fixHeading));
    await tester.runAsync(() async {
      await nav.openDirections(MapPlace(id: 'place:osm:w7', type: 'place', name: 'Shoshone Falls Park', kind: 'Park', address: 'Twin Falls, ID', lat: _road.last.lat, lon: _road.last.lon, matched: 'name'));
      await nav.start();
      gps.controller.add(fixAt(lat, lon, heading: fixHeading));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // What the screen put on the map: the position it set, the image it added, the camera it asked for.
    final features = (camera.sources[kPositionSource]!['features'] as List).cast<Map<String, dynamic>>();
    final point = features.singleWhere((f) => (f['geometry'] as Map)['type'] == 'Point');
    final shown = (point['properties'] as Map)['heading'] as num?;
    expect(shown?.toDouble(), fixHeading, reason: 'the screen gave the position a heading of its own');
    final png = camera.images[kHeadingImage];
    expect(png, isNotNull, reason: 'the screen added no arrow image');
    final decoded = (await tester.runAsync(() async => (await (await ui.instantiateImageCodec(png!)).getNextFrame()).image))!;
    expect((decoded.width, decoded.height), (94, 118), reason: '30 x 38 points at 3 pixels per point, and 2 pixels all round');
    final size = tester.getSize(find.byType(MapLibreMap));
    final last = camera.cameras.cast<List<dynamic>>().lastWhere((c) => c.first == 'newCameraPosition');
    final cam = const GuideCamera(lat: 0, lon: 0, zoom: 0).after(last, size);
    scene.value = _Scene(route: nav.route!, camera: cam, position: (lat: lat, lon: lon), heading: shown?.toDouble(), arrow: decoded);
    await tester.pump();
    await snap(tester, _out, name);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    scene.dispose();
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

  for (final theme in CacheThemeId.values) {
    testWidgets('guidance with a heading, ${theme.name}: the car\'s arrow', (tester) async {
      await _guidance(tester, theme, name: 'arrow-390-${theme.name}', heading: true);
    });
  }
  testWidgets('guidance with no heading ever known: the dot', (tester) async {
    await _guidance(tester, CacheThemeId.light, name: 'dot-390-light', heading: false);
  });
}

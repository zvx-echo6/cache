// The elevation profile and the route mini map (docs: the approved navigation mockups) for the owner to review: guidance with the
// mini map, swapped, the elevation panel pulled up, no elevation data, part of the route without data, and the route preview; a
// phone upright (390 x 844) and sideways (844 x 390) and a computer window (1440 x 900), light and dark.
//
// The live map is a platform view and is not drawn in a test (it shows as the empty background, as in the other guidance renders).
// The whole-route picture is MapLibre's offscreen snapshot on a device; here a stand-in is drawn in its place from the same camera
// (the land colour, a road grid, the route and its ends), so the picture's place, size and dot can be checked.
// flutter test test_shots/nav_elevation_renders_test.dart --update-goldens  (pictures in test_shots/nav_elevation/)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
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
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/support/test_layer_engine.dart';
import 'shot_kit.dart';

const _out = 'nav_elevation';

/// The mockup's sample profile (feet at miles), stretched over the fake route.
const _nodes = [(0.0, 4820.0), (1.2, 4700.0), (2.4, 4610.0), (3.4, 4780.0), (4.2, 5130.0), (5.2, 5350.0), (6.4, 5200.0), (7.6, 5470.0), (8.6, 5700.0), (9.8, 5350.0), (11.2, 5080.0)];

ElevationProfile _profile(double totalM, {bool gap = false}) {
  double feetAt(double mi) {
    for (var i = 1; i < _nodes.length; i++) {
      final (a, ea) = _nodes[i - 1];
      final (b, eb) = _nodes[i];
      if (mi <= b) {
        final t = (1 - math.cos(math.pi * (mi - a) / (b - a))) / 2;
        return ea + (eb - ea) * t;
      }
    }
    return _nodes.last.$2;
  }

  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= totalM; x += kProfileStepM) {
    d.add(x);
    final mi = x / totalM * 11.2;
    e.add(gap && mi > 6.6 && mi < 7.9 ? double.nan : feetAt(mi) / 3.28084);
  }
  return ElevationProfile.fromSamples(d, e, totalM: totalM);
}

/// Hands out stand-in pictures when the test says (they are drawn outside the test's fake clock).
class _StandInSnapshotter implements RouteSnapshotter {
  _StandInSnapshotter(this.route, this.palette);
  final MapRoute route;
  final MapPalette palette;
  final List<(OverviewCamera, double, Completer<OverviewPicture?>)> pending = [];

  @override
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio}) {
    final c = Completer<OverviewPicture?>();
    pending.add((camera, pixelRatio, c));
    return c.future;
  }

  Future<void> fulfil() async {
    final todo = [...pending];
    pending.clear();
    for (final (cam, ratio, c) in todo) {
      c.complete(OverviewPicture(image: await _draw(cam, ratio), camera: cam, pixelRatio: ratio, renderMs: 0));
    }
  }

  Future<ui.Image> _draw(OverviewCamera cam, double ratio) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(ratio);
    final size = cam.size;
    canvas.drawRect(Offset.zero & size, Paint()..color = palette['land']);
    final minor = Paint()
      ..color = palette['roadMinor']
      ..strokeWidth = 1.5;
    for (var x = size.width * 0.12; x < size.width; x += size.width * 0.27) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), minor);
    }
    for (var y = size.height * 0.1; y < size.height; y += size.height * 0.23) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), minor);
    }
    final pts = [for (final p in route.points) cam.project(p.lat, p.lon)];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    final w = size.width < 200 ? 4.0 : 6.0;
    canvas.drawPath(path, Paint()
      ..color = palette['routeCasing']
      ..style = PaintingStyle.stroke
      ..strokeWidth = w + 3
      ..strokeCap = StrokeCap.round);
    canvas.drawPath(path, Paint()
      ..color = palette['route']
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round);
    canvas.drawCircle(pts.first, w + 1, Paint()..color = palette['land']);
    canvas.drawCircle(pts.first, w + 1, Paint()
      ..color = palette['route']
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);
    canvas.drawCircle(pts.last, w + 3, Paint()..color = palette['pin']);
    return rec.endRecording().toImage((size.width * ratio).round(), (size.height * ratio).round());
  }
}

enum _Frame { guidance, swapped, elevation, noData, partial, preview }

Future<void> _frame(WidgetTester tester, {required _Frame frame, required String size, required Size screen, required double ratio, required EdgeInsets insets, required CacheThemeId theme}) async {
  phone(tester, size: screen, ratio: ratio);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('nav-elevation-renders-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  final json = fakeRouteJson(name: 'Pine Hollow Trailhead');
  final route = MapRoute.fromJson(json);
  final backend = FakeBackend()
    ..onRoute = ((to, mode, from) async => MapRoute.fromJson(json))
    ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(json, 2.9 / 11.2)));
  final gps = FakeNavPosition();
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
  final profile = switch (frame) {
    _Frame.noData => ElevationProfile.none(route.distanceM),
    _Frame.partial => _profile(route.distanceM, gap: true),
    _ => _profile(route.distanceM),
  };
  final elevation = RouteElevation(loader: (r) async => profile);
  final snapshots = _StandInSnapshotter(route, mapPaletteFor(theme));
  final camera = CameraController();
  final along = route.points[(route.points.length * 2.9 / 11.2).round()];
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(shotApp(
      MapsScreen(
        location: location,
        maps: maps,
        nav: nav,
        themeId: theme,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: elevation,
        snapshotter: snapshots,
      ),
      theme: theme,
      insets: insets,
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    location.publish(fixAt(along.lat, along.lon, heading: 70));
    await tester.runAsync(() async {
      await nav.openDirections(const MapPlace(id: 'place:osm:n4', type: 'place', name: 'Pine Hollow Trailhead', kind: 'Park', address: '', lat: 42.5, lon: -113.5, matched: 'name'));
      if (frame != _Frame.preview) {
        await nav.start();
        gps.controller.add(fixAt(along.lat, along.lon, heading: 70));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(snapshots.fulfil);
      }
    }

    await settle();
    if (frame == _Frame.swapped) {
      await tester.tap(find.byKey(const ValueKey('route-inset')));
      await settle();
    }
    if (frame == _Frame.elevation || frame == _Frame.noData || frame == _Frame.partial) {
      elevation.setOpen(true);
      await settle();
    }
    await snap(tester, _out, '${frame.name}-$size-${theme == CacheThemeId.light ? 'light' : 'dark'}');
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

void main() {
  setUpAll(() async {
    await loadShotFonts();
  });

  const sizes = [
    ('phone-390', Size(390, 844), 3.0, EdgeInsets.only(top: 47, bottom: 34)),
    ('phone-844x390', Size(844, 390), 3.0, EdgeInsets.only(left: 47, right: 47, bottom: 21)),
    ('desktop-1440', Size(1440, 900), 2.0, EdgeInsets.zero),
  ];
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    for (final (name, screen, ratio, insets) in sizes) {
      for (final frame in _Frame.values) {
        testWidgets('${frame.name}, $name, ${theme.name}', (tester) async {
          await _frame(tester, frame: frame, size: name, screen: screen, ratio: ratio, insets: insets, theme: theme);
        });
      }
    }
  }
}

// Two faults of the map screens after their fixes, at a phone's width (390 x 844), light and dark, for review:
//   offroad-fit-390-*        Off-road chosen: the route the screen fitted into view ends above the scale, the credits and the panel
//   offroad-panel-end-390-*  the same screen with the panel's choices scrolled to their end: the off-road note in full above Start
//   measure-bar-390-*        the measuring bar with its hint in full
//
// The live map is a platform view and is not drawn in a test. In its place a stand-in is drawn from the camera the screen asked
// for (the land colour, the route and its ends) with the same web-mercator fit the map makes (GuideCamera, guide_map_kit.dart), so
// where the fitted route falls on the screen can be seen. The guide's own pictures have the real map (tools/guide/README.md).
// flutter test test_shots/map_faults_renders_test.dart --update-goldens  (pictures in test_shots/map_faults/)

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/ui/map_widgets.dart' show ScaleBarWidget;
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
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
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/support/test_layer_engine.dart';
import 'guide_map_kit.dart' show GuideCamera;
import 'shot_kit.dart';

const _out = 'map_faults';

/// What the stand-in map shows: the route, seen by the camera the screen last fitted it with.
class _View {
  const _View(this.route, this.camera);
  final MapRoute route;
  final GuideCamera camera;
}

/// The map's place on the screen: the land colour, and the route where the camera puts it.
class _RouteSurface extends NoSurface {
  _RouteSurface(this.view, this.palette);

  final ValueListenable<_View?> view;
  final MapPalette palette;

  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) =>
      ValueListenableBuilder<_View?>(
        valueListenable: view,
        builder: (context, v, _) => SizedBox.expand(child: CustomPaint(painter: _RoutePainter(v, palette))),
      );
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.view, this.palette);

  final _View? view;
  final MapPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette['land']);
    final v = view;
    if (v == null) return;
    final pts = [for (final p in v.route.points) v.camera.project(p.lat, p.lon, size)];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = palette['routeCasing']
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round);
    canvas.drawPath(
        path,
        Paint()
          ..color = palette['route']
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(pts.first, 7, Paint()..color = palette['land']);
    canvas.drawCircle(
        pts.first,
        7,
        Paint()
          ..color = palette['route']
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    canvas.drawCircle(pts.last, 9, Paint()..color = palette['pin']);
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.view != view;
}

/// The Maps screen with Off-road chosen and a route on foot, its elevation read: first as the screen fitted the route into view,
/// then with the panel's choices scrolled to their end.
Future<void> _offroad(WidgetTester tester, CacheThemeId theme) async {
  phone(tester, size: const Size(390, 844), ratio: 3);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('map-faults-renders-');
  final originalPlatform = MapLibrePlatform.createInstance;
  final view = ValueNotifier<_View?>(null);
  MapLibrePlatform.createInstance = () => _RouteSurface(view, mapPaletteFor(theme));
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  // A walk north with a bend: taller than it is wide, so its lower end comes down to what covers the map's foot.
  final pts = [for (var i = 0; i <= 40; i++) GeoPoint(42.5 + 0.02 * i / 40, -113.8 + 0.004 * math.sin(i / 40 * math.pi))];
  final json = {...fakeRouteJson(id: 'faults-offroad', offroad: true, mode: 'offroad_foot', name: 'Pine Hollow Trailhead'), 'geometry': encodePolyline6(pts)};
  final route = MapRoute.fromJson(json);
  final backend = FakeBackend()..onRoute = ((to, mode, from) async => MapRoute.fromJson(json));
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial), onFollow: maps.setFollow);
  final total = route.distanceM;
  final dist = [for (var x = 0.0; x <= total; x += kProfileStepM) x];
  final elevation = RouteElevation(loader: (r) async => ElevationProfile.fromSamples(dist, [for (final x in dist) 1560 + 30 * x / total], totalM: total));
  final camera = CameraController();
  final name = theme == CacheThemeId.light ? 'light' : 'dark';
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(shotApp(
      MapsScreen(location: location, maps: maps, nav: nav, themeId: theme, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf', elevation: elevation),
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
    location.publish(fixAt(pts.first.lat, pts.first.lon, heading: 0));
    await tester.runAsync(() async {
      await nav.setMode('offroad_foot');
      await nav.openDirections(MapPlace(id: 'place:osm:n4', type: 'place', name: 'Pine Hollow Trailhead', kind: 'Park', address: '', lat: pts.last.lat, lon: pts.last.lon, matched: 'name'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
    }

    await settle();
    expect(find.byKey(const ValueKey('land-strict')), findsOneWidget, reason: 'Off-road is not chosen');
    expect(find.byKey(const ValueKey('preview-elevation-chart')), findsOneWidget, reason: 'the elevation chart is not shown');

    // The map as the screen's last fit leaves it.
    final size = tester.getSize(find.byType(MapLibreMap));
    final fits = camera.cameras.cast<List<dynamic>>().where((u) => u.first == 'newLatLngBounds').toList();
    expect(fits, isNotEmpty, reason: 'the screen did not fit the route into view');
    final cam = const GuideCamera(lat: 0, lon: 0, zoom: 0).after(fits.last, size);
    view.value = _View(route, cam);
    // The screen is told the camera the map has, as the map tells it (the scale bar follows it).
    map.onCameraMove!(CameraPosition(target: LatLng(cam.lat, cam.lon), zoom: cam.zoom));
    await tester.pump();
    // Both ends of the route are on the map above the scale (under the scale: the credits and the panel).
    final coverTop = tester.getTopLeft(find.byType(ScaleBarWidget)).dy;
    for (final p in [route.points.first, route.points.last]) {
      final at = cam.project(p.lat, p.lon, size);
      expect(at.dy, lessThan(coverTop), reason: 'an end of the route is under what covers the map\'s foot');
      expect(at.dy, greaterThan(0), reason: 'an end of the route is above the screen');
    }
    await snap(tester, _out, 'offroad-fit-390-$name');

    // The panel's choices scroll: at their end the off-road note is in full, above Start.
    await tester.ensureVisible(find.byKey(const ValueKey('offroad-note')));
    await settle();
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('offroad-note'))).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byKey(const ValueKey('route-start'))).dy),
      reason: 'the off-road note cannot be scrolled into view',
    );
    await snap(tester, _out, 'offroad-panel-end-390-$name');
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    view.dispose();
    camera.dispose();
    nav.dispose();
    elevation.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final name = theme == CacheThemeId.light ? 'light' : 'dark';

    testWidgets('Off-road chosen: the fitted route above the panel, and the panel scrolled to its end, phone-390, $name', (tester) async {
      await _offroad(tester, theme);
    });

    testWidgets('the measuring bar with its hint in full, phone-390, $name', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      await tester.pumpWidget(shotApp(
        Scaffold(
          backgroundColor: mapPaletteFor(theme)['land'],
          // Where the Maps screen puts the bar: at the foot of the map, 12 points in.
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: MeasurePanel(total: const Fmt(UnitSystem.imperial).distance(966), points: 3, canUndo: true, onUndo: () {}, onDone: () {}),
              ),
            ),
          ),
        ),
        theme: theme,
      ));
      await tester.pump();
      expect(find.text('3 points · tap the map to add more'), findsOneWidget);
      await snap(tester, _out, 'measure-bar-390-$name');
    });
  }
}

// Two faults of the map screens after their fixes, at a phone's width (390 x 844), light and dark, for review:
//   offroad-fit-390-*        Off-road chosen: the route as the screen fitted it into view, in the free column between the
//                            position chip and the map's buttons, with nothing of it under the header, the chip, the buttons,
//                            the scale, the credits or the panel, and the whole of the position dot at its start and of the
//                            pin at its end in that column too; and the bar beside the panel's choices, which shows while
//                            there is more of them than fits
//   offroad-panel-end-390-*  the same screen with the panel's choices scrolled to their end: the off-road note in full above Start
//   measure-bar-390-*        the measuring bar with its hint in full
//
// The live map is a platform view and is not drawn in a test. In its place a stand-in is drawn from the camera the screen asked
// for (the land colour, the route, and at its ends the position dot with its heading marker and the destination's pin, at the
// sizes the map's style draws them on this 3x phone) with the same web-mercator fit the map makes (GuideCamera,
// guide_map_kit.dart), so where the fitted route falls on the screen can be seen. The guide's own pictures have the real map
// (tools/guide/README.md).
// flutter test test_shots/map_faults_renders_test.dart --update-goldens  (pictures in test_shots/map_faults/)

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart' show kPinSelectedEdge, kPinSelectedRadius, kPinSelectedReach, kPositionDotEdge, kPositionDotRadius;
import 'package:cache/maps/ui/map_assets.dart';
import 'package:cache/maps/ui/map_widgets.dart' show AttributionChip, MapButton, ScaleBarWidget;
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
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
    // The ends as the map's style draws them. The destination: the chosen place's pin, with its edge around it.
    canvas.drawCircle(pts.last, kPinSelectedRadius + kPinSelectedEdge + 0.0, Paint()..color = palette['routeCasing']);
    canvas.drawCircle(pts.last, kPinSelectedRadius + 0.0, Paint()..color = palette['pin']);
    // The start: the position dot with its ring, and over it the heading marker (the phone heads north), whose image is
    // _kHeadingPoints square on this phone (MapAssets.headingMarker draws the same triangle).
    canvas.drawCircle(pts.first, kPositionDotRadius + kPositionDotEdge + 0.0, Paint()..color = palette['positionRing']);
    canvas.drawCircle(pts.first, kPositionDotRadius + 0.0, Paint()..color = palette['position']);
    const s = _kHeadingPoints;
    final corner = pts.first - const Offset(s / 2, s / 2);
    final arrow = Path()
      ..moveTo(corner.dx + s / 2, corner.dy + s * 0.04)
      ..lineTo(corner.dx + s / 2 + s * 0.13, corner.dy + s * 0.2)
      ..lineTo(corner.dx + s / 2 - s * 0.13, corner.dy + s * 0.2)
      ..close();
    canvas.drawPath(
        arrow,
        Paint()
          ..color = palette['positionRing']
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.05
          ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(arrow, Paint()..color = palette['position']);
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.view != view;
}

/// The screen of these pictures has 3 pixels per point: the heading marker's image is this many points square on it.
const double _kHeadingPoints = MapAssets.headingMarkerSize / 3;

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
    // The bar beside the choices has come in fully.
    await tester.pump(const Duration(milliseconds: 400));
    // The whole route is on the map with nothing of it under what is over the map. It is a tall route, so it is in the column
    // between the position chip and the map's buttons, which runs down beside the scale to the credits.
    final on = [for (final p in route.points) cam.project(p.lat, p.lon, size)];
    final box = Rect.fromLTRB(on.map((o) => o.dx).reduce(math.min), on.map((o) => o.dy).reduce(math.min), on.map((o) => o.dx).reduce(math.max), on.map((o) => o.dy).reduce(math.max));
    final chip = tester.getRect(find.ancestor(of: find.textContaining('Within '), matching: find.byType(Container)).first);
    final buttons = tester.getRect(find.byType(MapButton).first).expandToInclude(tester.getRect(find.byType(MapButton).last));
    final over = {
      'the header': tester.getRect(find.byType(DirectionsHeader)),
      'the position chip': chip,
      'the map\'s buttons': buttons,
      'the scale': tester.getRect(find.byType(ScaleBarWidget)),
      'the credits': tester.getRect(find.byType(AttributionChip)),
      'the panel': tester.getRect(find.byType(RoutePanel)),
    };
    expect(box.left >= 0 && box.top >= 0 && box.right <= size.width && box.bottom <= size.height, isTrue, reason: 'the route is not wholly on the map: $box');
    for (final MapEntry(key: what, value: rect) in over.entries) {
      expect(rect.overlaps(box.inflate(1)), isFalse, reason: 'part of the route ($box) is under $what ($rect)');
    }
    expect(box.left >= chip.right && box.right <= buttons.left && box.top < chip.bottom, isTrue, reason: 'the tall route is not in the column between the chip and the buttons: $box');
    // What is drawn at the route's ends is wholly on the map and clear of everything over it too: the position dot with its
    // heading marker at the start (the foot of the column) and the destination's pin at the end (its top, under the header).
    final ends = {
      'the position dot with its heading marker': Rect.fromCircle(center: on.first, radius: MapAssets.headingMarkerReach(3)),
      'the destination\'s pin': Rect.fromCircle(center: on.last, radius: kPinSelectedReach),
    };
    for (final MapEntry(key: end, value: disc) in ends.entries) {
      expect(disc.left >= 0 && disc.top >= 0 && disc.right <= size.width && disc.bottom <= size.height, isTrue, reason: '$end is not wholly on the map: $disc');
      for (final MapEntry(key: what, value: rect) in over.entries) {
        expect(rect.overlaps(disc.inflate(1)), isFalse, reason: 'part of $end ($disc) is under $what ($rect)');
      }
    }
    expect(ends.values.last.top, greaterThanOrEqualTo(over['the header']!.bottom + kRouteFitGap - 0.5), reason: 'the pin is nearer to the header than the gap a fitted route keeps');
    await snap(tester, _out, 'offroad-fit-390-$name');

    // The panel's choices scroll: at their end the off-road note is in full, above Start.
    await tester.ensureVisible(find.byKey(const ValueKey('offroad-note')));
    await settle();
    await tester.pump(const Duration(milliseconds: 400));
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

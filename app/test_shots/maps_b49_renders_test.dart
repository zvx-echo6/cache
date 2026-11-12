// The guidance screen's corner picture and credit (the iPhone proof, B49), for the owner to review: the picture's own credit strip is
// cut off, and the one credit is a full-width line under the row. Four themes at 390 x 844; with MAPSB49_OLD set (run against the code
// before the fix) only the dark guidance screen is drawn, for the comparison. The place card for a place from a notebook has no Save.
// The picture is a stand-in with a credit strip drawn at its foot, as the native snapshotter's picture has.
// flutter test test_shots/maps_b49_renders_test.dart --update-goldens  (pictures in test_shots/maps_b49/)

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/overview/overview_camera.dart';
import 'package:cache/nav/overview/route_overview.dart';
import 'package:cache/maps/ui/map_widgets.dart' show AttributionChip;
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/location_service_test.dart' show FakeSource;
import '../test/nav_fakes.dart';
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/support/test_layer_engine.dart';
import 'shot_kit.dart';


/// Hands out stand-in pictures when the test says (they are drawn outside the test's fake clock).
class _StandInSnapshotter implements RouteSnapshotter {
  _StandInSnapshotter(this.route, this.palette);
  final MapRoute route;
  final MapPalette palette;
  final List<(OverviewCamera, double, Completer<OverviewPicture?>)> pending = [];
  final List<OverviewCamera> asked = [];

  @override
  Future<OverviewPicture?> render({required String styleJson, required OverviewCamera camera, required double pixelRatio}) {
    final c = Completer<OverviewPicture?>();
    asked.add(camera);
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
    // What the native snapshotter bakes in at the foot: its own credit strip.
    canvas.drawRect(Rect.fromLTWH(0, size.height - 22, size.width, 22), Paint()..color = const Color(0xCCFFFFFF));
    final tp = TextPainter(
      text: const TextSpan(text: '(c) OpenStreetMap contributors', style: TextStyle(fontSize: 11, color: Color(0xFF000000), fontFamily: 'Roboto')),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width - 6, size.height - 17));
    return rec.endRecording().toImage((size.width * ratio).round(), (size.height * ratio).round());
  }
}


const _out = 'maps_b49';
final _old = Platform.environment.containsKey('MAPSB49_OLD');

Future<void> _guidance(WidgetTester tester, CacheThemeId theme) async {
  const screen = Size(390, 844);
  phone(tester, size: screen, ratio: 3);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('maps-b49-renders-');
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
  final elevation = RouteElevation(loader: (r) async => ElevationProfile.none(route.distanceM));
  final snapshots = _StandInSnapshotter(route, mapPaletteFor(theme));
  final camera = CameraController();
  final along = route.points[(route.points.length * 2.9 / 11.2).round()];
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
      await maps.init();
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
    location.publish(fixAt(along.lat, along.lon, heading: 70));
    await tester.runAsync(() async {
      await nav.openDirections(const MapPlace(id: 'place:osm:n4', type: 'place', name: 'Pine Hollow Trailhead', kind: 'Park', address: '', lat: 42.5, lon: -113.5, matched: 'name'));
      await nav.start();
      gps.controller.add(fixAt(along.lat, along.lon, heading: 70));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(snapshots.fulfil);
    }
    if (!_old) {
      // The corner picture was asked for taller than the corner by the credit strip, and the crop hides that strip.
      final asked = snapshots.asked.first;
      expect(asked.size.height - asked.size.width, kSnapshotCreditStripPt);
      expect(find.byKey(const ValueKey('route-overview-crop')), findsOneWidget);
      final inset = tester.getRect(find.byKey(const ValueKey('route-inset')));
      expect(tester.getSize(find.byKey(const ValueKey('route-overview-crop'))).height, inset.height - 4, reason: 'the visible corner is a square');
      expect(tester.getSize(find.byKey(const ValueKey('route-overview-inset'))).height, inset.height - 4 + kSnapshotCreditStripPt);
      // The credit: under the row, on one line, in full.
      final chip = tester.getRect(find.byType(AttributionChip));
      expect(chip.top, greaterThanOrEqualTo(inset.bottom - 0.5), reason: 'under the corner picture, not beside it');
      expect(chip.width, lessThanOrEqualTo(screen.width));
      final credit = find.descendant(of: find.byType(AttributionChip), matching: find.byType(Text));
      expect(tester.widget<Text>(credit).data, isNotEmpty);
      expect(tester.renderObject<RenderParagraph>(credit).size.height, lessThan(10.5 * 1.2 * 1.5), reason: 'the credit is on one line at 390 pt');
    }
    await snap(tester, _out, _old ? 'guidance-${theme.name}-BEFORE' : 'guidance-${theme.name}');
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
  setUpAll(loadShotFonts);

  if (_old) {
    testWidgets('guidance before the fix, dark', (tester) => _guidance(tester, CacheThemeId.dark));
    return;
  }
  for (final theme in CacheThemeId.values) {
    testWidgets('guidance, ${theme.name}', (tester) => _guidance(tester, theme));
  }
  for (final theme in CacheThemeId.values) {
    testWidgets('place card of a notebook place, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 844), ratio: 3);
      final dir = Directory.systemTemp.createTempSync('maps-b49-card-');
      final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
      final nav = NavState(backend: FakeBackend(), location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
      const place = MapPlace(id: 'notebook:e1', type: 'place', name: 'Hot spring', kind: 'Camping spots', address: 'Off Hwy 30, Hagerman', lat: 42.6, lon: -113.4, matched: '');
      await tester.pumpWidget(shotApp(
        Builder(builder: (c) => Scaffold(backgroundColor: c.t.background, body: Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.all(12), child: PlaceCard(nav: nav, place: place, fmt: const Fmt(UnitSystem.imperial), onClose: () {}))))),
        theme: theme,
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('place-save')), findsNothing);
      await snap(tester, _out, 'place-card-notebook-${theme.name}');
      await tester.pumpWidget(const SizedBox.shrink());
      nav.dispose();
      location.dispose();
      dir.deleteSync(recursive: true);
    });
  }
}

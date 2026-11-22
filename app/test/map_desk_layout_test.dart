// On the web and in Cache on Linux's desktop window, the map's overlays sit at the map's own edges: Layers, Find me and the zoom
// buttons top right (with or without the position chip), the credits bottom right, the scale bottom left over the column on the
// left (while it shows no panel), the position chip at the top left of the area beside that column. A phone, upright or held
// sideways, is laid out exactly as before and has no zoom buttons. Every name and place here is made up.

import 'dart:io';

import 'package:cache/linux_ui.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/ui/map_widgets.dart' show AttributionChip, MapButton, ScaleBarWidget;
import 'package:cache/nav/nav_state.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/test_layer_engine.dart';

const _place = MapPlace(id: 'place:test:fern', type: 'place', name: 'Fernwood Trailhead', kind: 'Park', address: '', lat: 42.5, lon: -113.5);

/// The Maps screen in a window of [size] (the whole window is the map), with the desktop layout on or off ([desk]), a position
/// ([withFix]) and a place chosen ([withPlace], so the column on the left shows a card). [body] reads the screen.
Future<void> _onMaps(
  WidgetTester tester, {
  required Size size,
  required bool desk,
  bool withFix = true,
  bool withPlace = false,
  required Future<void> Function(CameraController camera) body,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  debugLinuxUi = desk ? true : null;
  addTearDown(() => debugLinuxUi = null);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('map-desk-');
  final platform = MapLibrePlatform.createInstance;
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
    maps.setOn('basemap', true);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: MapsScreen(location: location, maps: maps, nav: nav, themeId: CacheThemeId.dark, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(MapLibreMap), findsOneWidget);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    if (withFix) location.publish(fixAt(42.5769, -114.5878));
    if (withPlace) nav.select(_place);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await body(camera);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = platform;
    camera.dispose();
    nav.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

Finder get _zoomIn => find.byTooltip('Zoom in');
Finder get _zoomOut => find.byTooltip('Zoom out');
Finder get _layers => find.byTooltip('Layers');
Finder get _chip => find.textContaining('Within');
Rect _r(WidgetTester t, Finder f) => t.getRect(f);

void main() {
  for (final withFix in [true, false]) {
    testWidgets('wide desktop window, ${withFix ? 'with' : 'without'} the position chip: buttons top right, credits bottom right, scale bottom left', (tester) async {
      const size = Size(1906, 909);
      await _onMaps(tester, size: size, desk: true, withFix: withFix, body: (_) async {
        expect(_chip, withFix ? findsOneWidget : findsNothing);
        // Layers, Find me and the zoom buttons: one column at the map's right edge.
        expect(_r(tester, _layers).right, size.width - 12, reason: 'Layers is not at the right edge');
        expect(_r(tester, _zoomIn).right, size.width - 12);
        expect(_r(tester, _zoomOut).right, size.width - 12);
        expect(_r(tester, _zoomIn).top, greaterThan(_r(tester, _layers).top));
        expect(_r(tester, _zoomOut).top, greaterThan(_r(tester, _zoomIn).top));
        expect(_r(tester, find.byType(AttributionChip)).right, size.width - 12);
        expect(_r(tester, find.byType(AttributionChip)).bottom, size.height - 8);
        // No panel: the scale is at the map's bottom left, under the column on the left.
        expect(_r(tester, find.byType(ScaleBarWidget)).left, closeTo(12, 6));
        expect(_r(tester, find.byType(ScaleBarWidget)).bottom, lessThanOrEqualTo(size.height - 8 + 0.5));
        if (withFix) {
          // The chip stays at the top left of the area beside the column, level with the search box.
          expect(_r(tester, _chip).left, 12 + 380 + 12 - 0.0 + 0, reason: 'chip is not next to the search column');
        }
      });
    });
  }

  testWidgets('desktop window with a place card: the scale stays just right of the column, nothing overlaps', (tester) async {
    const size = Size(1440, 900);
    await _onMaps(tester, size: size, desk: true, withPlace: true, body: (_) async {
      expect(find.text('Fernwood Trailhead'), findsWidgets);
      expect(_r(tester, find.byType(ScaleBarWidget)).left, greaterThanOrEqualTo(12 + 380 + 12));
      expect(_r(tester, find.byType(AttributionChip)).right, size.width - 12);
      expect(_r(tester, _layers).right, size.width - 12);
    });
  });

  testWidgets('the zoom buttons zoom the map by one step', (tester) async {
    await _onMaps(tester, size: const Size(1440, 900), desk: true, body: (camera) async {
      camera.cameras.clear();
      await tester.tap(_zoomIn);
      await tester.pump();
      expect(camera.cameras, [CameraUpdate.zoomIn().toJson()]);
      await tester.tap(_zoomOut);
      await tester.pump();
      expect(camera.cameras.last, CameraUpdate.zoomOut().toJson());
      expect(camera.cameras, hasLength(2));
    });
  });

  testWidgets('the zoom buttons look like the map\'s other buttons', (tester) async {
    await _onMaps(tester, size: const Size(1440, 900), desk: true, body: (_) async {
      expect(find.ancestor(of: _zoomIn, matching: find.byType(MapButton)), findsOneWidget);
      expect(tester.getSize(find.ancestor(of: _zoomIn, matching: find.byType(MapButton))), tester.getSize(find.ancestor(of: _layers, matching: find.byType(MapButton))));
    });
  });

  testWidgets('a phone, upright: no zoom buttons, and the scale, credits and buttons where they were', (tester) async {
    const size = Size(390, 844);
    await _onMaps(tester, size: size, desk: false, body: (_) async {
      expect(_zoomIn, findsNothing);
      expect(_zoomOut, findsNothing);
      expect(_r(tester, find.byType(ScaleBarWidget)).left, 12);
      expect(_r(tester, find.byType(AttributionChip)).left, 12);
      expect(_r(tester, _layers).right, size.width - 12);
    });
  });

  testWidgets('a phone held sideways (not the web): no zoom buttons, layout as before', (tester) async {
    const size = Size(844, 390);
    await _onMaps(tester, size: size, desk: false, body: (_) async {
      expect(_zoomIn, findsNothing);
      expect(_zoomOut, findsNothing);
      // As before: the scale and the credits just right of the column on the left, at its left; the buttons after the chip.
      expect(_r(tester, find.byType(ScaleBarWidget)).left, 12 + 380 + 12);
      expect(_r(tester, find.byType(AttributionChip)).left, 12 + 380 + 12);
      expect(_r(tester, find.byType(AttributionChip)).right, lessThan(size.width - 12));
      expect(_r(tester, _chip).left, 12 + 380 + 12);
    });
  });

  testWidgets('a wide window that is not the web or the Linux desktop is laid out as before', (tester) async {
    await _onMaps(tester, size: const Size(1440, 900), desk: false, body: (_) async {
      expect(_zoomIn, findsNothing);
      expect(_r(tester, find.byType(ScaleBarWidget)).left, 12 + 380 + 12);
    });
  });
}

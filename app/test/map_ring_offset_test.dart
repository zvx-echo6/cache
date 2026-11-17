// The ring on a press and hold sits where the finger is, even with a side rail left of the map (a phone in landscape). Every name and
// place here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/drive_rig.dart';
import 'support/test_layer_engine.dart';

void main() {
  testWidgets('a press and hold puts the ring on the finger, not shifted by the rail left of the map', (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    final dir = Directory.systemTemp.createTempSync('map-ring-');
    final platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine(published: const []);
    final maps = MapsState(engine: engine, settingsDirOverride: dir);
    final rig = DriveRig();
    final camera = CameraController();
    await tester.runAsync(() async {
      await rig.setUp();
      await location.init();
      await engine.start();
    });
    maps.setOn('basemap', true);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Row(children: [
        const SizedBox(width: 341),
        Expanded(
          child: MapsScreen(
            location: location,
            maps: maps,
            nav: rig.nav,
            themeId: CacheThemeId.dark,
            glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
            elevation: rig.elevation,
          ),
        ),
      ]),
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();

    for (final press in const [Offset(1200, 540), Offset(1800, 700)]) {
      // The stubbed map view takes no hits, so the press goes straight to the map's pointer Listener, at a screen point.
      final listener = tester.widget<Listener>(find.ancestor(of: find.byType(MapLibreMap), matching: find.byType(Listener)).first);
      listener.onPointerDown!(PointerDownEvent(position: press));
      map.onMapLongClick!(math.Point<double>(press.dx - 341, press.dy), const LatLng(42.5, -113.5));
      await tester.pump(const Duration(milliseconds: 50));
      final ring = find.byKey(const ValueKey('ring-menu'));
      expect(ring, findsOneWidget);
      final c = tester.getCenter(ring);
      expect((c - press).distance, lessThan(4), reason: 'ring centre $c, press $press');
      await tester.tap(find.byKey(const ValueKey('ring-dismiss')), warnIfMissed: false);
      await tester.pump();
    }

    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = platform;
    camera.dispose();
    maps.dispose();
    await tester.runAsync(() async {
      rig.tearDown();
      location.dispose();
      await dir.delete(recursive: true);
    });
  });
}

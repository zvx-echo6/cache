// Link audit batch 2, after only: the map view after the drive screen's Map (rel-1.1 has no such button), with the back arrow above
// the locate button. The map itself is a platform view and is not drawn. Phone 390 x 844, light. Made-up route and places.
// flutter test test_shots/links2_after_only_renders_test.dart --update-goldens  (picture in test_shots/links2/)

import 'dart:io';

import 'package:cache/car/phone_drive.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../test/location_service_test.dart' show FakeSource;
import '../test/navigation_camera_test.dart' show CameraController, NoSurface;
import '../test/support/drive_rig.dart';
import '../test/support/test_layer_engine.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('04 the map view after Map, with Back', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 3);
    rootBundle.clear();
    final dir = Directory.systemTemp.createTempSync('links2-after-');
    final platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine();
    final maps = MapsState(engine: engine, settingsDirOverride: dir);
    final rig = DriveRig();
    final drive = PhoneDrive();
    final camera = CameraController();
    try {
      await tester.runAsync(() async {
        await rig.setUp();
        await location.init();
        await engine.start();
      });
      await tester.pumpWidget(shotApp(
        MapsScreen(
          location: location,
          maps: maps,
          nav: rig.nav,
          themeId: CacheThemeId.light,
          glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
          elevation: rig.elevation,
          drive: drive,
        ),
      ));
      for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      map.onMapCreated!(camera);
      map.onStyleLoadedCallback!();
      await tester.pump();
      await tester.runAsync(() => rig.guide());
      rig.at(1, 400);
      drive.carConnected.value = true;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.tap(find.byKey(const ValueKey('drive-map')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('peek-back')), findsOneWidget);
      await snap(tester, 'links2', '04-map-back-after-only');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      MapLibrePlatform.createInstance = platform;
      camera.dispose();
      maps.dispose();
      drive.dispose();
      await tester.runAsync(() async {
        rig.tearDown();
        location.dispose();
        await dir.delete(recursive: true);
      });
    }
  });
}

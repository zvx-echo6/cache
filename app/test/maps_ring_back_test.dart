// With the long-press ring open on the Maps screen, Back closes the ring and nothing else; a second Back is as before (the
// screen's route goes). Every name here is made up.

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
  testWidgets('Back closes the open ring and leaves Maps; a second Back leaves as before', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    final dir = Directory.systemTemp.createTempSync('map-ringback-');
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
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      theme: buildTheme(CacheThemeId.dark),
      home: const Scaffold(body: Text('below')),
    ));
    key.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => MapsScreen(
        location: location,
        maps: maps,
        nav: rig.nav,
        themeId: CacheThemeId.dark,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: rig.elevation,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();

    map.onMapLongClick!(const math.Point<double>(100, 100), const LatLng(42.5, -113.5));
    await tester.pump();
    expect(find.byKey(const ValueKey('ring-dismiss')), findsOneWidget, reason: 'the ring is open');

    // First Back: the ring closes, Maps stays.
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('ring-dismiss')), findsNothing, reason: 'the ring is closed');
    expect(find.byType(MapsScreen), findsOneWidget, reason: 'Maps is still there');

    // Second Back: as before, the screen goes.
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MapsScreen), findsNothing);
    expect(find.text('below'), findsOneWidget);

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

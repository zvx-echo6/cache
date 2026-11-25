// The map credits: the credit line shows when the map first opens in a launch and folds to a small (i) on the first pan, zoom or tap,
// or after five seconds; it is not shown again in the same launch; the (i) opens the credits sheet. Every name here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/ui/map_widgets.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/drive_rig.dart';
import 'support/test_layer_engine.dart';

class _Rig {
  late Directory dir;
  late LocationService location;
  late MapsState maps;
  late DriveRig rig;
  final CameraController camera = CameraController();
  late MapLibreMap map;
  late MapLibrePlatform Function() _platform;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: MapsScreen(
        location: location,
        maps: maps,
        nav: rig.nav,
        themeId: CacheThemeId.dark,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: rig.elevation,
      ),
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
  }

  Future<void> setUp(WidgetTester tester) async {
    resetCreditsLaunch();
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    dir = Directory.systemTemp.createTempSync('map-credits-');
    _platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine();
    maps = MapsState(engine: engine, settingsDirOverride: dir);
    rig = DriveRig();
    await tester.runAsync(() async {
      await rig.setUp();
      await location.init();
      await engine.start();
    });
    maps.setOn('basemap', true);
    await open(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = _platform;
    camera.dispose();
    maps.dispose();
    await tester.runAsync(() async {
      rig.tearDown();
      location.dispose();
      await dir.delete(recursive: true);
    });
  }
}

final _line = find.byKey(const ValueKey('credits-line'));
final _button = find.byKey(const ValueKey('credits-button'));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('when the map first opens the credit line shows, with its text, and not the (i)', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    expect(_line, findsOneWidget);
    expect(_button, findsNothing);
    expect(find.text(r.maps.attributions.join(' · ')), findsOneWidget);
    expect(r.maps.attributions, isNotEmpty);
    await r.finish(tester);
  });

  testWidgets('it folds to the (i) on the first pan', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    await tester.dragFrom(const Offset(200, 400), const Offset(0, -120));
    await _settle(tester);
    expect(_line, findsNothing);
    expect(_button, findsOneWidget);
    await r.finish(tester);
  });

  testWidgets('it folds on the first zoom (two fingers; and a mouse wheel)', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await a.moveBy(const Offset(-40, 0));
    await b.moveBy(const Offset(40, 0));
    await a.up();
    await b.up();
    await _settle(tester);
    expect(_line, findsNothing);
    expect(_button, findsOneWidget);
    await r.finish(tester);

    final w = _Rig();
    await w.setUp(tester);
    final mouse = TestPointer(3, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(200, 400)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -80)));
    await _settle(tester);
    expect(_line, findsNothing);
    expect(_button, findsOneWidget);
    await w.finish(tester);
  });

  testWidgets('it folds on the first tap on the map', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    r.map.onMapClick!(const math.Point<double>(100, 100), const LatLng(42.5, -113.5));
    await _settle(tester);
    expect(_line, findsNothing);
    expect(_button, findsOneWidget);
    await r.finish(tester);
  });

  testWidgets('it folds after 5 seconds with no touch, and not before', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(_line, findsOneWidget, reason: 'still the line at 4 s');
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_line, findsNothing);
    expect(_button, findsOneWidget);
    await r.finish(tester);
  });

  testWidgets('it is shown once per launch: a screen opened again, and a return from the background, start and stay folded', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    expect(_line, findsOneWidget);
    // The person leaves Maps before it folded, then comes back in the same launch.
    await tester.pumpWidget(const SizedBox.shrink());
    await r.open(tester);
    expect(_line, findsNothing, reason: 'not shown again in the same launch');
    expect(_button, findsOneWidget);
    for (final st in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(st);
    }
    await _settle(tester);
    expect(_line, findsNothing);
    expect(_button, findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(_line, findsNothing);
    await r.finish(tester);
  });

  testWidgets('the (i) opens the credits sheet, unchanged: "Map credits" and each layer\'s attribution and licence', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    r.map.onMapClick!(const math.Point<double>(100, 100), const LatLng(42.5, -113.5));
    await _settle(tester);
    expect(find.text('Map credits'), findsNothing, reason: 'the sheet is not open yet (the button\'s own label is not text)');
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(find.text('Map credits'), findsOneWidget);
    for (final u in r.maps.uses) {
      expect(find.text(u.def.title), findsWidgets);
      expect(find.text(u.def.attribution), findsWidgets);
    }
    await r.finish(tester);
  });

  testWidgets('the (i) is a 44 point touch target around a 28 point button, and says "Map credits"', (tester) async {
    final r = _Rig();
    await r.setUp(tester);
    r.map.onMapClick!(const math.Point<double>(100, 100), const LatLng(42.5, -113.5));
    await _settle(tester);
    expect(tester.getSize(_button), const Size(44, 44));
    expect(find.bySemanticsLabel('Map credits'), findsOneWidget);
    expect(find.byType(AttributionChip), findsOneWidget);
    await r.finish(tester);
  });
}

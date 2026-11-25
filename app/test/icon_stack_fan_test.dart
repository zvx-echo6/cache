// Stacked icons on the Maps screen: repeaters that overlap are one marker with a count (their own pictures are left out); a tap on it
// fans them out; a tap on a disc opens that repeater's card and folds the fan; the fan folds on a tap on the map or the dim, on Back,
// and when the map is panned or zoomed; more than 8 open a list. Every name and place here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/roads/road_event.dart';
import 'package:cache/roads/road_events_state.dart';
import 'package:cache/roads/road_geo.dart';
import 'package:cache/roads/road_map_layers.dart';
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

const double _lat = 42.56, _lon = -113.46;

/// The fake map: a tap's query answers from [hits] by layer; positions are shown at 23,300 points a degree from the screen's middle.
class _Cam extends CameraController {
  final Map<String, List<Map<String, dynamic>>> hits = {};

  @override
  CameraPosition? get cameraPosition => const CameraPosition(target: LatLng(_lat, _lon), zoom: 14);

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #queryRenderedFeaturesInRect || i.memberName == #queryRenderedFeatures) {
      final layers = (i.positionalArguments[1] as List).cast<String>();
      return Future<List<dynamic>>.value(List<dynamic>.of([for (final l in layers) ...?hits[l]]));
    }
    return super.noSuchMethod(i);
  }
}

class _Maps {
  late Directory dir;
  late LocationService location;
  late MapsState maps;
  late DriveRig rig;
  late UserLayersState userLayers;
  final _Cam camera = _Cam();
  late MapLibreMap map;
  late MapLibrePlatform Function() _platform;

  /// The repeaters of the one list, as [offsets] (in degrees of longitude) from the base spot.
  Future<void> pump(WidgetTester tester, List<double> offsets, {RoadEventsState? roads}) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    dir = Directory.systemTemp.createTempSync('stack-fan-');
    _platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine();
    maps = MapsState(engine: engine, settingsDirOverride: dir);
    rig = DriveRig();
    userLayers = UserLayersState((call, [arg]) async => switch (call) {
          'list' => {
              'layers': const [],
              'repeater_lists': [
                {'id': 'l2', 'kind': 'repeaters', 'name': 'Magic Valley', 'visible': true, 'repeaters': offsets.length},
              ],
            },
          'get' when arg == 'l2' => {
              'id': 'l2',
              'name': 'Magic Valley',
              'repeaters': [
                for (final (i, o) in offsets.indexed) {'item': i + 1, 'address': 'repeater:l2/${i + 1}', 'name': 'K7AB${i + 1}', 'town': 'Twin Falls', 'lat': _lat, 'lon': _lon + o, 'frequency': '146.940 MHz', 'list': 'Magic Valley'},
              ],
            },
          _ => <String, dynamic>{'features': <Object>[]},
        });
    camera.screenOf = (at) => math.Point<num>(195 + (at.longitude - _lon) * 23300, 400 - (at.latitude - _lat) * 23300);
    await tester.runAsync(() async {
      await rig.setUp();
      await location.init();
      await engine.start();
      await userLayers.reload();
    });
    maps.setOn('basemap', true);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: MapsScreen(
        location: location,
        maps: maps,
        nav: rig.nav,
        themeId: CacheThemeId.dark,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: rig.elevation,
        userLayers: userLayers,
        roadEvents: roads,
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
    map.onCameraMove!(const CameraPosition(target: LatLng(_lat, _lon), zoom: 14));
    map.onCameraIdle!();
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester, {int turns = 8}) async {
    for (var i = 0; i < turns; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  List<Map<String, dynamic>> get markers => ((camera.sources[kStackSource]?['features'] as List?) ?? const []).cast<Map<String, dynamic>>();

  /// Taps the group marker on the map (the fake query answers it).
  Future<void> tapMarker(WidgetTester tester) async {
    camera.hits[kStackMarkers] = [markers.single];
    map.onMapClick!(const math.Point<double>(195, 400), const LatLng(_lat, _lon));
    await settle(tester);
    camera.hits.clear();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = _platform;
    camera.dispose();
    maps.dispose();
    userLayers.dispose();
    rig.tearDown();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

void main() {
  // Three repeaters a few points apart at zoom 14 (23,300 points a degree: 0.0002 degrees is under 5 points), one far away.
  const near = [0.0, 0.0002, 0.0004];
  final fan = find.byKey(const ValueKey('stack-fan'));

  testWidgets('repeaters that overlap are one marker with a count; their own pictures are left out', (tester) async {
    final m = _Maps();
    await m.pump(tester, [...near, 0.01]);
    expect(m.markers, hasLength(1));
    expect((m.markers.single['properties'] as Map)['img'], contains('stack-repeater-3'));
    final hidden = m.camera.filters[kUserRepeaters] as List;
    expect(hidden.toString(), allOf(contains('l2/1'), contains('l2/2'), contains('l2/3')), reason: 'the three are filtered out of the repeaters layer');
    expect(hidden.toString(), isNot(contains('l2/4')), reason: 'the far one stays');
    await m.finish(tester);
  });

  testWidgets('a repeater and a road event at one spot group: the marker shows the road event on a tie; a tap on the event\'s disc opens its card', (tester) async {
    final m = _Maps();
    const work = RoadEvent(id: 'e1', source: RoadEventSource.event511, sourceId: 'idaho511-events', kind: RoadEventKind.work, road: 'US-20', line: [], point: LL(_lat, _lon));
    final roads = RoadEventsState(changes: ChangeNotifier(), debounce: Duration.zero, read: () async => [work]);
    await m.pump(tester, [0.0], roads: roads);
    await tester.runAsync(() async => roads.refresh());
    await m.settle(tester);
    expect(m.markers, hasLength(1));
    expect((m.markers.single['properties'] as Map)['img'], contains('stack-roadEvent-2'));
    expect(m.camera.filters[kRoadEventChips].toString(), contains('e1'), reason: 'the event\'s own chip is left out');
    await m.tapMarker(tester);
    await tester.tap(find.byKey(const ValueKey('stack-disc-road:e1')));
    await m.settle(tester);
    expect(roads.selectedId, 'e1');
    expect(fan, findsNothing);
    await m.finish(tester);
  });

  testWidgets('repeaters far apart are not grouped: no marker, nothing filtered out', (tester) async {
    final m = _Maps();
    await m.pump(tester, [0.0, 0.01, 0.02]);
    expect(m.markers, isEmpty);
    await m.finish(tester);
  });

  testWidgets('zoomed in the group dissolves (the discs are bigger but their points are further apart)', (tester) async {
    final m = _Maps();
    await m.pump(tester, near);
    expect(m.markers, hasLength(1));
    m.map.onCameraMove!(const CameraPosition(target: LatLng(_lat, _lon), zoom: 19));
    m.map.onCameraIdle!();
    await m.settle(tester);
    expect(m.markers, isEmpty, reason: 'at zoom 19 the points are 5 x 16 = 70 points apart');
    await m.finish(tester);
  });

  testWidgets('a tap on the marker opens the fan: a disc for each repeater, with a target of 44 points', (tester) async {
    final m = _Maps();
    await m.pump(tester, near);
    await m.tapMarker(tester);
    expect(fan, findsOneWidget);
    for (final i in [1, 2, 3]) {
      final disc = find.byKey(ValueKey('stack-disc-repeater:l2/$i'));
      expect(disc, findsOneWidget);
      expect(tester.getSize(disc), const Size(44, 44));
    }
    await m.finish(tester);
  });

  testWidgets('a tap on a disc opens that repeater\'s card and folds the fan', (tester) async {
    final m = _Maps();
    await m.pump(tester, near);
    await m.tapMarker(tester);
    await tester.tap(find.byKey(const ValueKey('stack-disc-repeater:l2/2')));
    await m.settle(tester);
    expect(m.userLayers.selectedRepeater.value?.name, 'K7AB2');
    expect(fan, findsNothing, reason: 'the fan folds when a card opens');
    await m.finish(tester);
  });

  testWidgets('the fan folds on a tap on the dim, on a tap on the map, on Back, on a pan and on a zoom', (tester) async {
    final m = _Maps();
    await m.pump(tester, near);

    await m.tapMarker(tester);
    await tester.tapAt(const Offset(20, 120));
    await m.settle(tester);
    expect(fan, findsNothing, reason: 'the dim');

    await m.tapMarker(tester);
    m.map.onMapClick!(const math.Point<double>(30, 700), const LatLng(42.0, -113.0));
    await m.settle(tester);
    expect(fan, findsNothing, reason: 'a tap on the map');

    await m.tapMarker(tester);
    await tester.binding.handlePopRoute();
    await m.settle(tester);
    expect(fan, findsNothing, reason: 'Back');

    await m.tapMarker(tester);
    m.map.onCameraMove!(const CameraPosition(target: LatLng(_lat + 0.001, _lon), zoom: 14));
    await m.settle(tester);
    expect(fan, findsNothing, reason: 'a pan');

    await m.tapMarker(tester);
    m.map.onCameraMove!(const CameraPosition(target: LatLng(_lat + 0.001, _lon), zoom: 14.6));
    await m.settle(tester);
    expect(fan, findsNothing, reason: 'a zoom');
    await m.finish(tester);
  });

  testWidgets('more than 8 in a group open a list, not a fan; a row opens that repeater\'s card', (tester) async {
    final m = _Maps();
    await m.pump(tester, [for (var i = 0; i < 9; i++) i * 0.00005]);
    expect(m.markers, hasLength(1));
    await m.tapMarker(tester);
    expect(fan, findsNothing);
    expect(find.byKey(const ValueKey('stack-list')), findsOneWidget);
    expect(find.text('9 here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stack-row-repeater:l2/4')));
    await m.settle(tester);
    expect(m.userLayers.selectedRepeater.value?.name, 'K7AB4');
    await m.finish(tester);
  });

  testWidgets('repeaters at one spot stay one group at every zoom', (tester) async {
    final m = _Maps();
    await m.pump(tester, [0.0, 0.0]);
    expect(m.markers, hasLength(1));
    m.map.onCameraMove!(const CameraPosition(target: LatLng(_lat, _lon), zoom: 20));
    m.map.onCameraIdle!();
    await m.settle(tester);
    expect(m.markers, hasLength(1), reason: 'identical coordinates never split');
    await m.finish(tester);
  });
}

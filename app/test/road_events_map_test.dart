// The Maps screen and road events: what the sources stored is drawn from the state (nothing is fetched while panning), a tap on a closure
// opens its card and wins over the road's name under it, and a tap with no event under it opens what it did before. Every name and
// place here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
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

Map<String, dynamic> _raw(String type, Object coords, Map<String, dynamic> props) => {
      'type': 'Feature',
      'geometry': {'type': type, 'coordinates': coords},
      'properties': props,
    };

/// A map whose query answers what the test put in [events] for the road event layers and in [labels] for the base map's labels.
class _Camera extends CameraController {
  final List<Map<String, dynamic>> events = [];
  final List<Map<String, dynamic>> labels = [];
  final List<List<String>> asked = [];

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #queryRenderedFeaturesInRect || i.memberName == #queryRenderedFeatures) {
      final layers = (i.positionalArguments[1] as List).cast<String>();
      asked.add(layers);
      final out = layers.contains(kRoadEventChips) ? events : (layers.contains('places_locality') ? labels : const <Map<String, dynamic>>[]);
      return Future<List<dynamic>>.value(List<dynamic>.of(out));
    }
    return super.noSuchMethod(i);
  }
}

RoadEvent _closure(String id, {bool stale = false, String? age, bool full = true}) => RoadEvent(
  id: id,
  source: RoadEventSource.event511,
  sourceId: 'idaho511-events',
  kind: RoadEventKind.closure,
  road: 'Sample Highway',
  line: decodePolyline('kabiGpg}dU?etBXqYVaG|@cL`@gD'),
  point: const LL(43.6049, -116.2809),
  heading: Heading.west,
  fullClosure: full,
  stale: stale,
  age: age ?? '40 minutes old',
  fields: const {'Details': 'Sample closure.'},
  credit: 'Road events: Idaho 511',
);

class _Rig {
  late Directory dir;
  late LocationService location;
  late MapsState maps;
  late DriveRig rig;
  final _Camera camera = _Camera();
  late MapLibreMap map;
  late MapLibrePlatform Function() _platform;
  late RoadEventsState roads;
  final ChangeNotifier changes = ChangeNotifier();
  List<RoadEvent> stored = [];
  int reads = 0;

  Future<void> pump(WidgetTester tester, List<RoadEvent> events) async {
    stored = events;
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    dir = Directory.systemTemp.createTempSync('road-map-');
    _platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine(published: const []);
    maps = MapsState(engine: engine, settingsDirOverride: dir);
    rig = DriveRig();
    roads = RoadEventsState(
      changes: changes,
      debounce: Duration.zero,
      read: () async {
        reads++;
        return stored;
      },
    );
    await tester.runAsync(() async {
      await rig.setUp();
      await location.init();
      await engine.start();
    });
    maps.setOn('basemap', true);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: MapsScreen(
        location: location,
        maps: maps,
        nav: rig.nav,
        themeId: CacheThemeId.light,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: rig.elevation,
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
    // The style load draws the chips (real image work) and then the events.
    for (var i = 0; i < 300 && !camera.styleEvents.contains('image:$kRoadChipWork'); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> tap(WidgetTester tester) async {
    map.onMapClick!(const math.Point<double>(100, 100), const LatLng(43.6049, -116.2809));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = _platform;
    camera.dispose();
    maps.dispose();
    roads.dispose();
    changes.dispose();
    await tester.runAsync(() async {
      rig.tearDown();
      location.dispose();
      await dir.delete(recursive: true);
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('what the sources stored is drawn; the road chips are in the style; nothing is read while the map pans', (tester) async {
    final m = _Rig();
    await m.pump(tester, [_closure('a')]);
    final src = m.camera.sources[kRoadEventSource];
    expect(src, isNotNull, reason: 'the events were pushed to the map source');
    final roles = [for (final f in src!['features'] as List) ((f as Map)['properties'] as Map)['role']];
    expect(roles, containsAll(['closure', 'chip']));
    expect(m.camera.styleEvents, containsAll(['image:$kRoadChipClosure', 'image:$kRoadChipCrash', 'image:$kRoadChipWork']));
    final before = m.reads;
    // the camera moves: no read of the stored data and so no download (a read is from the stored copy, never a fetch)
    m.map.onCameraMove?.call(const CameraPosition(target: LatLng(43.7, -116.3), zoom: 11));
    await tester.pump(const Duration(milliseconds: 500));
    expect(m.reads, before, reason: 'panning does not read or fetch anything');
    await m.finish(tester);
  });

  testWidgets('a tap on a closure opens its card and wins over the road\'s name under it', (tester) async {
    final m = _Rig();
    await m.pump(tester, [_closure('a')]);
    m.camera.events.add(_raw('Point', [-116.2809, 43.6049], {'id': 'a', 'role': 'chip'}));
    m.camera.labels.add(_raw('LineString', [[-116.29, 43.6], [-116.27, 43.6]], {'name': 'Sample Highway'}));
    await m.tap(tester);
    expect(find.byKey(const ValueKey('road-event-card')), findsOneWidget);
    expect(find.text('Sample Highway'), findsOneWidget);
    expect(find.text('Road closure · Westbound'), findsOneWidget);
    expect(find.text('All lanes closed'), findsOneWidget);
    expect(find.byKey(const ValueKey('place-card-name')), findsNothing, reason: 'the road label under it did not open a road card');
    expect(m.camera.asked.where((l) => l.contains('places_locality')), isEmpty, reason: 'the base map was not even asked');
    // the tapped event is marked on the map
    final props = [for (final f in m.camera.sources[kRoadEventSource]!['features'] as List) (f as Map)['properties'] as Map];
    expect(props.where((p) => p['sel'] == true), isNotEmpty);
    // Close
    await tester.tap(find.byKey(const ValueKey('road-event-card-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('road-event-card')), findsNothing);
    expect(m.roads.selectedId, isNull);
    await m.finish(tester);
  });

  testWidgets('with no event under the tap the map does what it did before', (tester) async {
    final m = _Rig();
    await m.pump(tester, [_closure('a')]);
    await m.tap(tester);
    expect(find.byKey(const ValueKey('road-event-card')), findsNothing);
    expect(m.roads.selectedId, isNull);
    expect(m.camera.asked.any((l) => l.contains(kRoadEventChips)), isTrue, reason: 'the event layers were asked first');
    await m.finish(tester);
  });

  testWidgets('an event past its validity is shown dimmed with its age, not hidden', (tester) async {
    final m = _Rig();
    await m.pump(tester, [_closure('a', stale: true, age: '5 hours old')]);
    final f = (m.camera.sources[kRoadEventSource]!['features'] as List).cast<Map>();
    expect(f.every((x) => (x['properties'] as Map)['dim'] == true), isTrue);
    m.camera.events.add(_raw('Point', [-116.2809, 43.6049], {'id': 'a', 'role': 'chip'}));
    await m.tap(tester);
    expect(find.textContaining('Out of date, last updated 5 hours ago'), findsOneWidget);
    await m.finish(tester);
  });

  testWidgets('a new read of the stored data redraws, and an event that is gone closes its card', (tester) async {
    final m = _Rig();
    await m.pump(tester, [_closure('a'), _closure('b')]);
    m.camera.events.add(_raw('Point', [-116.2809, 43.6049], {'id': 'b', 'role': 'chip'}));
    await m.tap(tester);
    expect(m.roads.selectedId, 'b');
    m.stored = [_closure('a')];
    m.changes.notifyListeners();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
    expect(m.roads.selectedId, isNull);
    expect(find.byKey(const ValueKey('road-event-card')), findsNothing);
    final ids = {for (final f in m.camera.sources[kRoadEventSource]!['features'] as List) ((f as Map)['properties'] as Map)['id']};
    expect(ids, {'a'});
    await m.finish(tester);
  });
}

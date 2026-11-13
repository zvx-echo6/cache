import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart' show kPinSource;
import 'package:cache/nav/guidance_camera.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/lane_strip.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/ui/route_steps.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/test_layer_engine.dart';

/// A route east along 42.5N with [turns] maneuvers evenly along it: the start, turns left and right onto Road 1, Road 2, ...,
/// a stop as the third when [stop], and the arrival. The second maneuver has lane arrows when [lanes]. [alternative]: one other
/// route offered with it.
Map<String, dynamic> stepRouteJson({String id = 's1', int turns = 5, bool stop = false, bool lanes = false, String mode = 'drive', Map<String, dynamic>? alternative}) {
  final j = fakeRouteJson(id: id, mode: mode, name: 'Place 1');
  const n = 40;
  final total = (j['distance_m'] as num).toDouble();
  final mans = <Map<String, dynamic>>[];
  for (var i = 0; i < turns; i++) {
    final last = i == turns - 1 && turns > 1;
    final b = turns == 1 ? 0 : (i * n / (turns - 1)).round();
    final e = turns == 1 ? n : (last ? n : ((i + 1) * n / (turns - 1)).round());
    final type = i == 0 ? 'start' : (last ? 'destination' : (stop && i == 2 ? 'via' : (i.isOdd ? 'left' : 'right')));
    final instruction = switch (type) {
      'start' => 'Drive east on Road 0.',
      'destination' => 'You have arrived at your destination.',
      'via' => 'You have arrived at your stop.',
      'left' => 'Turn left onto Road $i.',
      _ => 'Turn right onto Road $i.',
    };
    mans.add({
      'index': i, 'kind': 'road', 'type': type, 'instruction': instruction, 'street_names': ['Road $i'],
      'distance_m': total * (e - b) / n, 'duration_s': 10, 'lat': 42.5, 'lon': -113.8 + 0.3 * b / n,
      'begin_index': b, 'end_index': e, 'bearing_deg': 90, 'cardinal': 'E', 'travel': mode,
      if (lanes && i == 1) 'lanes': [{'directions': 8, 'active': 8}, {'directions': 2}],
    });
  }
  j['maneuvers'] = mans;
  if (alternative != null) j['alternatives'] = [alternative];
  return j;
}

const _to = MapPlace(id: 'place:test:1', type: 'place', name: 'Place 1', kind: '', address: '', lat: 42.5, lon: -113.5, matched: 'name');

/// The Maps screen on a phone ([size]) with a route shown before Start: the route [route] gives for each call (the n-th call
/// is given n, from 1). [body] does the test.
Future<void> _withPreview(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  required Map<String, dynamic> Function(int call, String mode) route,
  required Future<void> Function(NavState nav, CameraController camera, FakeBackend backend) body,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('route-steps-');
  final originalPlatform = MapLibrePlatform.createInstance;
  MapLibrePlatform.createInstance = () => NoSurface();
  final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
  final engine = TestLayerEngine();
  final maps = MapsState(engine: engine, settingsDirOverride: dir);
  var calls = 0;
  final backend = FakeBackend()..onRoute = ((to, mode, from) async => MapRoute.fromJson(route(++calls, mode)));
  final gps = FakeNavPosition();
  final nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial));
  final camera = CameraController();
  try {
    await tester.runAsync(() async {
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: MapsScreen(location: location, maps: maps, nav: nav, themeId: CacheThemeId.light, glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf'),
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byType(MapLibreMap), findsOneWidget, reason: 'the map did not appear');
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(camera);
    map.onStyleLoadedCallback!();
    await tester.pump();
    // The route starts from a chosen place, as on Linux with no position (and with no position chip over the map: the test's
    // font draws every letter as a wide box, and the chip and the buttons would not fit side by side at 390).
    nav.setFrom(const MapPlace(id: 'place:test:0', type: 'place', name: 'Place 0', kind: '', address: '', lat: 42.5, lon: -113.8, matched: 'name'));
    await tester.runAsync(() => nav.openDirections(_to));
    await _settle(tester);
    expect(nav.phase, NavPhase.previewing);
    expect(find.byType(RoutePanel), findsOneWidget);
    await body(nav, camera, backend);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = originalPlatform;
    camera.dispose();
    nav.dispose();
    maps.dispose();
    location.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// The last camera move to a point the screen asked for (the step's), as (target lat, target lon, zoom, bearing).
(double, double, double, double)? _lastStepCamera(CameraController camera) {
  for (final u in camera.cameras.reversed) {
    if (u is List && u.first == 'newCameraPosition') {
      final c = (u[1] as Map).cast<String, dynamic>();
      final t = (c['target'] as List).cast<num>();
      return (t[0].toDouble(), t[1].toDouble(), (c['zoom'] as num).toDouble(), (c['bearing'] as num).toDouble());
    }
  }
  return null;
}

int _fits(CameraController camera) => camera.cameras.where((u) => u is List && u.first == 'newLatLngBounds').length;

bool _enabled(WidgetTester tester, String key) => tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed != null;

String _counter(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('step-counter'))).data!;

/// From the whole route (the route panel): its next arrow shows the first turn.
Future<void> _open(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('step-card')), findsNothing);
  await tester.tap(find.byKey(const ValueKey('step-next')));
  await _settle(tester);
  expect(find.byKey(const ValueKey('step-card')), findsOneWidget);
}

/// The whole route on the route panel: the arrows beside Start, back off and next on, no counter and no close.
void _expectWholeRoute(WidgetTester tester) {
  expect(find.byKey(const ValueKey('step-card')), findsNothing);
  expect(find.byType(RoutePanel), findsOneWidget);
  expect(_enabled(tester, 'step-back'), isFalse);
  expect(_enabled(tester, 'step-next'), isTrue);
  expect(find.byKey(const ValueKey('step-counter')), findsNothing);
  expect(find.byKey(const ValueKey('step-close')), findsNothing);
}

/// Checks that the camera the screen last asked for shows maneuver [i] of [route] at a street's zoom, north up, on the map and
/// above the step card (not under it).
void _expectCameraOn(WidgetTester tester, CameraController camera, MapRoute route, int i) {
  final cam = _lastStepCamera(camera);
  expect(cam, isNotNull, reason: 'the map was not moved to the turn');
  final (lat, lon, zoom, bearing) = cam!;
  expect(zoom, kStepZoom);
  expect(bearing, 0);
  final m = route.maneuvers[i];
  final mapSize = tester.getSize(find.byType(MapLibreMap));
  final at = screenPointFor(m.lat, m.lon, centreLat: lat, centreLon: lon, bearing: 0, zoom: zoom, map: mapSize);
  final card = tester.getRect(find.byKey(const ValueKey('step-card')));
  expect(at.dx, inInclusiveRange(0, mapSize.width), reason: 'turn ${i + 1} is off the map across');
  expect(at.dy, greaterThan(0), reason: 'turn ${i + 1} is above the map');
  expect(at.dy, lessThan(card.top), reason: 'turn ${i + 1} is under the step card');
}

void main() {
  testWidgets('the step card goes forward and back through the turns, one at a time, and the map follows each turn', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n', turns: 5, lanes: true), body: (nav, camera, backend) async {
      // The whole route first: back is off, next is on, no counter and no close.
      _expectWholeRoute(tester);
      expect(find.byTooltip('Previous'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      await _open(tester);
      final r = nav.route!;
      expect(_counter(tester), stepCounterText(1, 5));
      expect(find.text('Drive east on Road 0'), findsOneWidget);
      expect(find.byKey(const ValueKey('step-close')), findsOneWidget);
      // The first turn: back returns to the whole route, so it is on.
      expect(_enabled(tester, 'step-back'), isTrue);
      expect(_enabled(tester, 'step-next'), isTrue);
      _expectCameraOn(tester, camera, r, 0);
      // The turn shown is marked on the map.
      final pins = (camera.sources[kPinSource]!['features'] as List).cast<Map<String, dynamic>>();
      expect(pins.where((f) => (f['properties'] as Map)['id'] == 'route-step').map((f) => (f['geometry'] as Map)['coordinates']), [
        [r.maneuvers[0].lon, r.maneuvers[0].lat],
      ]);

      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(2, 5));
      expect(find.text('Turn left onto Road 1'), findsOneWidget);
      expect(find.text('Drive east on Road 0'), findsNothing);
      // The second turn has lane arrows on the route.
      expect(find.byType(LaneStrip), findsOneWidget);
      expect(_enabled(tester, 'step-back'), isTrue);
      _expectCameraOn(tester, camera, r, 1);

      for (var i = 2; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('step-next')));
        await _settle(tester);
        expect(_counter(tester), stepCounterText(i + 1, 5));
        _expectCameraOn(tester, camera, r, i);
      }
      // The last turn: there is no way forward.
      expect(find.text('You have arrived at your destination'), findsOneWidget);
      expect(_enabled(tester, 'step-next'), isFalse);
      expect(_enabled(tester, 'step-back'), isTrue);
      expect(find.byType(LaneStrip), findsNothing);
      final marks = (camera.sources[kPinSource]!['features'] as List).cast<Map<String, dynamic>>().where((f) => (f['properties'] as Map)['id'] == 'route-step');
      expect(marks.single['geometry']['coordinates'], [r.maneuvers[4].lon, r.maneuvers[4].lat]);

      await tester.tap(find.byKey(const ValueKey('step-back')));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(4, 5));
      _expectCameraOn(tester, camera, r, 3);
    });
  });

  testWidgets('a sideways swipe on the step card steps too', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n', turns: 4), body: (nav, camera, backend) async {
      await _open(tester);
      await tester.drag(find.byKey(const ValueKey('step-counter')), const Offset(-120, 0));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(2, 4));
      await tester.drag(find.byKey(const ValueKey('step-counter')), const Offset(-120, 0));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(3, 4));
      await tester.drag(find.byKey(const ValueKey('step-counter')), const Offset(120, 0));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(2, 4));
      await tester.drag(find.byKey(const ValueKey('step-counter')), const Offset(120, 0));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(1, 4));
      // A swipe back from the first turn is the back arrow's: the whole route again.
      await tester.drag(find.byKey(const ValueKey('step-counter')), const Offset(120, 0));
      await _settle(tester);
      _expectWholeRoute(tester);
    });
  });

  testWidgets('a stop shows its number and name', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n', turns: 5, stop: n > 1), body: (nav, camera, backend) async {
      await tester.runAsync(() => nav.addStop(const MapPlace(id: 'place:test:2', type: 'place', name: 'Market 1', kind: '', address: '', lat: 42.5, lon: -113.65, matched: 'name')));
      await _settle(tester);
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(3, 5));
      expect(find.descendant(of: find.byKey(const ValueKey('step-card')), matching: find.text('Stop 1: Market 1')), findsOneWidget);
    });
  });

  testWidgets('a route of one turn: next shows it, and then only back (to the whole route) is on', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n', turns: 1), body: (nav, camera, backend) async {
      _expectWholeRoute(tester);
      await _open(tester);
      expect(_counter(tester), stepCounterText(1, 1));
      expect(_enabled(tester, 'step-back'), isTrue);
      expect(_enabled(tester, 'step-next'), isFalse);
      _expectCameraOn(tester, camera, nav.route!, 0);
    });
  });

  testWidgets('close returns to the whole route, fitted into view, with the routes', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n'), body: (nav, camera, backend) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      final before = _fits(camera);
      await tester.tap(find.byKey(const ValueKey('step-close')));
      await _settle(tester);
      _expectWholeRoute(tester);
      expect(_fits(camera), greaterThan(before), reason: 'the whole route was not fitted again');
      expect(camera.cameras.last is List && (camera.cameras.last as List).first == 'newLatLngBounds', isTrue);
      final marks = (camera.sources[kPinSource]!['features'] as List).cast<Map<String, dynamic>>().where((f) => (f['properties'] as Map)['id'] == 'route-step');
      expect(marks, isEmpty, reason: 'the turn is still marked');
      expect(nav.phase, NavPhase.previewing);
    });
  });

  testWidgets('back from the first turn returns to the whole route, fitted into view, as close does', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n'), body: (nav, camera, backend) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('step-back')));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(1, 5));
      final before = _fits(camera);
      await tester.tap(find.byKey(const ValueKey('step-back')));
      await _settle(tester);
      _expectWholeRoute(tester);
      expect(_fits(camera), greaterThan(before), reason: 'the whole route was not fitted again');
      expect(camera.cameras.last is List && (camera.cameras.last as List).first == 'newLatLngBounds', isTrue);
      final marks = (camera.sources[kPinSource]!['features'] as List).cast<Map<String, dynamic>>().where((f) => (f['properties'] as Map)['id'] == 'route-step');
      expect(marks, isEmpty, reason: 'the turn is still marked');
      expect(nav.phase, NavPhase.previewing);
      // Next again starts from the first turn.
      await _open(tester);
      expect(_counter(tester), stepCounterText(1, 5));
    });
  });

  testWidgets('the system Back closes the card and returns to the whole route', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n'), body: (nav, camera, backend) async {
      await _open(tester);
      final before = _fits(camera);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      _expectWholeRoute(tester);
      expect(_fits(camera), greaterThan(before));
      expect(nav.phase, NavPhase.previewing, reason: 'Back left the route preview');
    });
  });

  testWidgets('another way of travel closes the card: no turn of the old route is shown', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n', mode: mode, turns: mode == 'walk' ? 3 : 5), body: (nav, camera, backend) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      expect(_counter(tester), stepCounterText(2, 5));
      await tester.runAsync(() => nav.setMode('walk'));
      await _settle(tester);
      _expectWholeRoute(tester);
      // Opened again, it is the new route's first turn.
      await _open(tester);
      expect(_counter(tester), stepCounterText(1, 3));
    });
  });

  testWidgets('choosing another route closes the card', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n', alternative: stepRouteJson(id: 'a$n', turns: 3)), body: (nav, camera, backend) async {
      expect(nav.routes.length, 2);
      await _open(tester);
      nav.selectRoute(1);
      await _settle(tester);
      _expectWholeRoute(tester);
      await _open(tester);
      expect(_counter(tester), stepCounterText(1, 3));
    });
  });

  testWidgets('Start on the card starts guidance as Start on the panel does', (tester) async {
    await _withPreview(tester, route: (n, mode) => stepRouteJson(id: 's$n'), body: (nav, camera, backend) async {
      backend.onProgress = (route, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route.raw, 0.1));
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('step-next')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('step-start')));
      await _settle(tester);
      expect(nav.phase, NavPhase.guiding);
      expect(nav.route!.routeId, 's1');
      expect(find.byKey(const ValueKey('step-card')), findsNothing);
      await tester.runAsync(() => nav.end());
      await _settle(tester);
    });
  });

  test('the lane arrows are the route\'s own, and none on arrival', () {
    final r = MapRoute.fromJson(stepRouteJson(turns: 6, stop: true));
    expect(r.maneuvers.map((m) => m.type), ['start', 'left', 'via', 'left', 'right', 'destination']);
    expect(previewStepLanes(r, 1), isEmpty);
    final withLanes = MapRoute.fromJson(stepRouteJson(turns: 3, lanes: true));
    expect(previewStepLanes(withLanes, 1).length, 2);
    expect(previewStepLanes(withLanes, 2), isEmpty, reason: 'no lanes on arrival');
  });
}

import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/measure.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart' show MeasurePanel;
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

class _Here implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

MapPlace pin(String name, double lat, double lon) => MapPlace.pin(lat, lon, name: name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late NavState nav;
  final events = <NavEvent>[];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ring');
    location = LocationService(source: _Here(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend()..onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson());
    nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    events.clear();
    nav.events.listen(events.add);
  });

  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  test('From here: directions start at the held spot, after the destination is chosen; Back starts from the phone again', () async {
    nav.setFrom(pin('Trailhead', 43.0, -114.0));
    expect(nav.searchOpen, isTrue, reason: 'the destination is chosen next');
    expect(nav.phase, NavPhase.browsing);
    await nav.openDirections(pin('Camp', 43.1, -114.2));
    expect(backend.froms.last, {'lat': 43.0, 'lon': -114.0, 'name': 'Trailhead'});
    nav.clearFrom();
    await Future<void>.delayed(Duration.zero);
    expect(backend.froms.last!['name'], 'Your location');
    nav.setFrom(pin('Trailhead', 43.0, -114.0));
    await Future<void>.delayed(Duration.zero);
    expect(backend.froms.last!['name'], 'Trailhead', reason: 'while a route is shown it is routed again from there');
    nav.cancelDirections();
    expect(nav.fromPlace, isNull);
  });

  test('Add stop: only while a route is shown; each stop goes to the router in order; at most 10; removable', () async {
    expect(await nav.addStop(pin('Store', 42.9, -113.9)), isFalse, reason: 'no route yet');
    await nav.openDirections(pin('Camp', 43.1, -114.2));
    expect(await nav.addStop(pin('Store', 42.9, -113.9)), isTrue);
    expect(await nav.addStop(pin('Gas', 42.95, -114.0)), isTrue);
    expect([for (final v in backend.vias.last) v['name']], ['Store', 'Gas']);
    await nav.removeStop(0);
    expect([for (final v in backend.vias.last) v['name']], ['Gas']);
    for (var i = 0; i < 9; i++) {
      await nav.addStop(pin('S$i', 42.0 + i / 10, -114.0));
    }
    expect(nav.stops.length, NavState.maxStops);
    expect(await nav.addStop(pin('One too many', 42.0, -114.0)), isFalse);
    expect(events.whereType<NavNotice>().last.text, 'A route has at most 10 stops');
    nav.cancelDirections();
    expect(nav.stops, isEmpty);
  });

  test('Measure: each point adds to the total; Undo takes the last one off, never the first', () {
    final m = MeasureLine(42.5, -113.8);
    expect(m.totalM, 0);
    expect(m.canUndo, isFalse);
    m.add(42.51, -113.8);
    expect(m.totalM, closeTo(1112, 2));
    m.add(42.51, -113.79);
    expect(m.totalM, closeTo(1112 + 820, 4));
    expect((m.geoJson()['features'] as List).length, 4, reason: 'three points and the line');
    expect(m.undo(), isTrue);
    expect(m.points.length, 2);
    expect(m.undo(), isTrue);
    expect(m.undo(), isFalse);
    expect(m.points.length, 1);
  });

  testWidgets('the measuring bar: total in the person\'s units, Undo, Done', (tester) async {
    var undo = 0, done = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Scaffold(
        body: MeasurePanel(total: const Fmt(UnitSystem.imperial).distance(1932), points: 3, canUndo: true, onUndo: () => undo++, onDone: () => done++),
      ),
    ));
    expect(find.text(const Fmt(UnitSystem.imperial).distance(1932)), findsOneWidget);
    expect(find.text('3 points · tap the map to add more'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('measure-undo')));
    await tester.tap(find.byKey(const ValueKey('measure-done')));
    expect((undo, done), (1, 1));
  });
}

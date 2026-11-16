// Directions opened before the phone has a position said "Your position is not known yet" and kept saying it after the first fix
// arrived, until the travel mode was switched. The panel (and the car screen) now follow the position. Every name here is made up.

import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';

class _NoSource implements PositionSource {
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

const _to = MapPlace(id: 'place:4', type: 'place', name: 'Far Clinic', kind: 'Hospital', lat: 42.5, lon: -113.5, matched: 'name');

void main() {
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late NavState nav;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dirpos');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    backend = FakeBackend()..onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(mode: mode));
    nav = NavState(
      backend: backend,
      location: location,
      speaker: FakeSpeaker(),
      positionSource: FakeNavPosition(),
      fmt: const Fmt(UnitSystem.imperial),
      searchDebounce: const Duration(milliseconds: 5),
      meaningDebounce: const Duration(milliseconds: 25),
    );
  });

  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> panel(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        // The screen rebuilds the panel when the nav state changes, as the Maps screen does.
        home: Scaffold(body: SingleChildScrollView(child: ListenableBuilder(listenable: nav, builder: (_, _) => RoutePanel(nav: nav, fmt: const Fmt(UnitSystem.imperial))))),
      ));

  testWidgets('"not known" at first; the first position arrives; the panel asks for the routes with no mode switch', (tester) async {
    await panel(tester);
    await tester.runAsync(() => nav.openDirections(_to));
    await tester.pump();
    expect(find.byKey(const ValueKey('route-error')), findsOneWidget);
    expect(find.textContaining('position is not known'), findsOneWidget);
    expect(backend.calls.where((c) => c.startsWith('route:')), isEmpty);

    location.publish(fixAt(42.5, -113.8));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(backend.calls.where((c) => c.startsWith('route:')), ['route:drive:Far Clinic:from'], reason: 'asked as soon as the position arrived');
    expect(nav.routes, isNotEmpty);
    expect(find.textContaining('position is not known'), findsNothing);
    expect(find.byKey(const ValueKey('route-error')), findsNothing);
  });

  testWidgets('a start the person chose is not waiting for a position: a later fix does not ask again', (tester) async {
    nav.fromPlace = MapPlace.pin(42.49, -113.81, name: 'Gravel lot');
    await tester.runAsync(() => nav.openDirections(_to));
    final before = backend.calls.length;
    location.publish(fixAt(42.5, -113.8));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(backend.calls.length, before);
  });

  testWidgets('after Cancel, a position arriving asks for nothing', (tester) async {
    await tester.runAsync(() => nav.openDirections(_to));
    nav.cancelDirections();
    location.publish(fixAt(42.5, -113.8));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(backend.calls.where((c) => c.startsWith('route:')), isEmpty);
    expect(nav.routeError, isNull);
  });
}

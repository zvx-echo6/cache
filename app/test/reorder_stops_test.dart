import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
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
}

MapPlace pin(String name, double lat, double lon) => MapPlace.pin(lat, lon, name: name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late NavState nav;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('reorder');
    location = LocationService(source: _Here(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend()..onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson());
    nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  });

  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> threeStops() async {
    await nav.openDirections(pin('Camp', 43.1, -114.2));
    await nav.addStop(pin('A', 42.9, -113.9));
    await nav.addStop(pin('B', 42.95, -114.0));
    await nav.addStop(pin('C', 43.0, -114.1));
  }

  List<String> names() => [for (final s in nav.stops) s.name];
  List<String> sent() => [for (final v in backend.vias.last) v['name'] as String];

  group('NavState.reorderStop', () {
    test('moves a stop and the route is asked again with the new order', () async {
      await threeStops();
      final asks = backend.vias.length;
      await nav.reorderStop(0, 2);
      expect(names(), ['B', 'C', 'A']);
      expect(backend.vias.length, asks + 1, reason: 'route recomputed');
      expect(sent(), ['B', 'C', 'A']);
      await nav.reorderStop(2, 0);
      expect(names(), ['A', 'B', 'C']);
      expect(sent(), ['A', 'B', 'C']);
    });

    test('notifies listeners, and the destination is untouched', () async {
      await threeStops();
      var n = 0;
      nav.addListener(() => n++);
      await nav.reorderStop(1, 0);
      expect(n, greaterThan(0));
      expect(nav.selected?.name, 'Camp');
    });

    test('same place, or out of range, changes nothing and does not recompute', () async {
      await threeStops();
      final asks = backend.vias.length;
      await nav.reorderStop(1, 1);
      await nav.reorderStop(-1, 0);
      await nav.reorderStop(0, -1);
      await nav.reorderStop(3, 0);
      await nav.reorderStop(0, 3);
      expect(names(), ['A', 'B', 'C']);
      expect(backend.vias.length, asks);
    });

    test('with no route shown there is nothing to recompute', () async {
      nav.stops = [pin('A', 1, 1), pin('B', 2, 2)];
      await nav.reorderStop(0, 1);
      expect(names(), ['B', 'A']);
      expect(backend.vias, isEmpty);
    });
  });

  group('the header', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Scaffold(body: ListenableBuilder(listenable: nav, builder: (_, __) => DirectionsHeader(nav: nav))),
      ));
    }

    void setUpStops() {
      nav
        ..selected = pin('Camp', 43.1, -114.2)
        ..fromPlace = pin('Gravel lot', 42.49, -113.81)
        ..stops = [pin('A', 42.9, -113.9), pin('B', 42.95, -114.0), pin('C', 43.0, -114.1)];
    }

    testWidgets('a handle on each middle stop only, 44 pt, with the bars icon', (tester) async {
      setUpStops();
      await pump(tester);
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey('stop-handle-$i')), findsOneWidget);
      }
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
      expect(tester.getSize(find.byKey(const ValueKey('stop-handle-0'))), const Size(44, 44));
      expect(find.byKey(const ValueKey('directions-from')), findsOneWidget);
      expect(find.byKey(const ValueKey('directions-to')), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-remove-0')), findsOneWidget);
    });

    testWidgets('dragging a handle reorders at once, renumbers, and says so', (tester) async {
      setUpStops();
      await pump(tester);
      final h = tester.getCenter(find.byKey(const ValueKey('stop-handle-0')));
      final g = await tester.startGesture(h);
      await tester.pump();
      await g.moveBy(const Offset(0, 20));
      await tester.pump();
      await g.moveBy(const Offset(0, 80));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(names(), ['B', 'C', 'A']);
      expect(find.text('Stop 3: A'), findsOneWidget);
      expect(find.text('Stop 1: B'), findsOneWidget);
      expect(find.text('Stop order changed'), findsOneWidget);
    });

    testWidgets('no handles while guiding', (tester) async {
      setUpStops();
      nav.phase = NavPhase.guiding;
      await pump(tester);
      expect(find.byIcon(Icons.drag_handle), findsNothing);
      expect(find.text('Stop 1: A'), findsOneWidget);
    });
  });
}

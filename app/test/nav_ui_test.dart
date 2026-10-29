import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/guidance_panels.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/ui/search_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class TestNav extends NavState {
  TestNav(FakeBackend b, LocationService l)
      : super(
          backend: b,
          location: l,
          speaker: FakeSpeaker(),
          positionSource: FakeNavPosition(),
          fmt: const Fmt(UnitSystem.imperial),
          searchDebounce: const Duration(milliseconds: 1),
          meaningDebounce: const Duration(milliseconds: 2),
        );

  void poke() => notifyListeners();
}

const hospital = MapPlace(
  id: 'place:osm:n4',
  type: 'place',
  name: 'Cassia Regional Hospital',
  kind: 'Hospital',
  category: 'hospital',
  address: '1501 Hiland Ave, Burley, ID',
  lat: 42.5,
  lon: -113.5,
  distanceM: 24600,
  direction: 'E',
  phone: '+1 208 678 4444',
  hours: '24/7',
  summary: 'Cassia Regional Hospital is a critical access hospital in Burley, Idaho.',
  wikipediaTitle: 'Cassia Regional Hospital',
  matched: 'name',
);

/// A panel that rebuilds when the navigation state changes, as it does on the Maps screen.
Widget live(NavState nav, Widget Function() build) => ListenableBuilder(listenable: nav, builder: (_, _) => build());

Widget host(CacheThemeId theme, Widget child, {double scale = 1.0}) => MaterialApp(
      theme: buildTheme(theme),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(360, 700), textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.bottomCenter, child: child)))),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late TestNav nav;
  const fmt = Fmt(UnitSystem.imperial);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('navui');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend();
    nav = TestNav(backend, location);
  });

  tearDown(() {
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  for (final theme in CacheThemeId.values) {
    group('in the ${theme.label} theme', () {
      testWidgets('search: typing lists names, kinds and distances; tapping a result chooses it', (tester) async {
        backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [
              hospital,
              const MapPlace(id: 'category:pharmacy', type: 'category', name: 'Pharmacy', kind: 'Category', lat: 0, lon: 0),
              const MapPlace(id: 'town:1', type: 'town', name: 'Burley', kind: 'City', address: 'ID', lat: 42.5357, lon: -113.7928),
            ]);
        await tester.pumpWidget(host(theme, NavSearchBar(nav: nav, fmt: fmt)));
        expect(find.text('Search places or coordinates'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('map-search-field')), 'hosp');
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump();
        expect(find.text('Cassia Regional Hospital'), findsOneWidget);
        expect(find.textContaining('Hospital · 1501 Hiland Ave'), findsOneWidget);
        expect(find.text('Pharmacy'), findsOneWidget);
        expect(find.text('All nearby'), findsOneWidget);
        expect(find.text('Burley'), findsOneWidget);
        // 24,600 m east of the phone's position
        expect(find.textContaining('15 mi E'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cassia Regional Hospital'));
        await tester.pump();
        expect(nav.selected!.id, 'place:osm:n4');
        expect(nav.searchOpen, isFalse);
        expect(find.text('Pharmacy'), findsNothing, reason: 'the list is gone; the field shows the choice');
      });

      testWidgets('search: nothing found, a note about words only, and the clear and back buttons', (tester) async {
        backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'no_embedder', results: const []);
        await tester.pumpWidget(host(theme, NavSearchBar(nav: nav, fmt: fmt)));
        await tester.enterText(find.byKey(const ValueKey('map-search-field')), 'zzz');
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump();
        expect(find.text('Nothing found for "zzz"'), findsOneWidget);
        await tester.tap(find.byTooltip('Clear'));
        await tester.pump();
        expect(nav.query, '');
        await tester.tap(find.byTooltip('Close search'));
        await tester.pump();
        expect(nav.searchOpen, isFalse);
      });

      testWidgets('place card: details, copy, and the three actions', (tester) async {
        await tester.pumpWidget(host(theme, PlaceCard(nav: nav, place: hospital, fmt: fmt, onClose: () {})));
        expect(find.text('Cassia Regional Hospital'), findsOneWidget);
        expect(find.text('Hospital · 15 mi E'), findsOneWidget);
        expect(find.text('1501 Hiland Ave, Burley, ID'), findsOneWidget);
        expect(find.text('+1 208 678 4444'), findsOneWidget);
        expect(find.text('24/7'), findsOneWidget);
        expect(find.textContaining('critical access hospital'), findsOneWidget);
        expect(find.text('Wikipedia: Cassia Regional Hospital'), findsOneWidget);
        expect(find.text('Directions'), findsOneWidget);
        expect(find.text('Save place'), findsOneWidget);
        expect(find.text('Add to Home'), findsOneWidget);
        final events = <NavEvent>[];
        nav.events.listen(events.add);
        await tester.tap(find.text('Add to Home'));
        await tester.tap(find.text('Save place'));
        await tester.pump();
        await tester.pump();
        expect(events.whereType<AddToHomeRequested>(), hasLength(1));
        expect(backend.saved, hasLength(1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('place card: a dropped pin shows its coordinates in every format and copies one on tap', (tester) async {
        final pin = MapPlace.pin(43.6, -116.2, formats: {'decimal': '43.60000, -116.20000', 'dms': '43°36\'0.0"N 116°12\'0.0"W', 'usng': '11T NK 12345 67890', 'plus_code': '85M9G8VC+MM'});
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
          return null;
        });
        await tester.pumpWidget(host(theme, PlaceCard(nav: nav, place: pin, fmt: fmt, onClose: () {})));
        expect(find.text('Dropped pin'), findsOneWidget);
        for (final label in ['Decimal', 'DMS', 'USNG', 'Plus Code']) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('85M9G8VC+MM'), findsOneWidget);
        await tester.tap(find.text('11T NK 12345 67890'));
        await tester.pump();
        expect(copied, '11T NK 12345 67890');
        expect(find.text('Copied'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('place card at the largest text size still fits', (tester) async {
        await tester.pumpWidget(host(theme, PlaceCard(nav: nav, place: hospital, fmt: fmt, onClose: () {}), scale: 1.6));
        expect(tester.takeException(), isNull);
      });

      testWidgets('directions: the way of travel, the routes, the off-road note, Start', (tester) async {
        backend.onRoute = (to, mode, from) async => MapRoute.fromJson({...fakeRouteJson(offroad: true, mode: mode), 'alternatives': [fakeRouteJson(id: 'r2', alt: 1)]});
        await nav.openDirections(hospital);
        await tester.pumpWidget(host(theme, live(nav, () => RoutePanel(nav: nav, fmt: fmt))));
        for (final m in ['Drive', 'Walk', 'Bike']) {
          expect(find.text(m), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('route-card-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('route-card-1')), findsOneWidget);
        expect(find.textContaining('off-road'), findsWidgets);
        expect(find.byKey(const ValueKey('offroad-note')), findsOneWidget);
        expect(find.textContaining('shown dashed'), findsOneWidget);
        expect(find.text('Start'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('route-card-1')));
        await tester.pump();
        expect(nav.routeIndex, 1);
        // the second (road only) route has no off-road note
        expect(find.byKey(const ValueKey('offroad-note')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('mode-walk')));
        await tester.pump();
        expect(nav.mode, 'walk');
        expect(tester.takeException(), isNull);
      });

      testWidgets('directions: off-road, on foot or by vehicle, with the land access', (tester) async {
        backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(offroad: true, mode: mode));
        await nav.openDirections(hospital);
        await tester.pumpWidget(host(theme, live(nav, () => RoutePanel(nav: nav, fmt: fmt))));
        expect(find.text('Off-road'), findsOneWidget);
        expect(find.byKey(const ValueKey('land-strict')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('mode-offroad')));
        await tester.pump();
        expect(nav.mode, 'offroad_foot');
        for (final t in ['On foot', 'Vehicle', 'Stay on open land', 'Usual', 'Emergency: any land']) {
          expect(find.text(t), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('land-emergency-warning')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('offroad-mode-offroad_vehicle')));
        await tester.pump();
        expect(nav.mode, 'offroad_vehicle');
        await tester.tap(find.byKey(const ValueKey('land-emergency')));
        await tester.pump();
        expect(nav.landAccess, 'emergency');
        expect(find.byKey(const ValueKey('land-emergency-warning')), findsOneWidget);
        expect(find.textContaining('Ignores land rules'), findsOneWidget);
        // back to drive: the off-road choices go away; Off-road comes back to the vehicle
        await tester.tap(find.byKey(const ValueKey('mode-drive')));
        await tester.pump();
        expect(find.byKey(const ValueKey('land-strict')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('mode-offroad')));
        await tester.pump();
        expect(nav.mode, 'offroad_vehicle');
        expect(tester.takeException(), isNull);
      });

      testWidgets('directions: off-road at the largest text size still fits', (tester) async {
        backend.onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(offroad: true, mode: mode));
        await nav.openDirections(hospital);
        await nav.setMode('offroad_vehicle');
        await nav.setLandAccess('emergency');
        await tester.pumpWidget(host(theme, live(nav, () => RoutePanel(nav: nav, fmt: fmt)), scale: 1.6));
        expect(find.byKey(const ValueKey('land-emergency-warning')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('directions: finding the way, and an error with Start switched off', (tester) async {
        nav.routing = true;
        await tester.pumpWidget(host(theme, live(nav, () => RoutePanel(nav: nav, fmt: fmt))));
        expect(find.text('Finding the way'), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('route-start'))).onPressed, isNull);
        nav.routing = false;
        nav.routeError = 'No way found between these places';
        nav.poke();
        await tester.pump();
        expect(find.text('No way found between these places'), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('route-start'))).onPressed, isNull);
      });

      testWidgets('guidance: the next turn with its distance, the one after, and the totals', (tester) async {
        final route = fakeRouteJson();
        await _startGuiding(nav, backend, route);
        nav.progress = MapProgress.fromJson(fakeProgressJson(route, 0.3));
        nav.poke();
        await tester.pumpWidget(host(theme, live(nav, () => Column(mainAxisSize: MainAxisSize.min, children: [GuidanceBanner(nav: nav, fmt: fmt), const SizedBox(height: 8), GuidanceBar(nav: nav, fmt: fmt)]))));
        expect(find.byKey(const ValueKey('banner-distance')), findsOneWidget);
        expect(find.text('Turn left onto Road 1.'), findsOneWidget);
        expect(find.textContaining('Then turn right onto Road 2'), findsOneWidget);
        expect(find.byIcon(Icons.turn_left), findsOneWidget);
        expect(find.text('left'), findsOneWidget);
        expect(find.text('to go'), findsOneWidget);
        expect(find.text('arrive'), findsOneWidget);
        expect(find.text('End'), findsOneWidget);
        expect(find.byTooltip('Turn the voice off'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('guidance-voice')));
        await tester.pump();
        expect(find.byTooltip('Turn the voice on'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('guidance: on open ground it shows the bearing, how far, and the climb', (tester) async {
        final route = fakeRouteJson(offroad: true);
        await _startGuiding(nav, backend, route);
        nav.progress = MapProgress.fromJson(fakeProgressJson(route, 0.85));
        nav.poke();
        await tester.pumpWidget(host(theme, live(nav, () => GuidanceBanner(nav: nav, fmt: fmt))));
        expect(find.byKey(const ValueKey('banner-offroad')), findsOneWidget);
        expect(find.text('Head E · 87°'), findsOneWidget);
        expect(find.textContaining('Climb'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('guidance: waiting for a fix, rerouting, and arrival', (tester) async {
        final route = fakeRouteJson();
        await _startGuiding(nav, backend, route);
        await tester.pumpWidget(host(theme, live(nav, () => GuidanceBanner(nav: nav, fmt: fmt))));
        expect(find.text('Getting your position'), findsOneWidget);
        nav.rerouting = true;
        nav.poke();
        await tester.pump();
        expect(find.text('Rerouting'), findsOneWidget);
        nav.rerouting = false;
        nav.arrived = true;
        nav.poke();
        await tester.pump();
        expect(find.text('You have arrived'), findsOneWidget);
        await tester.pumpWidget(host(theme, live(nav, () => GuidanceBar(nav: nav, fmt: fmt))));
        expect(find.text('Done'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('guidance at the largest text size still fits on a narrow screen', (tester) async {
        final route = fakeRouteJson();
        await _startGuiding(nav, backend, route);
        nav.progress = MapProgress.fromJson(fakeProgressJson(route, 0.3));
        nav.poke();
        await tester.pumpWidget(host(theme, live(nav, () => Column(mainAxisSize: MainAxisSize.min, children: [GuidanceBanner(nav: nav, fmt: fmt), const SizedBox(height: 8), GuidanceBar(nav: nav, fmt: fmt)])), scale: 1.4));
        expect(tester.takeException(), isNull);
      });
    });
  }
}

Future<void> _startGuiding(TestNav nav, FakeBackend backend, Map<String, dynamic> route) async {
  backend.onRoute = (to, mode, from) async => MapRoute.fromJson(route);
  backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.0));
  await nav.openDirections(hospital);
  await nav.start();
  // no fix has come from the position service yet
  nav.progress = null;
}

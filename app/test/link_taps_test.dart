// The link audit's first batch (rel-1.1): everything on the map, the route panel, the elevation, the drive screen, the layer sheet
// and a saved place's page that points to something opens it. Every name and place here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/car/car_trip.dart';
import 'package:cache/car/phone_drive.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/open_maps.dart';
import 'package:cache/nav/ui/elevation_panel.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/drive_rig.dart';
import 'support/notebook_fake.dart';
import 'support/test_layer_engine.dart';

/// The fake map, answering a tap's query with the features put in [hits] for each layer.
class _HitCamera extends CameraController {
  final Map<String, List<Map<String, dynamic>>> hits = {};

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #queryRenderedFeatures) {
      final layers = (i.positionalArguments[1] as List).cast<String>();
      return Future<List<dynamic>>.value([for (final l in layers) ...?hits[l]]);
    }
    return super.noSuchMethod(i);
  }
}

/// The Maps screen on a phone, with the drive rig's navigation state (made-up route, places and position).
class _Maps {
  late Directory dir;
  late LocationService location;
  late MapsState maps;
  late DriveRig rig;
  late PhoneDrive drive;
  final _HitCamera camera = _HitCamera();
  late MapLibreMap map;
  late MapLibrePlatform Function() _platform;

  DriveNav get nav => rig.nav;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    dir = Directory.systemTemp.createTempSync('link-taps-');
    _platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine();
    maps = MapsState(engine: engine, settingsDirOverride: dir);
    rig = DriveRig();
    drive = PhoneDrive();
    await tester.runAsync(() async {
      await rig.setUp();
      await location.init();
      await engine.start();
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: MapsScreen(
        location: location,
        maps: maps,
        nav: nav,
        themeId: CacheThemeId.dark,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: rig.elevation,
        drive: drive,
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

  /// A tap on the map at ([lat], [lon]), and the frames after it.
  Future<void> tap(WidgetTester tester, double lat, double lon) async {
    map.onMapClick!(const math.Point<double>(100, 100), LatLng(lat, lon));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// The last camera move of [kind] ('newLatLngZoom', 'newLatLngBounds'), as the map package encodes it.
  List<dynamic>? lastMove(String kind) => camera.cameras.cast<List<dynamic>>().where((u) => u.first == kind).lastOrNull;

  /// The small pin the screen marks a shown spot with.
  Map? marked() => ((camera.sources[kPinSource]?['features'] as List?) ?? const []).cast<Map>().where((f) => (f['properties'] as Map)['id'] == 'route-step').firstOrNull;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = _platform;
    camera.dispose();
    maps.dispose();
    drive.dispose();
    await tester.runAsync(() async {
      rig.tearDown();
      location.dispose();
      await dir.delete(recursive: true);
    });
  }
}

const _bakery = MapPlace(id: 'place:test:bakery', type: 'place', name: 'Larkspur Bakery', kind: 'Bakery', address: '', lat: 42.51, lon: -113.7, matched: 'name');
const _mill = MapPlace(id: 'place:test:mill', type: 'place', name: 'Old Mill Bakery', kind: 'Bakery', address: '', lat: 42.52, lon: -113.6, matched: 'name');

void _near(List<dynamic>? move, double lat, double lon, {String? reason}) {
  expect(move, isNotNull, reason: reason);
  final at = (move![1] as List).cast<num>();
  expect(at[0].toDouble(), closeTo(lat, 1e-6), reason: reason);
  expect(at[1].toDouble(), closeTo(lon, 1e-6), reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1 and 2: the map\'s own pins and lines', () {
    testWidgets('a search result\'s pin opens that result\'s card (it used to close the search)', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.rig.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: const [_bakery, _mill]);
      await tester.runAsync(() async {
        m.nav.openSearch();
        m.nav.onQueryChanged('bakery');
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await m.settle(tester);
      expect(m.nav.results.map((r) => r.id), [_bakery.id, _mill.id]);
      m.camera.hits[kPinResults] = [
        {'properties': {'role': 'result', 'id': _mill.id}},
      ];
      await m.tap(tester, _mill.lat, _mill.lon);
      expect(m.nav.selected?.id, _mill.id, reason: 'the tapped pin\'s place is chosen');
      expect(m.nav.searchOpen, isFalse);
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      expect(find.text('Old Mill Bakery'), findsWidgets);
      await m.finish(tester);
    });

    testWidgets('a tap on the map away from any result\'s pin still closes the search', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.rig.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: const [_bakery]);
      await tester.runAsync(() async {
        m.nav.openSearch();
        m.nav.onQueryChanged('bakery');
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await m.tap(tester, 42.9, -113.0);
      expect(m.nav.searchOpen, isFalse);
      expect(m.nav.selected, isNull);
      await m.finish(tester);
    });

    testWidgets('the grey line of another route chooses that route, as its card does', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      final best = fakeRouteJson(id: 'r1', name: 'Spruce Gap');
      best['alternatives'] = [fakeRouteJson(id: 'r2', alt: 3, name: 'Spruce Gap')];
      m.rig.backend.onRoute = (to, mode, from) async => MapRoute.fromJson(best);
      await tester.runAsync(() => m.nav.openDirections(const MapPlace(id: 'place:test:gap', type: 'place', name: 'Spruce Gap', kind: '', address: '', lat: 42.5, lon: -113.5, matched: 'name')));
      await m.settle(tester);
      expect(m.nav.routes, hasLength(2));
      expect(m.nav.routeIndex, 0);
      // On the chosen route's own line: nothing changes.
      await m.tap(tester, 42.5, -113.65);
      expect(m.nav.routeIndex, 0);
      // On the other route's line, where it is farthest from the chosen one.
      final alt = m.nav.routes[1].points[20];
      await m.tap(tester, alt.lat, alt.lon);
      expect(m.nav.routeIndex, 1);
      expect(m.nav.phase, NavPhase.previewing);
      await m.finish(tester);
    });

    test('a tap counts as on another route\'s line within a finger\'s reach, and only when nearer to it than to the chosen route', () {
      final best = MapRoute.fromJson(fakeRouteJson(id: 'r1'));
      final alt = MapRoute.fromJson(fakeRouteJson(id: 'r2', alt: 3));
      final routes = [best, alt];
      final mid = alt.points[20];
      final mpp = metresPerPoint(mid.lat, 14);
      expect(mpp, closeTo(3.5, 0.2), reason: 'about 3.5 m a point at zoom 14 at this latitude');
      expect(altRouteAt(routes, 0, mid.lat, mid.lon, metresPerPoint: mpp), 1);
      // 10 points off the line: still on it. 30 points off: not.
      expect(altRouteAt(routes, 0, mid.lat + 10 * mpp / 110574, mid.lon, metresPerPoint: mpp), 1);
      expect(altRouteAt(routes, 0, mid.lat + 30 * mpp / 110574, mid.lon, metresPerPoint: mpp), isNull);
      // The chosen route's line is not another route.
      expect(altRouteAt(routes, 1, mid.lat, mid.lon, metresPerPoint: mpp), isNull);
      expect(altRouteAt(routes, 1, 42.5, best.points[20].lon, metresPerPoint: mpp), 0);
      expect(altRouteAt([best], 0, 42.5, -113.65, metresPerPoint: mpp), isNull);
    });
  });

  group('3: the route panel\'s header', () {
    Future<NavState> header(WidgetTester tester) async {
      final r = DriveRig();
      await tester.runAsync(r.setUp);
      addTearDown(r.tearDown);
      final nav = r.nav
        ..selected = driveDestination
        ..fromPlace = MapPlace.pin(42.49, -113.81, name: 'Gravel lot')
        ..stops = const [driveStop];
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: DirectionsHeader(nav: nav))));
      return nav;
    }

    testWidgets('"Directions to" shows the destination, "From" the start, a stop\'s row that stop; each opens the Maps tab', (tester) async {
      final nav = await header(tester);
      final asked = <NavEvent>[];
      final sub = nav.events.listen(asked.add);
      addTearDown(sub.cancel);
      await tester.tap(find.byKey(const ValueKey('directions-to')));
      expect(nav.mapShow?.at?.lat, driveDestination.lat);
      expect(nav.mapShow?.at?.lon, driveDestination.lon);
      expect(nav.takeMapShow(), isNotNull);
      await tester.tap(find.byKey(const ValueKey('directions-from')));
      expect(nav.takeMapShow()?.at?.lat, 42.49);
      await tester.tap(find.text('Stop 1: Corner Market'));
      final s = nav.takeMapShow();
      expect((s?.at?.lat, s?.at?.lon), (driveStop.lat, driveStop.lon));
      await tester.pump();
      expect(asked.whereType<MapRequested>(), hasLength(3));
      // The stop's X still removes it, and only that.
      expect(find.byKey(const ValueKey('stop-remove-0')), findsOneWidget);
    });

    testWidgets('the Maps screen brings a spot it is asked to show into view and marks it', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.nav.showOnMap(const GeoPoint(42.53, -113.66));
      await m.settle(tester);
      _near(m.lastMove('newLatLngZoom'), 42.53, -113.66);
      final mark = m.marked();
      expect(mark, isNotNull, reason: 'the spot is marked');
      expect(((mark!['geometry'] as Map)['coordinates'] as List).cast<num>(), [-113.66, 42.53]);
      expect(m.nav.mapShow, isNull, reason: 'taken');
      await m.finish(tester);
    });
  });

  group('4: a saved place\'s page', () {
    testWidgets('its small map and its coordinates open it on the Maps tab; a link in its notes opens', (tester) async {
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store);
      await tester.runAsync(nb.start);
      final book = await tester.runAsync(nb.ensureSavedPlaces);
      final e = await tester.runAsync(() => nb.saveEntry(
            notebookId: book!.id,
            occurredAt: '2026-10-27T10:00:00-06:00',
            title: 'Rally point 7',
            body: '[Trail notes](https://example.org/trail-notes)',
            place: const NbPlace(lat: 42.531, lon: -113.661, label: 'North gate'),
          ));
      final shown = <(double, double, String)>[];
      final links = <String>[];
      final pd = PlaceNotebookDeps(
        watched: (_) => false,
        setWatched: (_, _) {},
        alerts: PlaceAlerts.memory(),
        map: (context, pin, onPick, look) => const ColoredBox(key: ValueKey('fake-place-map'), color: Colors.teal),
        show: (p, name) => shown.add((p.lat, p.lon, name)),
        openLink: (url) async => links.add(url),
      );
      final deps = NotebookDeps(notebook: nb, places: const PlaceChoices(here: _noHere, saved: _noSaved), placesDeps: pd, now: DateTime.now);
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: PlaceView(deps: deps, book: book!, entryId: e!.id)));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('fake-place-map')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('place-map-open')));
      expect(shown, [(42.531, -113.661, 'Rally point 7')]);
      await tester.tap(find.byKey(const ValueKey('place-coords')));
      expect(shown, hasLength(2));
      await tester.tap(find.text('Trail notes', findRichText: true));
      await tester.pump();
      expect(links, ['https://example.org/trail-notes']);
    });

    test('Show on a place opens its card while looking at the map, and only its spot while a route is shown', () async {
      final r = DriveRig();
      await r.setUp();
      addTearDown(r.tearDown);
      final asked = <NavEvent>[];
      final sub = r.nav.events.listen(asked.add);
      addTearDown(sub.cancel);
      r.nav.showPlace(_bakery);
      await Future<void>.delayed(Duration.zero);
      expect(r.nav.selected?.id, _bakery.id);
      expect(asked.whereType<MapRequested>(), hasLength(1));
      await r.guide();
      r.nav.showPlace(_mill);
      await Future<void>.delayed(Duration.zero);
      expect(r.nav.selected?.id, driveDestination.id, reason: 'the route being followed keeps its destination');
      expect((r.nav.mapShow?.at?.lat, r.nav.mapShow?.at?.lon), (_mill.lat, _mill.lon));
      expect(asked.whereType<MapRequested>(), hasLength(2));
    });
  });

  group('5: a place card of a notebook place', () {
    NbEntry entry(String id, {String? key, String title = 'Spring box', double lat = 42.54, double lon = -113.62}) =>
        NbEntry(id: id, notebookId: 'nb1', occurredAt: '2026-10-27T10:00:00-06:00', title: title, place: NbPlace(lat: lat, lon: lon, key: key));

    test('the card finds its Places notebook entry', () {
      final pins = [entry('e1'), entry('e2', key: 'k2', title: 'Saved spot', lat: 42.55), entry('e3', title: 'Cabin', lat: 42.56)];
      expect(notebookEntryFor(const MapPlace(id: 'notebook:e1', type: 'place', name: 'Spring box', kind: '', address: '', lat: 1, lon: 1, matched: ''), pins)?.id, 'e1');
      expect(notebookEntryFor(const MapPlace(id: 'place:x', type: 'place', name: 'Renamed', kind: '', address: '', lat: 9, lon: 9, matched: ''), pins, savedKey: 'k2')?.id, 'e2');
      expect(notebookEntryFor(const MapPlace(id: 'place:42.56,-113.62', type: 'place', name: 'Cabin', kind: '', address: '', lat: 42.56, lon: -113.62, matched: ''), pins)?.id, 'e3');
      expect(notebookEntryFor(const MapPlace(id: 'place:y', type: 'place', name: 'Cabin', kind: '', address: '', lat: 42.6, lon: -113.62, matched: ''), pins), isNull);
      expect(notebookEntryFor(const MapPlace(id: 'notebook:gone', type: 'place', name: 'Spring box', kind: '', address: '', lat: 42.54, lon: -113.62, matched: ''), pins), isNull);
    });

    testWidgets('it has Open, as the notebook pin\'s sheet does, only when there is an entry', (tester) async {
      final r = DriveRig();
      await tester.runAsync(r.setUp);
      addTearDown(r.tearDown);
      var opened = 0;
      const place = MapPlace(id: 'notebook:e1', type: 'place', name: 'Spring box', kind: 'Places', address: '', lat: 42.54, lon: -113.62, matched: '');
      Future<void> card(VoidCallback? open) => tester.pumpWidget(MaterialApp(
            theme: buildTheme(CacheThemeId.light),
            home: Scaffold(body: PlaceCard(nav: r.nav, place: place, fmt: r.nav.fmt, onClose: () {}, onOpenEntry: open)),
          ));
      await card(() => opened++);
      final open = find.byKey(const ValueKey('place-open-entry'));
      expect(open, findsOneWidget);
      expect(find.descendant(of: open, matching: find.text('Open')), findsOneWidget);
      await tester.tap(open);
      expect(opened, 1);
      await card(null);
      expect(find.byKey(const ValueKey('place-open-entry')), findsNothing);
    });
  });

  group('6: the elevation', () {
    Future<RouteElevation> loaded(WidgetTester tester) async {
      final el = RouteElevation(loader: (route) async => driveProfile());
      addTearDown(el.dispose);
      await tester.runAsync(() async {
        el.request(MapRoute.fromJson(driveRouteJson()));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      return el;
    }

    test('a point of the chart is the share of the route under it', () {
      expect(chartFractionAt(44, 354, full: true), 0);
      expect(chartFractionAt(344, 354, full: true), 1);
      expect(chartFractionAt(194, 354, full: true), closeTo(0.5, 1e-9));
      expect(chartFractionAt(10, 354, full: true), 0, reason: 'left of the plot: its start');
      expect(chartFractionAt(40 + 150, 350, full: false), closeTo(0.5, 1e-9));
    });

    testWidgets('the guidance panel: a touch on the chart, Highest, Lowest and Steepest climb ahead each give their spot', (tester) async {
      final el = await loaded(tester);
      final spots = <double>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Scaffold(body: SizedBox(width: 400, child: ElevationPanel(elevation: el, fmt: const Fmt(UnitSystem.imperial), palette: mapPaletteFor(CacheThemeId.light), distanceAlongM: 0, routeM: 24600, onSpot: spots.add))),
      ));
      await tester.pump();
      final p = el.profile!;
      final chart = tester.getRect(find.byKey(const ValueKey('elevation-chart')));
      await tester.tapAt(Offset(chart.left + 44 + (chart.width - 54) * 0.25, chart.center.dy));
      expect(spots.single, closeTo(0.25, 0.01));
      await tester.tap(find.byKey(const ValueKey('elevation-highest')));
      expect(spots.last, closeTo(p.highest!.distM / p.totalM, 1e-9));
      await tester.tap(find.byKey(const ValueKey('elevation-lowest')));
      expect(spots.last, closeTo(p.lowest!.distM / p.totalM, 1e-9));
      final steep = el.climbAhead(0)!;
      await tester.tap(find.byKey(const ValueKey('elevation-steep')));
      expect(spots.last, closeTo(steep.startM / p.totalM, 1e-9));
      expect(spots, hasLength(4));
    });

    testWidgets('the route preview\'s summary: its chart, Highest and Lowest give their spot', (tester) async {
      final el = await loaded(tester);
      final spots = <double>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Scaffold(body: SizedBox(width: 360, child: RouteElevationSummary(elevation: el, fmt: const Fmt(UnitSystem.imperial), palette: mapPaletteFor(CacheThemeId.light), onSpot: spots.add))),
      ));
      await tester.pump();
      final p = el.profile!;
      final chart = tester.getRect(find.byKey(const ValueKey('preview-elevation-chart')));
      await tester.tapAt(Offset(chart.right - 10, chart.center.dy));
      expect(spots.single, closeTo(1, 1e-9));
      await tester.tap(find.byKey(const ValueKey('preview-elevation-highest')));
      expect(spots.last, closeTo(p.highest!.distM / p.totalM, 1e-9));
      await tester.tap(find.byKey(const ValueKey('preview-elevation-lowest')));
      expect(spots.last, closeTo(p.lowest!.distM / p.totalM, 1e-9));
    });

    test('a share of the route is shown at that point along its line', () async {
      final r = DriveRig();
      await r.setUp();
      addTearDown(r.tearDown);
      r.nav.showAlongRoute(0.5);
      expect(r.nav.mapShow, isNull, reason: 'no route: nothing to show');
      await r.guide();
      r.nav.showAlongRoute(0);
      final start = r.nav.route!.points.first;
      expect((r.nav.mapShow?.at?.lat, r.nav.mapShow?.at?.lon), (start.lat, start.lon));
      r.nav.showAlongRoute(1);
      final end = r.nav.route!.points.last;
      expect(r.nav.mapShow!.at!.lon, closeTo(end.lon, 1e-9));
    });
  });

  group('7: the drive screen (a car connected and guiding)', () {
    Future<_Maps> driving(WidgetTester tester) async {
      final m = _Maps();
      await m.pump(tester);
      await tester.runAsync(() => m.rig.guide());
      m.rig.at(1, 400);
      m.drive.carConnected.value = true;
      await m.settle(tester);
      expect(find.byKey(const ValueKey('drive-screen')), findsOneWidget);
      expect(m.drive.signal.value, isTrue);
      return m;
    }

    testWidgets('a turn\'s row and a stop\'s row show that spot on the phone\'s map; Back brings the drive screen again', (tester) async {
      final m = await driving(tester);
      final stop = m.nav.route!.maneuvers[3];
      expect(stop.type, 'via');
      await tester.tap(find.byKey(const ValueKey('drive-row-3')));
      await m.settle(tester);
      expect(find.byKey(const ValueKey('drive-screen')), findsNothing, reason: 'the map is on the tab');
      expect(find.byType(MapLibreMap), findsOneWidget);
      expect(m.drive.signal.value, isFalse, reason: 'the car is told the drive screen is not showing');
      _near(m.lastMove('newLatLngZoom'), stop.lat, stop.lon);
      expect(m.marked(), isNotNull);
      expect(m.maps.follow, FollowMode.free, reason: 'the map stays on the spot');
      // Back: the drive screen again.
      await tester.binding.handlePopRoute();
      await m.settle(tester);
      expect(find.byKey(const ValueKey('drive-screen')), findsOneWidget);
      expect(m.drive.signal.value, isTrue);
      // A turn's row.
      final turn = m.nav.route!.maneuvers[2];
      await tester.tap(find.byKey(const ValueKey('drive-row-2')));
      await m.settle(tester);
      _near(m.lastMove('newLatLngZoom'), turn.lat, turn.lon);
      await tester.binding.handlePopRoute();
      await m.settle(tester);
      expect(find.byKey(const ValueKey('drive-screen')), findsOneWidget);
      await m.finish(tester);
    });

    testWidgets('the route mini map shows the whole route on the phone\'s map', (tester) async {
      final m = await driving(tester);
      final before = m.camera.cameras.length;
      await tester.tap(find.byKey(const ValueKey('drive-mini-map')));
      await m.settle(tester);
      expect(find.byKey(const ValueKey('drive-screen')), findsNothing);
      final fit = m.lastMove('newLatLngBounds');
      expect(fit, isNotNull);
      expect(m.camera.cameras.indexOf(fit) >= before, isTrue, reason: 'a fit made after the tap');
      expect(m.marked(), isNull, reason: 'no spot is marked for the whole route');
      // The car leaving ends it too: the map stays, as it does whenever the car goes.
      m.drive.carConnected.value = false;
      await m.settle(tester);
      expect(find.byType(MapLibreMap), findsOneWidget);
      m.drive.carConnected.value = true;
      await m.settle(tester);
      expect(find.byKey(const ValueKey('drive-screen')), findsOneWidget, reason: 'a car coming back shows the drive screen again');
      await m.finish(tester);
    });
  });

  group('8: My layers', () {
    testWidgets('a notebook and a repeater list open by name (their switches still switch), and Show after Add from a file opens the new notebook', (tester) async {
      final dir = Directory.systemTemp.createTempSync('link-layers-');
      final location = LocationService(source: FakeSource(), settingsDirOverride: dir);
      final engine = TestLayerEngine();
      final maps = MapsState(engine: engine, settingsDirOverride: dir);
      final store = FakeNotebookBackend();
      final nb = fakeNotebook(store);
      final u = UserLayersState((call, [arg]) async => switch (call) {
            'list' => {
                'layers': const [],
                'repeater_lists': [
                  {'id': 'l1', 'kind': 'repeaters', 'name': 'Club list', 'visible': true, 'repeaters': 4},
                ],
              },
            _ => <String, dynamic>{},
          });
      late Notebook book;
      await tester.runAsync(() async {
        await location.init();
        await engine.start();
        await nb.start();
        book = await nb.ensureSavedPlaces();
        await nb.saveEntry(notebookId: book.id, occurredAt: '2026-10-27T10:00:00-06:00', title: 'Spring box', place: const NbPlace(lat: 42.54, lon: -113.62));
        await nb.reload();
        await u.reload();
      });
      final notebooks = <String>[], lists = <String>[];
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Scaffold(
          body: LayerSheet(
            maps: maps,
            location: location,
            notebooks: nb,
            userLayers: u,
            onOpenNotebook: notebooks.add,
            onOpenList: lists.add,
            pickRepeaters: (use) async => const RepeaterUpdate(notebookId: 'nb-new', added: 4),
          ),
        ),
      ));
      await tester.pump();
      final row = find.byKey(ValueKey('my-layer-${book.id}'));
      expect(row, findsOneWidget);
      await tester.tap(find.descendant(of: row, matching: find.text(book.name)));
      expect(notebooks, [book.id]);
      final was = nb.notebook(book.id)!.map;
      await tester.tap(find.byKey(ValueKey('my-layer-switch-${book.id}')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(notebooks, [book.id], reason: 'the switch does not open it');
      expect(store.notebooks.firstWhere((n) => n['id'] == book.id)['map'] == true, !was, reason: 'the switch switched it');
      await tester.tap(find.text('Club list'));
      expect(lists, ['l1']);
      await tester.ensureVisible(find.byKey(const ValueKey('my-layers-add')));
      await tester.tap(find.byKey(const ValueKey('my-layers-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-file-repeaters')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('repeaters-added')), findsOneWidget);
      await tester.tap(find.text('Show'));
      expect(notebooks, [book.id, 'nb-new']);
      await tester.pumpWidget(const SizedBox.shrink());
      maps.dispose();
      location.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    });
  });

  group('11: the car\'s stop rows', () {
    test('the car is sent where each stop is, so its row can show it on the car\'s map', () async {
      final r = DriveRig();
      await r.setUp();
      addTearDown(r.tearDown);
      await r.guide();
      final stops = (carTrip(r.nav)['stops'] as List).cast<Map>();
      expect(stops, hasLength(1));
      expect((stops.single['lat'], stops.single['lon']), (driveStop.lat, driveStop.lon));
    });
  });

  group('10: a guidance notification\'s tap', () {
    test('asks for the Maps tab once, from the native side at start or while the app runs', () async {
      const channel = MethodChannel('co.cache/open/test');
      var pending = 'maps';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'take') return null;
        final p = pending;
        pending = '';
        return p.isEmpty ? null : p;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final inbox = OpenMapsInbox(channel: channel);
      var heard = 0;
      inbox.addListener(() => heard++);
      await inbox.start();
      expect(inbox.pending, isTrue, reason: 'the tap that started the app');
      expect(inbox.take(), isTrue);
      expect(inbox.take(), isFalse, reason: 'once');
      // A tap while the app runs comes as `open`.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('open', 'maps')),
        (_) {},
      );
      expect(inbox.take(), isTrue);
      inbox.offer('weather');
      expect(inbox.pending, isFalse, reason: 'only the Maps tab is asked for here');
      expect(heard, 2);
    });
  });
}

Future<({double lat, double lon})?> _noHere() async => null;
Future<List<NbPlace>> _noSaved() async => const [];

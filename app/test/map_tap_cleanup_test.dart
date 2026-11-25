// Map tap cleanup: a tap on open ground drops a pin (and a second one moves it), an area opens only from its label, the pin card's
// county line opens the county, an area's card has no dot and a pin and a destination are a map pin, and while choosing directions a
// tap on empty map, a swipe down on the panel and the system Back each return to the place card (Back again closes it). Every name
// and place here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/route_panel.dart';
import 'package:cache/regions/area_lookup.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/drive_rig.dart';
import 'support/test_layer_engine.dart';

Map<String, dynamic> _raw(String type, Object coords, Map<String, dynamic> props) => {
      'type': 'Feature',
      'geometry': {'type': type, 'coordinates': coords},
      'properties': props,
    };

RegionRecord _region(String id, String name, String kind, {String? cls, int? pop, double? area, List<double>? bbox}) => RegionRecord.fromJson({
      'id': id,
      'name': name,
      'kind': kind,
      'class': cls,
      'region_code': 'US-ID',
      'population': pop,
      'area_km2': area,
      'bbox': bbox ?? [-113.6, 42.4, -113.4, 42.6],
      'polygon': 'polygons/$id.geojson',
    });

final RegionRecord _town = _region('us-id-quillmoor', 'Quillmoor', 'locality', cls: 'city', pop: 49764, area: 50.4);
final RegionRecord _county = _region('us-id-quill-county', 'Quill County', 'county', pop: 82375, area: 4988, bbox: [-114.0, 42.0, -113.0, 43.0]);
final RegionRecord _state = _region('us-id', 'Idaho', 'region', pop: 2001619, area: 215996);

Map<String, dynamic> _square(double w, double s, double e, double n) => {
      'type': 'Polygon',
      'coordinates': [
        [[w, s], [e, s], [e, n], [w, n], [w, s]],
      ],
    };

class _Areas implements AreaSource {
  AreaHit? hit = AreaHit(town: _town, county: _county, state: _state);

  @override
  Future<AreaHit?> areaAtPoint(double lat, double lon) async => hit;

  @override
  Future<Map<String, dynamic>?> storedGeometry(RegionRecord r) async => _square(r.bbox![0], r.bbox![1], r.bbox![2], r.bbox![3]);

  @override
  List<RegionRecord> townsIn(RegionRecord county, {int limit = 3}) => [_town];
}

/// The fake map: a tap's query answers from [hits] by layer (the base map's labels under 'places_locality').
class _Cam extends CameraController {
  final Map<String, List<Map<String, dynamic>>> hits = {};

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #queryRenderedFeaturesInRect || i.memberName == #queryRenderedFeatures) {
      final layers = (i.positionalArguments[1] as List).cast<String>();
      final out = <Map<String, dynamic>>[];
      for (final l in layers) {
        final h = hits[l] ?? (l.startsWith('places_locality') ? hits['places_locality'] : null);
        if (h != null && !out.any((o) => h.contains(o))) out.addAll(h);
      }
      return Future<List<dynamic>>.value(List<dynamic>.of(out));
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
  final _Areas areas = _Areas();
  late MapLibreMap map;
  late MapLibrePlatform Function() _platform;

  DriveNav get nav => rig.nav;

  Future<void> pump(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    areaFitSettle = Duration.zero;
    addTearDown(() => areaFitSettle = const Duration(milliseconds: 300));
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    dir = Directory.systemTemp.createTempSync('map-cleanup-');
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
                {'id': 'l2', 'kind': 'repeaters', 'name': 'Magic Valley', 'visible': true, 'repeaters': 1},
              ],
            },
          'get' when arg == 'l2' => {
              'id': 'l2',
              'name': 'Magic Valley',
              'repeaters': [
                {'item': 1, 'address': 'repeater:l2/1', 'name': 'K7ABC', 'town': 'Twin Falls', 'lat': 42.56, 'lon': -113.46, 'frequency': '146.940 MHz', 'list': 'Magic Valley'},
              ],
            },
          _ => <String, dynamic>{'features': <Object>[]},
        });
    await tester.runAsync(() async {
      await rig.setUp();
      await location.init();
      await engine.start();
      await userLayers.reload();
    });
    maps.setOn('basemap', true);
    rig.backend.onRoute = (to, mode, from) async => MapRoute.fromJson(driveRouteJson(withStop: false));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: MapsScreen(
        location: location,
        maps: maps,
        nav: nav,
        themeId: CacheThemeId.dark,
        glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
        elevation: rig.elevation,
        userLayers: userLayers,
        areas: areas,
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
    // A street-level view, as a person taps at: a route line is a few metres wide on the ground, not a country.
    map.onCameraMove!(const CameraPosition(target: LatLng(42.5, -113.5), zoom: 14));
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> tap(WidgetTester tester, double lat, double lon) async {
    map.onMapClick!(const math.Point<double>(100, 100), LatLng(lat, lon));
    await settle(tester);
  }

  /// Opens the pin card at the spot and then Directions to it.
  Future<void> directionsFromPin(WidgetTester tester) async {
    await tap(tester, 42.5, -113.5);
    expect(nav.selected?.matched, 'pin');
    await tester.tap(find.byKey(const ValueKey('place-directions')));
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    expect(nav.phase, NavPhase.previewing);
    expect(find.byKey(const ValueKey('route-start')), findsOneWidget);
  }

  /// The place the card shows, the search bar's text and whether the place card is up.
  String get barText => (find.byKey(const ValueKey('map-search-field')).evaluate().single.widget as TextField).controller!.text;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    MapLibrePlatform.createInstance = _platform;
    camera.dispose();
    maps.dispose();
    userLayers.dispose();
    await tester.runAsync(() async {
      rig.tearDown();
      location.dispose();
      await dir.delete(recursive: true);
    });
  }
}

int _outlineFeatures(_Maps m) => ((m.camera.sources[kAreaSource]?['features'] as List?) ?? const []).length;

/// The features of the pin source with this role.
List<Map> _pinFeatures(_Maps m, String role) => [
      for (final f in (m.camera.sources[kPinSource]?['features'] as List? ?? const []))
        if (((f as Map)['properties'] as Map)['role'] == role) f['properties'] as Map,
    ];

void main() {
  group('a) a tap on open ground drops a pin; an area opens from its label only', () {
    testWidgets('open ground inside a town drops a pin and opens the pin card with Directions; no area opens, no outline', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.id, 'loc:42.500000,-113.500000');
      expect(m.nav.selected?.matched, 'pin');
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-save')), findsOneWidget);
      expect(_outlineFeatures(m), 0, reason: 'no town outline: the ground was tapped, not the town\'s label');
      await m.finish(tester);
    });

    testWidgets('a town\'s label opens the town (its card and outline)', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.hits['places_locality'] = [_raw('Point', [-113.5, 42.5], {'name': 'Quillmoor'})];
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.id, 'area:us-id-quillmoor');
      expect(_outlineFeatures(m), 1);
      expect(find.text('About 49,800 people'), findsOneWidget);
      await m.finish(tester);
    });

    testWidgets('a second tap on open ground while a pin card is open moves the pin and its card to the new spot', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.tap(tester, 42.5, -113.5);
      final first = m.nav.selected!;
      expect(first.id, 'loc:42.500000,-113.500000');
      await m.tap(tester, 42.7, -113.2);
      final second = m.nav.selected!;
      expect(second.id, 'loc:42.700000,-113.200000', reason: 'moved, not closed');
      expect(second.matched, 'pin');
      expect((second.lat, second.lon), (42.7, -113.2));
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      expect(find.text(second.name), findsWidgets, reason: 'the card names the new spot');
      expect(m.barText, second.name);
      await m.finish(tester);
    });

    testWidgets('the county line of the pin card opens that county\'s card, even where a town is also there', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.tap(tester, 42.5, -113.5);
      expect(find.byKey(const ValueKey('place-county')), findsOneWidget);
      expect(find.text('Quill County, ID'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('place-county')));
      await m.settle(tester);
      expect(m.nav.selected?.id, 'area:us-id-quill-county');
      expect(find.text('County in Idaho'), findsOneWidget);
      expect(find.byKey(const ValueKey('place-directions')), findsNothing, reason: 'a county has no Directions');
      expect(_outlineFeatures(m), 1, reason: 'the county outline');
      await m.finish(tester);
    });

    testWidgets('a town card\'s county line ("Quill County, ID") also opens the county', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.hits['places_locality'] = [_raw('Point', [-113.5, 42.5], {'name': 'Quillmoor'})];
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.id, 'area:us-id-quillmoor');
      await tester.tap(find.byKey(const ValueKey('place-county')));
      await m.settle(tester);
      expect(m.nav.selected?.id, 'area:us-id-quill-county');
      await m.finish(tester);
    });

    testWidgets('the map slides so the dropped pin shows above the card: the camera centre is below the pin', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.cameras.clear();
      await m.tap(tester, 42.5, -113.5);
      await m.settle(tester);
      expect(m.camera.cameras, isNotEmpty, reason: 'the map moved');
      final last = m.camera.cameras.last as List;
      expect(last.first, 'newCameraPosition', reason: 'moved to an offset centre, not onto the pin itself: $last');
      final target = (last[1] as Map)['target'] as List;
      expect(target[0] as num, lessThan(42.5), reason: 'the centre is south of the pin, so the pin is drawn north of the middle, above the card');
      await m.finish(tester);
    });
  });

  group('b) markers', () {
    for (final (label, place) in [
      ('a coordinate search result', const MapPlace(id: 'coords:42.5,-113.5', type: 'coordinates', name: '42.5, -113.5', kind: 'Coordinates', address: '', lat: 42.5, lon: -113.5, matched: 'name')),
      ('a searched place', const MapPlace(id: 'place:test:boise', type: 'place', name: 'Boise', kind: 'City', address: 'Ada County, ID', lat: 42.5, lon: -113.5, matched: 'name')),
    ]) {
      testWidgets('$label: the map slides so its pin shows above the card, as for a tap on open ground', (tester) async {
        final m = _Maps();
        await m.pump(tester);
        m.camera.cameras.clear();
        await tester.runAsync(() async => m.nav.select(place));
        await m.settle(tester);
        expect(m.camera.cameras, isNotEmpty, reason: 'the map moved');
        final last = m.camera.cameras.last as List;
        expect(last.first, 'newCameraPosition', reason: 'moved to an offset centre, not onto the pin itself: $last');
        final target = (last[1] as Map)['target'] as List;
        expect(target[0] as num, lessThan(42.5), reason: 'the centre is south of the pin, so the pin is drawn above the card');
        await m.finish(tester);
      });
    }

    testWidgets('an area\'s card draws no dot (only its outline); a dropped pin is drawn as a map pin image', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.hits['places_locality'] = [_raw('Point', [-113.5, 42.5], {'name': 'Quillmoor'})];
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.id, 'area:us-id-quillmoor');
      await m.settle(tester);
      expect(_pinFeatures(m, 'selected'), isEmpty, reason: 'no red dot on an area');
      expect(_outlineFeatures(m), 1);
      m.camera.hits.clear();
      m.nav.clearSelection();
      await m.tap(tester, 42.5, -113.5);
      // The pin image is drawn with real image work.
      for (var i = 0; i < 40 && _pinFeatures(m, 'selected').isEmpty || (_pinFeatures(m, 'selected').isNotEmpty && _pinFeatures(m, 'selected').first['pin'] == null && i < 40); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      final sel = _pinFeatures(m, 'selected');
      expect(sel, hasLength(1));
      expect(sel.single['pin'], isNotNull, reason: 'a map pin image, not the plain dot');
      await m.finish(tester);
    });

    testWidgets('the destination while choosing directions is the same map pin', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.directionsFromPin(tester);
      for (var i = 0; i < 40 && (_pinFeatures(m, 'selected').isEmpty || _pinFeatures(m, 'selected').first['pin'] == null); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(_pinFeatures(m, 'selected').single['pin'], isNotNull);
      await m.finish(tester);
    });

    testWidgets('a place that is not a pin keeps its dot while no directions are chosen', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await tester.runAsync(() async {
        m.nav.select(const MapPlace(id: 'place:test:a', type: 'place', name: 'Cascade Park', kind: 'Park', lat: 42.5, lon: -113.5, matched: 'name'));
      });
      await m.settle(tester);
      expect(_pinFeatures(m, 'selected').single['pin'], isNull);
      await m.finish(tester);
    });
  });

  group('e) the routes on the map', () {
    Future<void> threeRoutes(WidgetTester tester, _Maps m) async {
      m.rig.backend.onRoute = (to, mode, from) async {
        final j = fakeRouteJson(id: 'r1', name: 'Walmart');
        j['duration_s'] = 14 * 60.0;
        final b = fakeRouteJson(id: 'r2', alt: 3);
        b['duration_s'] = 15 * 60.0;
        final c = fakeRouteJson(id: 'r3', alt: 6);
        c['duration_s'] = 17 * 60.0;
        j['alternatives'] = [b, c];
        return MapRoute.fromJson(j);
      };
      await tester.runAsync(() => m.nav.openDirections(const MapPlace(id: 'place:t:w', type: 'place', name: 'Walmart', kind: '', address: '', lat: 42.5, lon: -113.5, matched: 'name')));
      await m.settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(m.nav.routes, hasLength(3));
    }

    List<Map> labels(_Maps m) => [
          for (final f in (m.camera.sources[kRouteSource]?['features'] as List? ?? const []))
            if ((f as Map)['geometry']['type'] == 'Point') f['properties'] as Map,
        ];

    testWidgets('every route has a time label in the panel\'s words; the chosen one is the filled one; the styles follow the selection', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await threeRoutes(tester, m);
      var l = labels(m);
      expect(l, hasLength(3));
      expect({for (final p in l) p['label']}, {'14 min', '15 min', '17 min'});
      expect({for (final p in l) p['route']: p['sel']}, {0: true, 1: false, 2: false});
      expect(find.text('14 min · ${m.nav.fmt.distance(m.nav.routes[0].distanceM)}'), findsOneWidget, reason: 'the panel says what the label says');
      await tester.runAsync(() async => m.nav.selectRoute(2));
      await m.settle(tester);
      for (var i = 0; i < 40 && labels(m).firstWhere((p) => p['sel'] == true)['route'] != 2; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      l = labels(m);
      expect({for (final p in l) p['route']: p['sel']}, {0: false, 1: false, 2: true});
      expect(l.firstWhere((p) => p['sel'] == true)['img'], 'route-time-sel-17 min');
      expect(find.text('17 min · ${m.nav.fmt.distance(m.nav.routes[2].distanceM)}'), findsOneWidget);
      await m.finish(tester);
    });

    testWidgets('a tap on a faded alternate\'s line selects it', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await threeRoutes(tester, m);
      expect(m.nav.routeIndex, 0);
      final alt = m.nav.routes[1].points[20];
      await m.tap(tester, alt.lat, alt.lon);
      expect(m.nav.routeIndex, 1);
      expect(m.nav.phase, NavPhase.previewing);
      // The label image is drawn (real work) before the labels are pushed.
      for (var i = 0; i < 40 && labels(m).firstWhere((p) => p['sel'] == true)['route'] != 1; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(labels(m).firstWhere((p) => p['sel'] == true)['route'], 1);
      await m.finish(tester);
    });

    testWidgets('the camera frames all the routes inside the map above the panel: the fit holds every route and its bottom padding clears the panel', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.cameras.clear();
      await threeRoutes(tester, m);
      await m.settle(tester);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      final probe = CameraUpdate.newLatLngBounds(LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(1, 1)), left: 11, top: 12, right: 13, bottom: 14).toJson() as List<dynamic>;
      double pad(List<dynamic> u, double v) => (u[probe.indexOf(v)] as num).toDouble();
      final fits = m.camera.cameras.cast<List<dynamic>>().where((u) => u.first == 'newLatLngBounds').toList();
      expect(fits, isNotEmpty);
      final u = fits.last;
      final a = [for (final n in (u[1] as List)[0] as List) (n as num).toDouble()], b = [for (final n in (u[1] as List)[1] as List) (n as num).toDouble()];
      final south = a[0] < b[0] ? a[0] : b[0], north = a[0] < b[0] ? b[0] : a[0];
      final west = a[1] < b[1] ? a[1] : b[1], east = a[1] < b[1] ? b[1] : a[1];
      for (final r in m.nav.routes) {
        final bb = r.bounds;
        expect(south, lessThanOrEqualTo(bb[0] + 1e-9));
        expect(west, lessThanOrEqualTo(bb[1] + 1e-9));
        expect(north, greaterThanOrEqualTo(bb[2] - 1e-9));
        expect(east, greaterThanOrEqualTo(bb[3] - 1e-9));
      }
      final panel = tester.getRect(find.byType(RoutePanel));
      final map = tester.getSize(find.byType(MapLibreMap));
      expect(pad(u, 14), greaterThanOrEqualTo(map.height - panel.top - 1), reason: 'the routes are framed above the panel (its ${map.height - panel.top} points)');
      expect(pad(u, 12), greaterThan(0), reason: 'and below the header');
      // Choosing another route does not move the camera again.
      final before = fits.length;
      await tester.runAsync(() async => m.nav.selectRoute(1));
      await m.settle(tester);
      expect(m.camera.cameras.cast<List<dynamic>>().where((x) => x.first == 'newLatLngBounds').length, before);
      await m.finish(tester);
    });
  });

  group('c) going back while choosing directions', () {
    Future<void> expectPlaceCard(WidgetTester tester, _Maps m, MapPlace place) async {
      await m.settle(tester);
      expect(m.nav.phase, NavPhase.browsing);
      expect(m.nav.selected?.id, place.id, reason: 'the place the directions came from');
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-start')), findsNothing);
      expect(m.barText, place.name, reason: 'the search bar shows the place\'s name, not "Search places or coordinates"');
    }

    Future<void> backAgainCloses(WidgetTester tester, _Maps m) async {
      expect(await tester.binding.handlePopRoute(), isTrue, reason: 'Back again is taken');
      await m.settle(tester);
      expect(m.nav.selected, isNull, reason: 'it closed the place card');
      expect(find.byKey(const ValueKey('place-card-name')), findsNothing);
      expect(await tester.binding.handlePopRoute(), isFalse, reason: 'with no card Back is the system\'s');
    }

    testWidgets('a tap on empty map returns to the place card; Back closes it', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.directionsFromPin(tester);
      final place = m.nav.selected!;
      await m.tap(tester, 42.9, -113.9);
      await expectPlaceCard(tester, m, place);
      await backAgainCloses(tester, m);
      await m.finish(tester);
    });

    testWidgets('a swipe down on the directions panel returns to the place card; Back closes it', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.directionsFromPin(tester);
      final place = m.nav.selected!;
      await tester.flingFrom(tester.getCenter(find.byKey(const ValueKey('route-panel-swipe'))), const Offset(0, 200), 1500);
      await tester.pump(const Duration(milliseconds: 300));
      await expectPlaceCard(tester, m, place);
      await backAgainCloses(tester, m);
      await m.finish(tester);
    });

    testWidgets('the system Back (Android gesture and button, iOS edge swipe: all arrive as Back) returns to the place card; Back closes it', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.directionsFromPin(tester);
      final place = m.nav.selected!;
      expect(await tester.binding.handlePopRoute(), isTrue, reason: 'the screen took Back (it did not leave Maps)');
      await expectPlaceCard(tester, m, place);
      await backAgainCloses(tester, m);
      await m.finish(tester);
    });

    testWidgets('a place card that was a searched place returns with its name in the bar', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      const boise = MapPlace(id: 'place:test:boise', type: 'place', name: 'Boise', kind: 'City', address: 'Ada County, ID', lat: 42.5, lon: -113.5, matched: 'name');
      await tester.runAsync(() async => m.nav.select(boise));
      await m.settle(tester);
      await tester.tap(find.byKey(const ValueKey('place-directions')));
      await m.settle(tester);
      expect(m.nav.phase, NavPhase.previewing);
      await tester.tap(find.byTooltip('Back'));
      await m.settle(tester);
      await expectPlaceCard(tester, m, boise);
      await m.finish(tester);
    });

    testWidgets('a tap on a repeater while choosing directions still opens that repeater; only empty map is back', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      await m.directionsFromPin(tester);
      m.camera.hits[kUserRepeaters] = [_raw('Point', [-113.46, 42.56], {'list': 'l2', 'item': 1, 'name': 'K7ABC'})];
      await m.tap(tester, 42.56, -113.46);
      expect(m.userLayers.selectedRepeater.value?.name, 'K7ABC', reason: 'the repeater opened');
      expect(m.nav.phase, NavPhase.previewing, reason: 'the directions stay');
      m.camera.hits.clear();
      await m.tap(tester, 42.9, -113.9);
      expect(m.nav.phase, NavPhase.browsing, reason: 'empty map is back');
      await m.finish(tester);
    });
  });
}

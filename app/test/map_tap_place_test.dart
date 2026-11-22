// Link fixes, batch 3: a tap on a place, a town, a point of interest or a named feature on the phone's map opens its card. The
// choice is a pure function (map_tap.dart); the Maps screen asks the map what is under the tap and opens what it chooses. Every name
// and place here is made up.

import 'dart:io';
import 'dart:math' as math;

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/map_tap.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'location_service_test.dart' show FakeSource;
import 'navigation_camera_test.dart' show CameraController, NoSurface;
import 'support/drive_rig.dart';
import 'support/test_layer_engine.dart';

// ---- the pure choice ------------------------------------------------------------------------------------------------------

TapFeature _f(TapSource source, TapTier tier, {String? name, String kind = '', double lat = 42.5, double lon = -113.5, String? notebookId}) =>
    TapFeature(source: source, tier: tier, name: name, kind: kind, lat: lat, lon: lon, notebookId: notebookId);

extension on TapFeature {
  TapFeature poiCopy({String rawKind = ''}) => TapFeature(source: source, tier: tier, name: name, kind: kind, lat: lat, lon: lon, poi: true, rawKind: rawKind);
}

MapPlace _place(String id, String name, double lat, double lon, {String type = 'place', String kind = 'Village'}) =>
    MapPlace(id: id, type: type, name: name, kind: kind, lat: lat, lon: lon, matched: 'name');

/// One GeoJSON feature as the map's query gives it.
Map<String, dynamic> _raw(String type, Object coords, Map<String, dynamic> props) => {
      'type': 'Feature',
      'geometry': {'type': type, 'coordinates': coords},
      'properties': props,
    };

const Map<String, dynamic> _trailDef = {
  'id': 'test-trails',
  'title': 'Test trails',
  'kind': 'vector',
  'default_on': true,
  'source': {'type': 'pmtiles', 'url': '', 'minzoom': 0, 'maxzoom': 14, 'tile_format': 'mvt'},
  'offline': {'allowed': true},
  'style_hints': {
    'role': 'trails',
    'layers': [
      {'name': 'trails', 'attributes': ['TRAIL_NAME', 'TRAIL_TYPE']},
    ],
  },
};

void _pureTests() {
  group('what a tap chooses', () {
    test('a label first, then a line, then an area; an imported file\'s line before an overlay\'s', () {
      final area = _f(TapSource.overlay, TapTier.area, name: 'Brackwillow Unit', kind: 'Test lands');
      final overlayLine = _f(TapSource.overlay, TapTier.line, name: 'Hollow Fern Trail', kind: 'Test trails');
      final importedLine = _f(TapSource.imported, TapTier.line, name: 'Ridge loop', kind: 'Test book', notebookId: 'nb-1');
      final label = _f(TapSource.basemap, TapTier.label, name: 'Quillmoor');
      expect(pickTapFeature([area, overlayLine, importedLine, label]), same(label));
      expect(pickTapFeature([area, overlayLine, importedLine]), same(importedLine));
      expect(pickTapFeature([area, overlayLine]), same(overlayLine));
      expect(pickTapFeature([area]), same(area));
      expect(pickTapFeature(const []), isNull);
    });

    test('an area under a label: the label opens', () {
      final area = _f(TapSource.imported, TapTier.area, name: 'Camp area', kind: 'Test book', notebookId: 'nb-1');
      final label = _f(TapSource.basemap, TapTier.label, name: 'Larkspur Flats', lat: 42.51, lon: -113.51);
      final c = chooseMapTap([area, label])!;
      expect(c.place.name, 'Larkspur Flats');
      expect(c.notebookId, isNull);
    });

    test('within a kind, a named feature comes before one without a name', () {
      final unnamed = _f(TapSource.imported, TapTier.line, kind: 'Test book');
      final named = _f(TapSource.overlay, TapTier.line, name: 'Hollow Fern Trail', kind: 'Test trails');
      expect(pickTapFeature([unnamed, named]), same(named));
    });

    test('a label is matched to the places data by its name and its point: the nearest of that name within reach', () {
      final label = _f(TapSource.basemap, TapTier.label, name: 'Quillmoor', lat: 42.5, lon: -113.5);
      final near = _place('town:test:q1', 'Quillmoor', 42.5005, -113.5005);
      final farther = _place('place:test:q2', 'quillmoor', 42.502, -113.5);
      final faraway = _place('town:test:q3', 'Quillmoor', 43.5, -112.0);
      final other = _place('town:test:q4', 'Quillmoor Junction', 42.5, -113.5);
      final category = _place('category:test:q5', 'Quillmoor', 42.5, -113.5, type: 'category');
      expect(matchLabelPlace(label, [faraway, other, category, farther, near], reachM: 500)?.id, 'town:test:q1');
      // Letter case and spacing aside, the same name.
      expect(matchLabelPlace(label, [farther], reachM: 500)?.id, 'place:test:q2');
      expect(matchLabelPlace(label, [faraway, other, category], reachM: 500), isNull);
      expect(matchLabelPlace(label, [farther], reachM: 50), isNull, reason: 'out of reach');
    });

    test('a matched label opens that place, as a search result does', () {
      final label = _f(TapSource.basemap, TapTier.label, name: 'Quillmoor', lat: 42.5, lon: -113.5);
      final town = _place('town:test:q1', 'Quillmoor', 42.5001, -113.5001);
      final c = chooseMapTap([label], candidates: [town], reachM: 500)!;
      expect(c.place, same(town));
    });

    test('a chip opens the place it is linked to and is never matched by name and distance; no link is the no-details card', () {
      final chip = _f(TapSource.basemap, TapTier.label, name: 'Shoshone Falls', kind: 'Landmark', lat: 42.596, lon: -114.402).poiCopy(rawKind: 'attraction');
      final attraction = _place('place:osm:n1671534021', 'Shoshone Falls', 42.596, -114.402, kind: 'Attraction');
      final park = _place('place:osm:w121853382', 'Shoshone Falls', 42.5933, -114.4003, kind: 'Park');
      // The park is a same-named place 300 m away: the old name-and-distance match could pick it. A chip uses only its link.
      expect(chooseMapTap([chip], candidates: [park], reachM: 500)!.place.matched, kPoiMatched, reason: 'candidates are not looked at for a chip');
      expect(chooseMapTap([chip], candidates: [park], linked: attraction, reachM: 500)!.place, same(attraction));
      expect(chooseMapTap([chip])!.place.id, startsWith('loc:'));
    });

    test('places data from before the links (old build): a chip is matched by name and distance, as a label is (transition fallback)', () {
      final chip = _f(TapSource.basemap, TapTier.label, name: 'Shoshone Falls', kind: 'Park', lat: 42.5933, lon: -114.4003).poiCopy(rawKind: 'park');
      final park = _place('place:osm:w121853382', 'Shoshone Falls', 42.5933, -114.4003, kind: 'Park');
      expect(chooseMapTap([chip], candidates: [park], linksPresent: false, reachM: 500)!.place, same(park));
      expect(chooseMapTap([chip], candidates: [park], linksPresent: true, reachM: 500)!.place.matched, kPoiMatched, reason: 'new data: links only');
    });

    test('no match: the label\'s name at its point, so Directions go there', () {
      final label = _f(TapSource.basemap, TapTier.label, name: 'Larkspur Flats', lat: 42.51, lon: -113.52);
      final c = chooseMapTap([label], candidates: [_place('town:test:x', 'Elsewhere', 42.51, -113.52)])!;
      expect(c.place.name, 'Larkspur Flats');
      expect(c.place.kind, '');
      expect(c.place.id, 'loc:42.510000,-113.520000');
      expect(c.place.lat, 42.51);
      expect(c.place.lon, -113.52);
      expect(c.place.isCoordinates, isFalse);
      expect(c.place.isNotebookPlace, isFalse);
      expect(c.notebookId, isNull);
    });

    test('an overlay\'s feature: its name and its layer, at the tapped spot; one without a name is called by its layer', () {
      final c = chooseMapTap([_f(TapSource.overlay, TapTier.line, name: 'Hollow Fern Trail', kind: 'Test trails', lat: 42.6, lon: -113.4)])!;
      expect((c.place.name, c.place.kind, c.place.lat, c.place.lon), ('Hollow Fern Trail', 'Test trails', 42.6, -113.4));
      expect(c.place.id, startsWith('loc:'));
      final u = chooseMapTap([_f(TapSource.overlay, TapTier.area, kind: 'Test lands')])!;
      expect((u.place.name, u.place.kind), ('Test lands', ''));
    });

    test('an imported file\'s feature: named by its notebook, with Open to it and no Save', () {
      final c = chooseMapTap([_f(TapSource.imported, TapTier.area, name: 'Camp area', kind: 'Test book', notebookId: 'nb-1')])!;
      expect((c.place.name, c.place.kind), ('Camp area', 'Test book'));
      expect(c.notebookId, 'nb-1');
      expect(c.place.isNotebookPlace, isTrue);
      expect(notebookEntryFor(c.place, const []), isNull);
    });
  });

  group('reading the map\'s features', () {
    test('a base-map label is a label at its own point whatever its geometry, and only with a name', () {
      final town = tapFeatureFrom(_raw('Point', [-113.49, 42.49], {'name': 'Quillmoor', 'kind': 'locality'}), source: TapSource.basemap, kind: '', tapLat: 42.5, tapLon: -113.5)!;
      expect((town.tier, town.name, town.lat, town.lon), (TapTier.label, 'Quillmoor', 42.49, -113.49));
      final road = tapFeatureFrom(_raw('LineString', [[-113.6, 42.5], [-113.4, 42.5]], {'name': 'Tamwhistle Road'}), source: TapSource.basemap, kind: '', tapLat: 42.5, tapLon: -113.5)!;
      expect((road.tier, road.lat, road.lon), (TapTier.label, 42.5, -113.5));
      expect(tapFeatureFrom(_raw('Point', [-113.49, 42.49], {'kind': 'locality'}), source: TapSource.basemap, kind: '', tapLat: 42.5, tapLon: -113.5), isNull);
    });

    test('an overlay\'s or a file\'s feature is a line or an area by its geometry; a point is none', () {
      TapFeature? r(String type) => tapFeatureFrom(_raw(type, const [], {'TRAIL_NAME': 'Hollow Fern Trail'}), source: TapSource.overlay, kind: 'Test trails', tapLat: 1, tapLon: 2);
      expect(r('LineString')?.tier, TapTier.line);
      expect(r('MultiLineString')?.tier, TapTier.line);
      expect(r('Polygon')?.tier, TapTier.area);
      expect(r('MultiPolygon')?.tier, TapTier.area);
      expect(r('Point'), isNull);
      expect((r('LineString')!.name, r('LineString')!.lat, r('LineString')!.lon), ('Hollow Fern Trail', 1.0, 2.0));
      expect(tapFeatureFrom('nonsense', source: TapSource.overlay, kind: '', tapLat: 0, tapLon: 0), isNull);
    });

    test('a public place\'s chip beats a town or road name beside it, which beats a line', () {
      final town = _f(TapSource.basemap, TapTier.label, name: 'Quillmoor');
      final chip = _f(TapSource.basemap, TapTier.label, name: 'Sorrel Park', kind: 'Park').poiCopy();
      final line = _f(TapSource.overlay, TapTier.line, name: 'Hollow Fern Trail');
      expect(pickTapFeature([town, chip, line])?.name, 'Sorrel Park');
      expect(pickTapFeature([line, town, chip])?.name, 'Sorrel Park');
      expect(pickTapFeature([line, town])?.name, 'Quillmoor');
      expect(pickTapFeature([line])?.name, 'Hollow Fern Trail');
    });

    test('a chip is read with its icon\'s name as its kind, named or not', () {
      Map<String, dynamic> raw(Map<String, dynamic> props) => _raw('Point', [-113.5, 42.5], props);
      TapFeature? chip(Map<String, dynamic> props) => tapFeatureFrom(raw(props), source: TapSource.basemap, kind: '', tapLat: 0, tapLon: 0, poi: true);
      expect(chip({'name': 'Cascade Park', 'kind': 'park'})?.kind, 'Park');
      expect(chip({'name': 'Quik Stop', 'kind': 'fuel'})?.kind, 'Fuel');
      expect(chip({'name': 'Chem Mart', 'kind': 'chemist'})?.kind, 'Pharmacy');
      expect(chip({'name': 'X', 'kind': 'church'})?.kind, '');
      expect(chip({'name': 'Cascade Park', 'kind': 'park'})?.poi, isTrue);
      expect(chip({'name': 'Cascade Park', 'kind': 'park'})?.rawKind, 'park', reason: 'the tile\'s own kind is what its link is looked up by');
      expect(chip({'name': 'Chem Mart', 'kind': 'chemist'})?.rawKind, 'chemist');
      expect(chip({'kind': 'park'}), isNotNull, reason: 'a chip with no name still opens a card, named by its kind');
      expect(chip({'kind': 'drinking_water'})?.kind, 'Drinking water');
      expect(tapFeatureFrom(raw({'kind': 'park'}), source: TapSource.basemap, kind: '', tapLat: 0, tapLon: 0), isNull, reason: 'a name label with no name is nothing');
    });

    test('a chip the places data does not have opens a card with its name and kind, marked so the card says it has no details', () {
      final f = _f(TapSource.basemap, TapTier.label, name: 'Cascade Park', kind: 'Park').poiCopy();
      final c = tapChoiceFor(f);
      expect((c.place.name, c.place.kind, c.place.matched), ('Cascade Park', 'Park', kPoiMatched));
      expect(c.place.id, startsWith('loc:'));
      final matched = tapChoiceFor(f, match: _place('place:test:c1', 'Cascade Park', 42.5, -113.5, kind: 'Park'));
      expect(matched.place.id, 'place:test:c1');
      expect(matched.place.matched, isNot(kPoiMatched));
    });

    test('the name comes from the tiles\' name fields', () {
      expect(featureName({'name': 'A'}), 'A');
      expect(featureName({'NAME': 'B'}), 'B');
      expect(featureName({'ROUTE_PRMRY_NM': 'C', 'subset': 'x'}), 'C');
      expect(featureName({'Mang_Name': 'D', 'Unit_Nm': 'E'}), 'E');
      expect(featureName({'name': '  ', 'name:latin': 'F'}), 'F');
      expect(featureName({'class': 'x'}), isNull);
      expect(featureName(null), isNull);
    });

    test('the base map\'s labels are its symbol layers, not the app\'s or an overlay\'s', () {
      const style = '{"layers":[{"id":"water","type":"fill","source":"src-basemap"},{"id":"places_town","type":"symbol","source":"src-basemap"},'
          '{"id":"contours-label","type":"symbol","source":"src-contours"},{"id":"pin-results","type":"symbol","source":"cache-pin"},'
          '{"id":"roads_labels","type":"symbol","source":"src-basemap"}]}';
      expect(basemapLabelLayers(style, basemapSource: 'src-basemap'), ['places_town', 'roads_labels']);
      expect(basemapLabelLayers('not json', basemapSource: 'src-basemap'), isEmpty);
    });

    test('the base map\'s line layers are its line layers, not its symbols or an overlay\'s', () {
      const style = '{"layers":[{"id":"water","type":"fill","source":"src-basemap"},{"id":"path","type":"line","source":"src-basemap"},'
          '{"id":"road_label","type":"symbol","source":"src-basemap"},{"id":"t-line","type":"line","source":"src-t"}]}';
      expect(basemapLineLayers(style, basemapSource: 'src-basemap'), ['path']);
    });

    test('an overlay\'s hit layers are its line and fill layers of the style, from its source', () {
      const style = '{"layers":[{"id":"t-fill","type":"fill","source":"src-t"},{"id":"t-casing","type":"line","source":"src-t"},'
          '{"id":"t-line","type":"line","source":"src-t"},{"id":"o-line","type":"line","source":"src-o"},{"id":"t-sym","type":"symbol","source":"src-t"}]}';
      expect(overlayHitLayers(style, source: 'src-t'), ['t-fill', 't-casing', 't-line']);
      expect(overlayHitLayers('not json', source: 'src-t'), isEmpty);
    });
  });
}

// ---- the Maps screen ------------------------------------------------------------------------------------------------------

/// The fake map: a tap's query (by box or by point) answers from [labels] for the base map's label layers, [trails] for the trail
/// overlay's layers and [user] for the imported files' lines and areas; it records the layers each query asked for.
class _TapCamera extends CameraController {
  final List<Map<String, dynamic>> labels = [];

  /// What the public places' chip layer answers.
  final List<Map<String, dynamic>> pois = [];
  final List<Map<String, dynamic>> trails = [];
  final List<Map<String, dynamic>> user = [];

  /// What the base map's line layers (paths, tracks, roads) answer.
  final List<Map<String, dynamic>> baseLines = [];
  final List<List<String>> asked = [];

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #queryRenderedFeaturesInRect || i.memberName == #queryRenderedFeatures) {
      final layers = (i.positionalArguments[1] as List).cast<String>();
      asked.add(layers);
      final List<Map<String, dynamic>> out;
      if (layers.contains(kUserLines) || layers.contains(kUserAreas)) {
        out = user;
      } else if (layers.any((l) => l.startsWith('test-trails-'))) {
        out = trails;
      } else if (layers.contains('places_locality')) {
        out = labels;
      } else if (layers.contains('pois')) {
        out = pois;
      } else {
        out = baseLines;
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
  final _TapCamera camera = _TapCamera();
  final List<String> openedBooks = [];
  late MapLibreMap map;
  late MapLibrePlatform Function() _platform;

  DriveNav get nav => rig.nav;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    rootBundle.clear();
    dir = Directory.systemTemp.createTempSync('map-tap-');
    _platform = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    final engine = TestLayerEngine(published: const [_trailDef]);
    maps = MapsState(engine: engine, settingsDirOverride: dir);
    rig = DriveRig();
    userLayers = UserLayersState((call, [arg]) async => switch (call) {
          'list' => {
              'layers': [
                {'id': 'L1', 'kind': 'layer', 'name': 'Test book', 'visible': true, 'notebook_id': 'nb-1'},
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
    // The base map (its labels) and the trail overlay are on.
    maps.setOn('basemap', true);
    maps.setOn('test-trails', true);
    expect(maps.uses.map((u) => u.def.id), containsAll(['basemap', 'test-trails']));
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
        onOpenNotebook: openedBooks.add,
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

  Future<void> tap(WidgetTester tester, double lat, double lon) async {
    map.onMapClick!(const math.Point<double>(100, 100), LatLng(lat, lon));
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
    userLayers.dispose();
    await tester.runAsync(() async {
      rig.tearDown();
      location.dispose();
      await dir.delete(recursive: true);
    });
  }
}

void _screenTests() {
  group('the Maps screen', () {
    testWidgets('a town\'s label opens the place of the places data it is, with Directions', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      final town = _place('town:test:q1', 'Quillmoor', 42.5002, -113.5002);
      final searched = <String>[];
      m.rig.backend.onSearch = (q, {near, meaning}) async {
        searched.add(q);
        return MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [_place('town:test:q9', 'Quillmoor', 44.0, -111.0), town]);
      };
      m.camera.labels.add(_raw('Point', [-113.5, 42.5], {'name': 'Quillmoor'}));
      // A trail under the label: the label opens.
      m.camera.trails.add(_raw('LineString', [[-113.6, 42.5], [-113.4, 42.5]], {'TRAIL_NAME': 'Hollow Fern Trail'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.camera.asked.first, allOf(isNotEmpty, isNot(contains(kUserLines))), reason: 'the base map\'s label layers are asked first');
      expect(m.camera.asked.first, contains('places_locality'));
      expect(searched, ['Quillmoor']);
      expect(m.nav.selected?.id, 'town:test:q1');
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
      expect(m.camera.asked.any((l) => l.any((x) => x.startsWith('test-trails-'))), isFalse, reason: 'with a label, the overlays are not asked');
      await m.finish(tester);
    });

    testWidgets('a chip beside a town\'s label opens the chip\'s place, by its link', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      final shop = _place('place:test:s1', 'Sorrel Bakery', 42.5001, -113.5001, kind: 'Bakery');
      m.rig.backend.links[('bakery', 'Sorrel Bakery')] = shop;
      m.camera.labels.add(_raw('Point', [-113.5, 42.5], {'name': 'Quillmoor'}));
      m.camera.pois.add(_raw('Point', [-113.5001, 42.5001], {'name': 'Sorrel Bakery', 'kind': 'bakery'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.camera.asked.any((l) => l.contains('pois')), isTrue, reason: 'the chip layer is asked');
      expect(m.camera.asked.where((l) => l.contains('places_locality')).every((l) => !l.contains('pois')), isTrue, reason: 'on its own, so it can rank first');
      expect(m.rig.backend.linkCalls, ['bakery:Sorrel Bakery'], reason: 'the chip\'s kind and name are its key');
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty, reason: 'a chip is never searched for by name');
      expect(m.nav.selected?.id, 'place:test:s1');
      await m.finish(tester);
    });

    testWidgets('a chip with no place of the places data: its kind and one muted line, with the same three buttons; no Open', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.pois.add(_raw('Point', [-113.5, 42.5], {'name': 'Cascade Park', 'kind': 'park'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.name, 'Cascade Park');
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('Park')), findsOneWidget, reason: 'the kind line, the icon\'s name');
      expect(find.byKey(const ValueKey('place-card-no-details')), findsOneWidget);
      expect(find.text('No other details for this place.'), findsOneWidget);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-save')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-add-home')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-open-entry')), findsNothing);
      await m.finish(tester);
    });

    testWidgets('Shoshone Falls: the attraction chip opens the attraction and the park chip opens the park, each by its link and kind', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      final attraction = _place('place:osm:n1671534021', 'Shoshone Falls', 42.596005, -114.402164, kind: 'Attraction');
      final park = _place('place:osm:w121853382', 'Shoshone Falls', 42.5933, -114.4003, kind: 'Park');
      m.rig.backend.links[('attraction', 'Shoshone Falls')] = attraction;
      m.rig.backend.links[('park', 'Shoshone Falls')] = park;
      // A search for the name finds the park first: a chip must not be answered by it.
      m.rig.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [park, attraction]);
      m.camera.pois.add(_raw('Point', [-114.402164, 42.596005], {'name': 'Shoshone Falls', 'kind': 'attraction'}));
      await m.tap(tester, 42.596005, -114.402164);
      expect(m.nav.selected?.id, 'place:osm:n1671534021');
      expect(m.nav.selected?.kind, 'Attraction');
      m.camera.pois
        ..clear()
        ..add(_raw('Point', [-114.40056, 42.593015], {'name': 'Shoshone Falls', 'kind': 'park'}));
      await m.tap(tester, 42.593015, -114.40056);
      expect(m.nav.selected?.id, 'place:osm:w121853382');
      expect(m.nav.selected?.kind, 'Park');
      expect(m.rig.backend.linkCalls, ['attraction:Shoshone Falls', 'park:Shoshone Falls']);
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty, reason: 'a chip is never searched for');
      await m.finish(tester);
    });

    testWidgets('old places data (no links in it): the chip is matched by name and distance, the old way', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      final park = _place('place:osm:w121853382', 'Shoshone Falls', 42.5933, -114.4003, kind: 'Park');
      m.rig.backend.linksPresent = false;
      m.rig.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [park]);
      m.camera.pois.add(_raw('Point', [-114.4003, 42.5933], {'name': 'Shoshone Falls', 'kind': 'park'}));
      await m.tap(tester, 42.5933, -114.4003);
      expect(m.nav.selected?.id, 'place:osm:w121853382');
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), ['search:Shoshone Falls:k']);
      await m.finish(tester);
    });

    testWidgets('a chip with no link opens the no-details card even when a place of that name is near; the link is asked once', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      final park = _place('place:osm:w121853382', 'Shoshone Falls', 42.5933, -114.4003, kind: 'Park');
      m.rig.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [park]);
      m.camera.pois.add(_raw('Point', [-114.402164, 42.596005], {'name': 'Shoshone Falls', 'kind': 'attraction'}));
      await m.tap(tester, 42.596005, -114.402164);
      expect(m.nav.selected?.id, startsWith('loc:'));
      expect(m.nav.selected?.matched, 'poi');
      expect(find.text('No other details for this place.'), findsOneWidget);
      expect(m.rig.backend.linkCalls, ['attraction:Shoshone Falls']);
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty);
      await m.finish(tester);
    });

    testWidgets('a chip with no name: a card named by its kind, no lookup of a name', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.pois.add(_raw('Point', [-113.5, 42.5], {'kind': 'drinking_water'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.name, 'Drinking water');
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty);
      expect(find.byKey(const ValueKey('place-card-no-details')), findsOneWidget);
      await m.finish(tester);
    });

    testWidgets('while a route is shown, a chip opens nothing', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.rig.backend.onRoute = (to, mode, from) async => MapRoute.fromJson(driveRouteJson(withStop: false));
      await tester.runAsync(() => m.nav.openDirections(driveDestination));
      await tester.pump();
      m.camera.pois.add(_raw('Point', [-113.5, 42.5], {'name': 'Cascade Park', 'kind': 'park'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.phase, NavPhase.previewing);
      expect(m.nav.selected?.name, isNot('Cascade Park'));
      await m.finish(tester);
    });

    testWidgets('a label the places data does not have: a card with its name, Directions to its point', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.labels.add(_raw('Point', [-113.51, 42.51], {'name': 'Larkspur Flats'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.name, 'Larkspur Flats');
      expect(m.nav.selected?.id, 'loc:42.510000,-113.510000');
      expect(find.text('Larkspur Flats'), findsWidgets);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
      expect(find.byKey(const ValueKey('place-open-entry')), findsNothing);
      await m.finish(tester);
    });

    testWidgets('a trail of an overlay: a card with its name and its layer, Directions to the tapped spot', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.trails.add(_raw('LineString', [[-113.6, 42.5], [-113.4, 42.5]], {'TRAIL_NAME': 'Hollow Fern Trail'}));
      await m.tap(tester, 42.5001, -113.5);
      expect(m.nav.selected?.name, 'Hollow Fern Trail');
      expect(m.nav.selected?.kind, 'Test trails');
      expect(m.nav.selected?.lat, 42.5001);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty, reason: 'only a label is looked up');
      await m.finish(tester);
    });

    testWidgets('a trail\'s thin line with no label near it opens its card; the query asks for the line layers the style has', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.trails.add(_raw('LineString', [[-113.6, 42.5], [-113.4, 42.5]], {'TRAIL_NAME': 'Hollow Fern Trail'}));
      await m.tap(tester, 42.5, -113.5);
      final asked = m.camera.asked.firstWhere((l) => l.any((x) => x.startsWith('test-trails-')));
      expect(asked, containsAll(['test-trails-line', 'test-trails-casing']));
      expect(m.nav.selected?.name, 'Hollow Fern Trail');
      expect(find.byKey(const ValueKey('place-card-name')), findsOneWidget);
      await m.finish(tester);
    });

    testWidgets('a named path of the base map, with no label or overlay there: the card of that name at the tapped spot', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.baseLines.add(_raw('LineString', [[-113.6, 42.5], [-113.4, 42.5]], {'name': 'Canyon Rim Trail', 'class': 'path'}));
      await m.tap(tester, 42.5001, -113.5);
      expect(m.nav.selected?.name, 'Canyon Rim Trail');
      expect(m.nav.selected?.lat, 42.5001);
      expect(find.byKey(const ValueKey('place-directions')), findsOneWidget);
      final lineAsk = m.camera.asked.where((l) => !l.contains('places_locality') && !l.any((x) => x.startsWith('test-trails-')) && !l.contains(kUserLines));
      expect(lineAsk, isNotEmpty, reason: 'the base map\'s line layers are asked');
      expect(lineAsk.first.any((x) => x == 'places_locality'), isFalse);
      await m.finish(tester);
    });

    testWidgets('an unnamed line of the base map opens nothing', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.baseLines.add(_raw('LineString', [[-113.6, 42.5], [-113.4, 42.5]], {'class': 'track'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected, isNull);
      await m.finish(tester);
    });

    testWidgets('an area of a file imported into a Places notebook: a card named by it, with Open to its notebook', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.camera.user.add(_raw('Polygon', [[[-113.6, 42.4], [-113.4, 42.4], [-113.4, 42.6], [-113.6, 42.4]]], {'layer': 'L1', 'name': 'Camp area'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.selected?.name, 'Camp area');
      expect(m.nav.selected?.kind, 'Test book');
      expect(find.byKey(const ValueKey('place-save')), findsNothing);
      final open = find.byKey(const ValueKey('place-open-entry'));
      expect(open, findsOneWidget);
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pump();
      expect(m.openedBooks, ['nb-1']);
      await m.finish(tester);
    });

    testWidgets('a tap on nothing opens nothing and closes the card that was open', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.nav.select(_place('place:test:x', 'Sorrel Bakery', 42.5, -113.5, kind: 'Bakery'));
      await tester.pump();
      await m.tap(tester, 42.7, -113.2);
      expect(m.nav.selected, isNull);
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty);
      await m.finish(tester);
    });

    testWidgets('while a route is shown, a label opens nothing', (tester) async {
      final m = _Maps();
      await m.pump(tester);
      m.rig.backend.onRoute = (to, mode, from) async => MapRoute.fromJson(driveRouteJson(withStop: false));
      await tester.runAsync(() => m.nav.openDirections(driveDestination));
      await tester.pump();
      expect(m.nav.phase, NavPhase.previewing);
      m.camera.labels.add(_raw('Point', [-113.5, 42.5], {'name': 'Quillmoor'}));
      await m.tap(tester, 42.5, -113.5);
      expect(m.nav.phase, NavPhase.previewing);
      expect(m.rig.backend.calls.where((c) => c.startsWith('search:')), isEmpty);
      await m.finish(tester);
    });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _pureTests();
  _screenTests();
}

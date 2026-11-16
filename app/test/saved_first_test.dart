import 'dart:io';

import 'package:cache/car/car_bridge.dart';
import 'package:cache/car/car_drive.dart';
import 'package:cache/car/car_places.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/saved_first.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/search/app_search_providers.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/test_layer_engine.dart';

// Made-up names only.

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

class _CarPlaces implements CarPlaces {
  final List<SavedPlaceRecord> saved = [];
  final List<MapPlace> found = [];

  @override
  Future<List<SavedPlaceRecord>> savedPlaces() async => saved;

  @override
  Future<MapSearchResponse> search(String query, {GeoPoint? near, int limit = 10}) async =>
      MapSearchResponse(query: query, kind: 'text', meaning: 'off', results: found);

  @override
  Future<void> close() async {}
}

MapPlace _place(String id, String name, {double lat = 42.5, double lon = -113.5}) =>
    MapPlace(id: id, type: 'place', name: name, kind: 'Park', address: '1 Sample Rd', lat: lat, lon: lon, matched: 'name');

/// The map search answers with ten other places, as a full page does: none of them is a saved place.
List<MapPlace> _others() => [for (var i = 0; i < 10; i++) _place('place:$i', 'Rowan Creek Trailhead $i', lon: -113.5 - i / 100)];

const _saved = [
  ('Willow Bend Shop', 42.61, -113.71),
  ("Rowan's House", 42.62, -113.72),
  ('Alder Home', 42.63, -113.73),
  ('Old Rowan Barn', 42.64, -113.74),
];

Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the rule', () {
    test('whole name, then a start of the name or of a word, then held anywhere; case, apostrophes and spaces do not matter', () {
      expect(savedMatch("Rowan's House", "Rowan's House"), 0);
      expect(savedMatch("Rowan's House", "rowan's house"), 0);
      expect(savedMatch("Rowan's House", 'ROWANS HOUSE'), 0);
      expect(savedMatch("Rowan's House", 'rowans house'), 0);
      expect(savedMatch('Alder Home', 'alderhome'), 0);
      expect(savedMatch("Rowan's House", 'rowan'), 1);
      expect(savedMatch('Alder Home', 'alder h'), 1);
      expect(savedMatch('Alder Home', 'home'), 1, reason: 'a word of the name starts with it');
      expect(savedMatch('Old Rowan Barn', 'rowan b'), 1);
      expect(savedMatch('Alder Home', 'der'), 2);
      expect(savedMatch('Alder Home', 'birch'), isNull);
      expect(savedMatch('Alder Home', '  '), isNull);
    });

    test('saved places that match come first, ranked, and the other places follow as they came, less a saved one', () {
      final saved = [for (final (i, s) in _saved.indexed) savedAsPlace(SavedPlaceRecord(key: 'k$i', name: s.$1, lat: s.$2, lon: s.$3))];
      final found = [_place('place:a', 'Rowan Park'), _place('place:b', "Rowan's House", lat: 42.62, lon: -113.72), _place('place:c', 'Rowan Mill')];
      expect([for (final p in savedFirst('rowan', saved, found)) p.name], ["Rowan's House", 'Old Rowan Barn', 'Rowan Park', 'Rowan Mill']);
      expect([for (final p in savedFirst("rowan's house", saved, found)) p.name].first, "Rowan's House");
      expect([for (final p in savedFirst('birch', saved, found)) p.name], ['Rowan Park', "Rowan's House", 'Rowan Mill']);
    });
  });

  group('the four searches', () {
    late Directory dir;
    late LocationService location;
    late FakeBackend backend;
    late NavState nav;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('savedfirst');
      location = LocationService(source: _NoSource(), settingsDirOverride: dir);
      await location.init();
      backend = FakeBackend();
      for (final s in _saved) {
        backend.saved.add(s);
      }
      backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: _others());
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

    Future<List<String>> phone(String q) async {
      nav.onQueryChanged(q);
      await settle();
      return [for (final p in nav.results) p.name];
    }

    test("phone Maps search: the exact name of a saved place is listed first, though the place search's page is full", () async {
      expect((await phone("Rowan's House")).first, "Rowan's House");
      expect((await phone("rowan's house")).first, "Rowan's House", reason: 'another case');
      expect((await phone('Rowans House')).first, "Rowan's House", reason: 'no apostrophe');
      expect((await phone('Alder Home')).first, 'Alder Home', reason: 'two words');
      expect((await phone('alder')).first, 'Alder Home', reason: 'a start');
      final rowan = await phone('rowan');
      expect(rowan.take(2), ["Rowan's House", 'Old Rowan Barn'], reason: 'the start of the name, then the start of a word');
      expect(rowan.skip(2), [for (final p in _others()) p.name], reason: 'the other places follow unchanged');
      expect(nav.results.first.kind, 'Saved place');
    });

    test('phone Maps search: saved places that match stay when the place search fails', () async {
      backend.onSearch = (q, {near, meaning}) async => throw const CacheSearchException('not_configured', 'no places');
      expect(await phone('alder'), ['Alder Home']);
    });

    CarBridge car(_CarPlaces own) {
      final drive = CarDriveSource(FakeNavPosition(), route: () => nav.route, tick: const Duration(milliseconds: 10));
      final maps = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir);
      addTearDown(maps.dispose);
      return CarBridge(nav: nav, maps: maps, drive: drive, places: own, glyphs: () async => 'g');
    }

    test('CarPlay and Android Auto search (CarBridge.search): the same rule as the phone', () async {
      final own = _CarPlaces()
        ..saved.addAll([for (final (i, s) in _saved.indexed) SavedPlaceRecord(key: 'k$i', name: s.$1, lat: s.$2, lon: s.$3)])
        ..found.addAll(_others());
      final b = car(own);
      Future<List<String>> names(String q) async => [for (final p in await b.search(q)) p.name];
      expect((await names('rowans house')).first, "Rowan's House");
      expect((await names('ALDER')).first, 'Alder Home');
      expect((await names('home')).first, 'Alder Home', reason: 'a word of the name starts with it');
      final rowan = await names('rowan');
      expect(rowan.take(2), ["Rowan's House", 'Old Rowan Barn']);
      expect(rowan.skip(2), [for (final p in _others()) p.name]);
    });

    test("Home search's Places: saved places that match come first, ranked, then the map's places", () async {
      final opened = <String>[];
      final home = PlacesSearchProvider(backend: backend, near: () => null, open: (p) => opened.add(p.name));
      final r = await home.search('rowan');
      expect([for (final x in r) x.title].take(2), ["Rowan's House", 'Old Rowan Barn']);
      expect(r.length, 8, reason: 'the limit applies after the saved places are put first');
      expect(r[0].score, greaterThanOrEqualTo(r[2].score));
      expect((await home.search("ROWAN'S HOUSE")).first.title, "Rowan's House");
      r.first.open();
      expect(opened, ["Rowan's House"]);
    });
  });
}

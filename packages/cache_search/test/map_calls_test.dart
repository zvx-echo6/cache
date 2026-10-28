import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

String fixture(String name) => File('test/fixtures/map/$name').readAsStringSync();

/// The native seam with the map calls: answers from canned JSON and records the requests.
class MapFake extends FakeNative implements CsMapNative {
  bool map = true;
  bool saved = true;
  final Map<String, String?> mapReplies = {};
  final List<String> mapCalls = [];

  @override
  bool get hasMap => map;
  @override
  bool get hasSavedPlaces => saved;

  @override
  String? mapSearch(int handle, String requestJson) {
    mapCalls.add('search:$requestJson');
    return mapReplies['search'];
  }

  @override
  String? mapRoute(int handle, String requestJson) {
    mapCalls.add('route:$requestJson');
    return mapReplies['route'];
  }

  @override
  String? mapProgress(int handle, String requestJson) {
    mapCalls.add('progress:$requestJson');
    return mapReplies['progress'];
  }

  @override
  String? placesList(int handle) => mapReplies['places'];
  @override
  String? placeSave(int handle, String placeJson) {
    mapCalls.add('save:$placeJson');
    return mapReplies['save'];
  }

  @override
  String? placeDelete(int handle, String key) {
    mapCalls.add('delete:$key');
    return mapReplies['delete'];
  }
}

/// The map seam plus cs_places_refresh.
class PlacesFake extends MapFake implements CsPlacesNative {
  final List<String> refreshCalls = [];

  @override
  bool get hasPlacesRefresh => true;

  @override
  String? placesRefresh(int handle, String argsJson) {
    refreshCalls.add(argsJson);
    final packs = (jsonDecode(argsJson) as Map)['packs'] as List?;
    return jsonEncode({'ok': true, 'packs': packs?.length ?? 0, 'merged': true});
  }
}

CsNative _placesWorkerFake() => PlacesFake();

// Runs inside the worker isolate, so it builds its own fake.
CsNative _workerFake() => MapFake()
  ..mapReplies['search'] = fixture('search-pharmacy.json')
  ..mapReplies['route'] = fixture('route-walk-stanley.json')
  ..mapReplies['progress'] = jsonEncode((jsonDecode(fixture('progress-walk.json')) as List).first)
  ..mapReplies['save'] = '{"key":"walgreens","name":"Walgreens","lat":42.539,"lon":-113.787,"label":null}'
  ..mapReplies['places'] = '{"places":[{"key":"home","name":"Home","lat":42.5,"lon":-113.8,"label":"cabin"}]}';

void main() {
  group('reading the answers of the core', () {
    test('polyline6 round trips Valhalla\'s encoding', () {
      final pts = decodePolyline6(_encode(const [GeoPoint(42.536, -113.792), GeoPoint(43.615, -116.202)]));
      expect(pts, hasLength(2));
      expect(pts.first.lat, closeTo(42.536, 1e-6));
      expect(pts.last.lon, closeTo(-116.202, 1e-6));
      expect(decodePolyline6(''), isEmpty);
      expect(decodePolyline6('_'), isEmpty, reason: 'a cut-off string gives what was complete');
    });

    test('a search answer: the anchor town, the categories, the rows with their card details', () {
      final r = MapSearchResponse.fromJson(jsonDecode(fixture('search-pharmacy.json')) as Map<String, dynamic>);
      expect(r.query, 'pharmacy near Burley');
      expect(r.kind, 'text');
      expect(r.anchorName, 'Burley');
      expect(r.categories, ['pharmacy']);
      expect(r.results.first.isCategory, isTrue);
      expect(r.results.first.id, 'category:pharmacy');
      final w = r.results.firstWhere((p) => p.name == 'Walgreens');
      expect(w.id, startsWith('place:'));
      expect(w.kind, 'Pharmacy');
      expect(w.phone, isNotNull);
      expect(w.website, 'https://www.walgreens.com');
      expect(w.distanceM, greaterThan(0));
      expect(w.direction, isNotNull);
      expect(w.toEnd().keys, containsAll(['id', 'lat', 'lon', 'name']));
      expect(r.results.first.toEnd().containsKey('id'), isFalse, reason: 'a category is not an end');
    });

    test('a drive route with an alternative: totals, segments that cover the line, all the maneuvers', () {
      final r = MapRoute.fromJson(jsonDecode(fixture('route-drive-challis.json')) as Map<String, dynamic>);
      expect(r.ok, isTrue);
      expect(r.mode, 'drive');
      expect(r.routing, 'road');
      expect(r.alternatives, hasLength(1));
      expect(r.alternatives.single.routeId, isNot(r.routeId));
      expect(r.alternatives.single.alternatives, isEmpty);
      expect(r.points.length, r.raw['point_count']);
      expect(r.segments.single.startIndex, 0);
      expect(r.segments.single.endIndex, r.points.length - 1);
      expect(r.hasOffroad, isFalse);
      expect(r.totals.offroadM, 0);
      expect(r.totals.roadM, closeTo(r.distanceM, 1));
      expect(r.maneuvers.length, greaterThan(10));
      expect(r.maneuvers.last.isArrival, isTrue);
      for (var i = 0; i < r.maneuvers.length; i++) {
        final m = r.maneuvers[i];
        expect(m.index, i);
        expect(m.beginIndex, lessThanOrEqualTo(m.endIndex));
        expect(m.endIndex, lessThan(r.points.length));
        expect(m.isOffroad, isFalse);
        // the maneuver sits on the line
        expect(r.points[m.beginIndex].lat, closeTo(m.lat, 2e-6));
      }
      final b = r.bounds;
      expect(b[0], lessThan(b[2]));
      expect(r.destinationName, 'Challis');
      expect(r.segmentPoints(r.segments.single).length, r.points.length);
    });

    test('a walk with open ground and a trail at its start: the kinds are kept apart', () {
      final r = MapRoute.fromJson(jsonDecode(fixture('route-walk-stanley.json')) as Map<String, dynamic>);
      expect(r.routing, 'offroad');
      expect(r.hasOffroad, isTrue);
      expect(r.segments.map((s) => s.kind), ['offroad', 'follow', 'road']);
      expect(r.segments.map((s) => s.travel), ['foot', 'foot', 'walk']);
      // the segments meet end to start
      for (var i = 1; i < r.segments.length; i++) {
        expect(r.segments[i].startIndex, r.segments[i - 1].endIndex);
      }
      expect(r.totals.offroadM, closeTo(r.segments[0].distanceM + r.segments[1].distanceM, 1));
      expect(r.totals.ascentM, greaterThan(100));
      final off = r.maneuvers.first;
      expect(off.isOffroad, isTrue);
      expect(off.gradeClass, isNotNull);
      expect(off.elevGainM, isNotNull);
      expect(off.cardinal, isNotNull);
      expect(r.maneuvers.length, greaterThan(12), reason: 'not cut short for a model');
      expect(r.maneuvers.where((m) => m.isOffroad).length, 3);
    });

    test('a failed route has its errors and nothing to draw', () {
      final r = MapRoute.fromJson({
        'ok': false, 'route_id': 'x', 'mode': 'drive', 'errors': [{'code': 'no_route', 'message': 'No route found'}],
      });
      expect(r.ok, isFalse);
      expect(r.errors.single.code, 'no_route');
      expect(r.maneuvers, isEmpty);
    });

    test('progress: where the fix is, what is next, and the off-road leg', () {
      final drive = (jsonDecode(fixture('progress-drive.json')) as List).map((e) => MapProgress.fromJson((e as Map).cast<String, dynamic>())).toList();
      final p = drive[1];
      expect(p.onRoute, isTrue);
      expect(p.offRoute, isFalse);
      expect(p.fraction, inInclusiveRange(0, 1));
      expect(p.remainingM + p.distanceAlongM, closeTo(p.totalM, 2));
      expect(p.current.index, lessThan(p.next!.index));
      expect(p.next!.distanceM, greaterThan(0));
      expect(p.next!.instruction, isNotEmpty);
      expect(p.then, isNotNull);
      expect(p.leg, isNull);
      expect(drive.last.next!.isArrival, isTrue);
      expect(drive.last.then, isNull);

      final walk = (jsonDecode(fixture('progress-walk.json')) as List).map((e) => MapProgress.fromJson((e as Map).cast<String, dynamic>())).toList();
      final o = walk.first;
      expect(o.leg, isNotNull);
      expect(o.leg!.bearingDeg, inInclusiveRange(0, 359));
      expect(o.leg!.cardinal, isNotEmpty);
      expect(o.leg!.distanceM, greaterThan(0));
      expect(o.current.isOffroad, isTrue);
      expect(o.next!.lengthM, greaterThan(0));
      expect(walk.last.leg, isNull);
    });
  });

  group('the engine and the worker', () {
    test('the config carries the places, routing and user sections', () {
      final n = MapFake();
      SearchEngine.open(n, const [], extra: {
        'places': {'packs': ['/p/places.sqlite']},
        'routing': {'valhalla': {'tiles': '/p/tiles.tar', 'shim': '/lib/libvalhalla_shim.so'}},
        'user': {'db_path': '/p/user.sqlite'},
      });
      final sent = jsonDecode(n.calls.first.substring('open:'.length)) as Map;
      expect(sent.keys, containsAll(['sources', 'places', 'routing', 'user']));
      expect((sent['places'] as Map)['packs'], ['/p/places.sqlite']);
    });

    test('a map call sends its request JSON and returns the typed answer', () {
      final n = MapFake()
        ..mapReplies['search'] = fixture('search-pharmacy.json')
        ..mapReplies['route'] = fixture('route-walk-stanley.json');
      final e = SearchEngine.open(n, const []);
      final s = e.mapSearch({'query': 'pharmacy near Burley', 'limit': 5});
      expect(s.results.first.name, 'Pharmacy');
      expect(jsonDecode(n.mapCalls.first.substring('search:'.length)), {'query': 'pharmacy near Burley', 'limit': 5});
      final r = e.mapRoute({'to': {'lat': 44.2, 'lon': -114.9}, 'mode': 'walk'});
      expect(r.routing, 'offroad');
      expect(n.mapCalls.last, startsWith('route:'));
    });

    test('the core\'s error is raised from the thread or handle error', () {
      final n = MapFake()
        ..error = '{"code":"not_configured","message":"map search needs places"}';
      final e = SearchEngine.open(n, const []);
      expect(() => e.mapSearch({'query': 'x'}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'not_configured')));
    });

    test('a core without the map calls says so instead of crashing', () {
      final old = FakeNative();
      expect(() => SearchEngine.open(old, const []).mapSearch({'query': 'x'}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
      final n = MapFake()..map = false;
      expect(() => SearchEngine.open(n, const []).mapRoute({'to': {}}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
      final m = MapFake()..saved = false;
      expect(() => SearchEngine.open(m, const []).savedPlaces(), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
    });

    test('cs_places_refresh: the packs when given, nothing else when not; an older core says so', () async {
      final n = PlacesFake();
      final e = SearchEngine.open(n, const []);
      expect(e.placesRefresh(packs: ['/p/idaho/places.sqlite']), {'ok': true, 'packs': 1, 'merged': true});
      expect(jsonDecode(n.refreshCalls.last), {'packs': ['/p/idaho/places.sqlite']});
      e.placesRefresh();
      expect(jsonDecode(n.refreshCalls.last), <String, dynamic>{});
      expect(() => SearchEngine.open(MapFake(), const []).placesRefresh(), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));

      final core = await SearchCore.open(const [], native: _placesWorkerFake);
      expect((await core.refreshPlaces(packs: ['/a', '/b']))['packs'], 2);
      expect((await core.refreshPlaces())['merged'], true);
      await core.close();
    });

    test('a search answer carries the places state', () {
      final r = MapSearchResponse.fromJson({
        'query': 'pharmacy',
        'meaning': 'used',
        'results': <Object>[],
        'warning': 'no places data is installed',
        'places': {'installed': true, 'covers': false, 'pending': 1},
        'warning_code': 'fetching',
      });
      expect(r.warningCode, 'fetching');
      expect(r.places!.installed, isTrue);
      expect(r.places!.covers, isFalse);
      expect(r.places!.pending, 1);
      final old = MapSearchResponse.fromJson({'query': 'x', 'results': <Object>[]});
      expect(old.warningCode, isNull);
      expect(old.places, isNull);
    });

    test('saved places: list, save, delete', () {
      final n = MapFake()
        ..mapReplies['places'] = '{"places":[{"key":"home","name":"Home","lat":42.5,"lon":-113.8,"label":"cabin"}]}'
        ..mapReplies['save'] = '{"key":"walgreens","name":"Walgreens","lat":42.539,"lon":-113.787,"label":null}'
        ..mapReplies['delete'] = '{"deleted":"home"}';
      final e = SearchEngine.open(n, const []);
      expect(e.savedPlaces().single.label, 'cabin');
      expect(e.savePlace({'name': 'Walgreens', 'lat': 42.539, 'lon': -113.787}).key, 'walgreens');
      e.deleteSavedPlace('home');
      expect(n.mapCalls.last, 'delete:home');
    });

    test('the worker isolate runs the map calls and gives typed answers', () async {
      final core = await SearchCore.open(const [], native: _workerFake, extra: const {'places': {'packs': ['/x']}});
      final s = await core.mapSearch('pharmacy near Burley', near: const GeoPoint(42.536, -113.792), limit: 5, meaning: false);
      expect(s.anchorName, 'Burley');
      final r = await core.mapRoute(from: {'lat': 44.05, 'lon': -115.42}, to: {'lat': 44.22, 'lon': -114.93, 'name': 'Stanley'}, mode: 'walk');
      expect(r.hasOffroad, isTrue);
      final p = await core.mapProgress(r, lat: 44.05, lon: -115.42, accuracyM: 8, now: DateTime.utc(2026, 10, 26, 12), sendRoute: true);
      expect(p.leg, isNotNull);
      final saved = await core.savePlace(name: 'Walgreens', lat: 42.539, lon: -113.787);
      expect(saved.key, 'walgreens');
      expect((await core.savedPlaces()).single.name, 'Home');
      await core.close();
    });

    test('the progress request carries the fix and the thresholds, and the route only when asked', () async {
      final n = MapFake()..mapReplies['progress'] = jsonEncode((jsonDecode(fixture('progress-drive.json')) as List).first);
      final e = SearchEngine.open(n, const []);
      final route = MapRoute.fromJson(jsonDecode(fixture('route-drive-challis.json')) as Map<String, dynamic>);
      e.mapProgress({'route_id': route.routeId, 'lat': 1.0, 'lon': 2.0, 'off_route_m': 40});
      final sent = jsonDecode(n.mapCalls.last.substring('progress:'.length)) as Map;
      expect(sent['route_id'], route.routeId);
      expect(sent.containsKey('route'), isFalse);
    });
  });
}

String _encode(List<GeoPoint> pts) {
  final out = StringBuffer();
  var plat = 0, plon = 0;
  void put(int v) {
    var x = v < 0 ? ~(v << 1) : (v << 1);
    while (x >= 0x20) {
      out.writeCharCode(((0x20 | (x & 0x1f)) + 63));
      x >>= 5;
    }
    out.writeCharCode(x + 63);
  }

  for (final p in pts) {
    final la = (p.lat * 1e6).round(), lo = (p.lon * 1e6).round();
    put(la - plat);
    put(lo - plon);
    plat = la;
    plon = lo;
  }
  return out.toString();
}

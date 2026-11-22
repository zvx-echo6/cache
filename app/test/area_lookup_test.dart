// Which town and county a point is in, from the catalogue's polygons kept on the phone. The outlines are the catalogue's own files for
// Twin Falls, Kimberly, Buhl, Twin Falls County and Idaho (test/fixtures/regions); the points were chosen and checked with an exact
// geometry library, not with the code under test.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/maps/geo.dart';
import 'package:cache/regions/area_lookup.dart';
import 'package:cache/weather/catalogue_store.dart' show NetworkProblem;
import 'package:cache/regions/region_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _rec(String id, String name, String kind, List<double> bbox, num area, int pop, List<String> parents) => {
      'id': id,
      'name': name,
      'kind': kind,
      'country': 'US',
      'region_code': 'US-ID',
      'parents': parents,
      'bbox': bbox,
      'area_km2': area,
      'population': pop,
      'polygon': 'polygons/$id.geojson',
    };

final List<Map<String, dynamic>> _records = [
  _rec('us-id', 'Idaho', 'region', [-117.24303, 41.98883, -111.04356, 49.00084], 215996, 2001619, ['us']),
  _rec('us-id-twin-falls-county', 'Twin Falls County', 'county', [-115.03924, 41.99415, -114.00032, 42.91843], 4988, 82375, ['us-id', 'us-id-magic-valley']),
  _rec('us-id-twin-falls', 'Twin Falls', 'locality', [-114.51593, 42.51255, -114.37903, 42.60642], 50.4, 49764, ['us-id-twin-falls-county', 'us-metro-twin-falls-id']),
  _rec('us-id-kimberly', 'Kimberly', 'locality', [-114.38435, 42.51917, -114.35492, 42.54991], 4.3, 4626, ['us-id-twin-falls-county']),
  _rec('us-id-buhl', 'Buhl', 'locality', [-114.77574, 42.58381, -114.74207, 42.61167], 4.86, 4558, ['us-id-twin-falls-county']),
  // In the catalogue, with no outline anywhere (a county whose file was never kept).
  _rec('us-id-ada-county', 'Ada County', 'county', [-116.5137, 43.11227, -115.97486, 43.80742], 2742, 434211, ['us-id']),
  // A town of the next state that has this county among its parents (as Tremonton, Utah, does a valley of Idaho's).
  {..._rec('us-ut-tremonton', 'Tremonton', 'locality', [-112.2, 41.7, -112.1, 41.75], 10, 9000, ['us-id-twin-falls-county']), 'region_code': 'US-UT'},
  _rec('us-metro-twin-falls-id', 'Twin Falls metro', 'metro', [-114.8, 42.0, -114.0, 42.9], 5000, 100000, ['us']),
];

List<RegionRecord> get _all => [for (final r in _records) RegionRecord.fromJson(r)];

Future<Map<String, dynamic>?> _fromFixtures(RegionRecord r) async {
  final f = File('test/fixtures/regions/${r.id}.geojson');
  if (!f.existsSync()) return null;
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return (j['geometry'] as Map).cast<String, dynamic>();
}

String? _names(AreaHit? h) => h == null ? null : '${h.town?.name ?? '-'} / ${h.county?.name ?? '-'} / ${h.state?.name ?? '-'}';

void main() {
  group('the lookup from outlines', () {
    test('inside Twin Falls: the city, its county and the state', () async {
      expect(_names(await areaAt(42.5629, -114.4609, _all, _fromFixtures)), 'Twin Falls / Twin Falls County / Idaho');
    });

    test('a point in a hole of the city is the county only', () async {
      // The city's outline has islands cut out of it (county land inside the city box).
      expect(_names(await areaAt(42.534235, -114.473544, _all, _fromFixtures)), '- / Twin Falls County / Idaho');
    });

    test('inside the county, outside any town: the county only (rural near Hollister, and the south end of the county)', () async {
      expect(_names(await areaAt(42.3519, -114.5766, _all, _fromFixtures)), '- / Twin Falls County / Idaho');
      expect(_names(await areaAt(42.01, -114.65, _all, _fromFixtures)), '- / Twin Falls County / Idaho');
    });

    test('near the city border each side gets its own answer (about 35 m either way of the western limit)', () async {
      expect(_names(await areaAt(42.533001, -114.465425, _all, _fromFixtures)), 'Twin Falls / Twin Falls County / Idaho');
      expect(_names(await areaAt(42.532999, -114.464625, _all, _fromFixtures)), '- / Twin Falls County / Idaho');
    });

    test('another town of the county is its own answer, not Twin Falls', () async {
      expect(_names(await areaAt(42.53442, -114.36522, _all, _fromFixtures)), 'Kimberly / Twin Falls County / Idaho');
      expect(_names(await areaAt(42.598785, -114.757103, _all, _fromFixtures)), 'Buhl / Twin Falls County / Idaho');
    });

    test('a point in the state but outside the county is the state only', () async {
      expect(_names(await areaAt(44.0, -115.0, _all, _fromFixtures)), '- / - / Idaho');
    });

    test('outside every outline: null (Oregon, Nevada)', () async {
      expect(await areaAt(44.0, -118.0, _all, _fromFixtures), isNull);
      expect(await areaAt(41.5, -115.5, _all, _fromFixtures), isNull);
    });

    test('a region with no outline, or one that cannot be read, is skipped without a word', () async {
      Future<Map<String, dynamic>?> broken(RegionRecord r) async {
        if (r.id == 'us-id-twin-falls') throw const FormatException('corrupt');
        if (r.id == 'us-id-kimberly') return {'type': 'Polygon', 'coordinates': 'nonsense'};
        if (r.id == 'us-id-ada-county') return null;
        return _fromFixtures(r);
      }

      expect(_names(await areaAt(42.5629, -114.4609, _all, broken)), '- / Twin Falls County / Idaho');
      expect(_names(await areaAt(42.53442, -114.36522, _all, broken)), '- / Twin Falls County / Idaho');
      expect(_names(await areaAt(43.5, -116.2, _all, broken)), '- / - / Idaho', reason: 'Ada County has no outline here');
    });

    test('the box is the first cut: no outline is read for a region whose box misses the point', () async {
      final read = <String>[];
      await areaAt(42.5629, -114.4609, _all, (r) {
        read.add(r.id);
        return _fromFixtures(r);
      });
      expect(read, isNot(contains('us-id-buhl')));
      expect(read, isNot(contains('us-id-ada-county')));
      expect(read, isNot(contains('us-metro-twin-falls-id')), reason: 'a metro area is not a town, county or state');
    });

    test('a MultiPolygon and a hole in it', () {
      final g = {
        'type': 'MultiPolygon',
        'coordinates': [
          [
            [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
            [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]],
          ],
          [
            [[20, 0], [30, 0], [30, 10], [20, 10], [20, 0]],
          ],
        ],
      };
      expect(pointInGeometry(g, 2, 2), isTrue);
      expect(pointInGeometry(g, 5, 5), isFalse, reason: 'in the hole');
      expect(pointInGeometry(g, 5, 25), isTrue, reason: 'the second part');
      expect(pointInGeometry(g, 15, 15), isFalse);
      expect(pointInGeometry({'type': 'Point', 'coordinates': [1, 1]}, 1, 1), isFalse);
    });
  });

  group('the population line', () {
    test('one source, rounded: the catalogue\'s', () {
      RegionRecord p(int? n) => RegionRecord.fromJson({'id': 'x', 'name': 'X', 'kind': 'locality', 'population': n});
      expect(areaPopulationLine(p(49764)), 'About 49,800 people');
      expect(areaPopulationLine(p(82375)), 'About 82,400 people');
      expect(areaPopulationLine(p(434211)), 'About 434,000 people');
      expect(areaPopulationLine(p(4558)), 'About 4,560 people');
      expect(areaPopulationLine(p(300)), 'About 300 people');
      expect(areaPopulationLine(p(null)), isNull);
      expect(areaPopulationLine(p(0)), isNull);
    });
  });

  group('kept with the download', () {
    late Directory dir;
    final requested = <String>[];
    var offline = false;
    final corrupt = <String>{'us-id-buhl'};

    Future<Uint8List> fetch(Uri u) async {
      requested.add(u.path);
      if (offline) throw const NetworkProblem('no connection');
      final name = u.pathSegments.last;
      Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
      if (name == 'index.json') {
        return b(jsonEncode({
          'polygon_base': 'https://t.example/regions/polygons/',
          'countries': [
            {'id': 'us', 'name': 'United States', 'kind': 'country', 'shard': 'us', 'bbox': [-125.0, 24.0, -66.0, 49.5], 'count': _records.length},
          ],
        }));
      }
      if (name == 'us.json') return b(jsonEncode({'shard': 'us', 'release': 't', 'regions': _records, 'tree': []}));
      if (name.endsWith('.geojson')) {
        final id = name.substring(0, name.length - '.geojson'.length);
        if (corrupt.contains(id)) return b('{"type": "Feature", "geometry": {"type":');
        final f = File('test/fixtures/regions/$id.geojson');
        if (f.existsSync()) return b(f.readAsStringSync());
      }
      throw const NetworkProblem('404');
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('area-store');
      requested.clear();
      offline = false;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('which outlines a region keeps: its counties and towns, and its state', () async {
      final c = RegionCatalogue(dir: () async => dir, fetch: fetch);
      final shard = await c.shard('us');
      expect({for (final r in c.areaRecordsOf(shard['us-id']!)) r.id}, {'us-id', 'us-id-twin-falls-county', 'us-id-twin-falls', 'us-id-kimberly', 'us-id-buhl', 'us-id-ada-county'}, reason: 'not the Utah town');
      expect({for (final r in c.areaRecordsOf(shard['us-id-twin-falls-county']!)) r.id}, {'us-id', 'us-id-twin-falls-county', 'us-id-twin-falls', 'us-id-kimberly', 'us-id-buhl'});
      expect({for (final r in c.areaRecordsOf(shard['us-id-kimberly']!)) r.id}, {'us-id', 'us-id-twin-falls-county', 'us-id-kimberly'});
      expect(c.areaRecordsOf(RegionRecord.fromJson({'id': 'us', 'name': 'United States', 'kind': 'country'})), isEmpty);
      expect(c.areaRecordsOf(RegionRecord.drawn(const GeoBounds(south: 42, west: -115, north: 43, east: -114))), isEmpty);
    });

    test('downloading Idaho keeps the outlines that can be fetched; one that fails is left out; then a tap is answered offline', () async {
      final c = RegionCatalogue(dir: () async => dir, fetch: fetch);
      final idaho = (await c.shard('us'))['us-id']!;
      final done = await c.storeAreaPolygons(idaho);
      // Ada County has no file on the host (404) and Buhl's is cut short: both are left out, nothing else is affected.
      expect((done.wanted, done.stored, done.failed, done.tooMany), (6, 4, 2, false));
      for (final id in ['us-id', 'us-id-twin-falls-county', 'us-id-twin-falls', 'us-id-kimberly']) {
        expect(File('${dir.path}/polygons/$id.geojson').existsSync(), isTrue, reason: id);
      }
      expect(File('${dir.path}/polygons/us-id-buhl.geojson').existsSync(), isFalse, reason: 'a half file is never kept');

      offline = true;
      final again = RegionCatalogue(dir: () async => dir, fetch: fetch);
      expect(_names(await again.areaAtPoint(42.5629, -114.4609)), 'Twin Falls / Twin Falls County / Idaho');
      expect(_names(await again.areaAtPoint(42.598785, -114.757103)), '- / Twin Falls County / Idaho', reason: 'Buhl has no outline on the phone');
      expect(await again.areaAtPoint(44.0, -118.0), isNull);
    });

    test('a corrupt or missing file on the phone is skipped silently', () async {
      final c = RegionCatalogue(dir: () async => dir, fetch: fetch);
      await c.storeAreaPolygons((await c.shard('us'))['us-id']!);
      File('${dir.path}/polygons/us-id-kimberly.geojson').writeAsStringSync('not json at all');
      File('${dir.path}/polygons/us-id-twin-falls.geojson').deleteSync();
      offline = true;
      final again = RegionCatalogue(dir: () async => dir, fetch: fetch);
      expect(_names(await again.areaAtPoint(42.53442, -114.36522)), '- / Twin Falls County / Idaho');
      expect(_names(await again.areaAtPoint(42.5629, -114.4609)), '- / Twin Falls County / Idaho');
    });

    test('a region with more outlines than the limit keeps none', () async {
      final c = RegionCatalogue(dir: () async => dir, fetch: fetch);
      final r = await c.storeAreaPolygons((await c.shard('us'))['us-id']!, maxFiles: 3);
      expect((r.stored, r.tooMany), (0, true));
      expect(Directory('${dir.path}/polygons').existsSync(), isFalse);
    });
  });
}

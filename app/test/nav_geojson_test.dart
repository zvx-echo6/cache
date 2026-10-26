import 'package:cache/nav/nav_data.dart';
import 'package:cache/nav/nav_geojson.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'nav_fakes.dart';

void main() {
  test('the chosen route is a line per stretch, each its own kind; the others are whole and marked', () {
    final a = MapRoute.fromJson(fakeRouteJson(offroad: true));
    final b = MapRoute.fromJson(fakeRouteJson(id: 'r2', alt: 1));
    final g = routeGeoJson([a, b], 0);
    final f = (g['features'] as List).cast<Map<String, dynamic>>();
    expect(f.length, 3);
    final props = [for (final x in f) x['properties'] as Map];
    expect(props.where((p) => p['alt'] == true).length, 1);
    expect(props.where((p) => p['alt'] == false).map((p) => p['kind']), ['road', 'offroad']);
    // the stretches meet: the road ends where the open ground begins
    final road = (f.firstWhere((x) => (x['properties'] as Map)['kind'] == 'road' && (x['properties'] as Map)['alt'] == false)['geometry'] as Map)['coordinates'] as List;
    final open = (f.firstWhere((x) => (x['properties'] as Map)['kind'] == 'offroad')['geometry'] as Map)['coordinates'] as List;
    expect(road.last, open.first);
    // coordinates are [lon, lat]
    expect((road.first as List).first, closeTo(-113.8, 1e-6));
    expect((road.first as List).last, closeTo(42.5, 1e-6));
    // no route chosen: nothing is drawn
    expect((routeGeoJson(const [], 0)['features'] as List), isEmpty);
    // a choice that is not there draws every route as an alternative
    final none = (routeGeoJson([a], 5)['features'] as List).cast<Map>();
    expect([for (final x in none) (x['properties'] as Map)['alt']], [true]);
  });

  test('pins: the chosen place large, the results small, categories never', () {
    const sel = MapPlace(id: 'place:1', type: 'place', name: 'A', kind: 'Pharmacy', lat: 42.5, lon: -113.8);
    const other = MapPlace(id: 'place:2', type: 'place', name: 'B', kind: 'Pharmacy', lat: 42.6, lon: -113.7);
    const cat = MapPlace(id: 'category:pharmacy', type: 'category', name: 'Pharmacy', kind: 'Category', lat: 0, lon: 0);
    final g = pinGeoJson(sel, [cat, sel, other]);
    final roles = [for (final f in g['features'] as List) ((f as Map)['properties'] as Map)['role']];
    expect(roles, ['result', 'selected']);
    expect((pinGeoJson(null, const [])['features'] as List), isEmpty);
  });

  group('the files the core reads', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('packs'));
    tearDown(() => dir.deleteSync(recursive: true));

    void touch(String rel) {
      final f = File('${dir.path}/$rel')..createSync(recursive: true);
      f.writeAsStringSync('x');
    }

    test('everything installed becomes the places, routing and user sections', () {
      touch('idaho/places.sqlite');
      touch('idaho/valhalla/tiles.tar');
      touch('idaho/offroad.sqlite');
      touch('idaho/elevation.pmtiles');
      final d = NavData.find(dir, shim: '/lib/libvalhalla_shim.so', userDb: '/data/user.sqlite');
      final c = d.toConfig();
      expect((c['places'] as Map)['packs'], hasLength(1));
      final routing = c['routing'] as Map;
      expect((routing['valhalla'] as Map)['shim'], '/lib/libvalhalla_shim.so');
      expect((routing['offroad'] as Map).keys, ['pack', 'elevation']);
      expect(c['user'], {'db_path': '/data/user.sqlite'});
      expect(d.hasRouting, isTrue);
    });

    test('off-road needs both files; routing needs the library; places alone is fine', () {
      touch('idaho/places.sqlite');
      touch('idaho/valhalla/tiles.tar');
      touch('idaho/offroad.sqlite');
      var c = NavData.find(dir, shim: '/lib/shim.so').toConfig();
      expect((c['routing'] as Map).containsKey('offroad'), isFalse);
      c = NavData.find(dir).toConfig();
      expect(c.containsKey('routing'), isFalse, reason: 'no shim library, no road routing');
      expect(c.containsKey('places'), isTrue);
      expect(NavData.find(Directory('${dir.path}/missing')).toConfig(), isEmpty);
    });

    test('several regions give several places packs', () {
      touch('idaho/places.sqlite');
      touch('utah/places.sqlite');
      final c = NavData.find(dir).toConfig();
      expect(((c['places'] as Map)['packs'] as List).length, 2);
    });
  });

  test('the native library path is read from the process maps', () {
    final dir = Directory.systemTemp.createTempSync('maps');
    addTearDown(() => dir.deleteSync(recursive: true));
    final maps = File('${dir.path}/maps')
      ..writeAsStringSync('7f00-7f10 r-xp 00000000 00:00 1 /system/lib64/libc.so\n7f20-7f30 r-xp 00000000 00:00 2 /data/app/~~x==/co.cache.cache-y==/lib/arm64/libcache_search.so\n');
    bool has(String p) => p == '/data/app/~~x==/co.cache.cache-y==/lib/arm64/libvalhalla_shim.so';
    expect(nativeLibraryPath('libvalhalla_shim.so', maps: maps.path, exists: has), '/data/app/~~x==/co.cache.cache-y==/lib/arm64/libvalhalla_shim.so');
    expect(nativeLibraryPath('libmissing.so', maps: maps.path, exists: has), isNull);
    expect(nativeLibraryPath('libvalhalla_shim.so', maps: '${dir.path}/nope', exists: has), isNull);
  });
}

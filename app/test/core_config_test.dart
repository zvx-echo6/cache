import 'dart:io';

import 'package:cache/search/core_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the native library folder is read from where the core library is mapped', () {
    final dir = Directory.systemTemp.createTempSync('maps_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final maps = File('${dir.path}/maps')
      ..writeAsStringSync(
        '7a00000000-7a00100000 r--p 00000000 fd:03 123 /system/lib64/libc.so\n'
        '7b00000000-7b00200000 r-xp 00000000 fd:03 456 /data/app/~~x/co.cache.cache-y/lib/arm64/libflutter.so\n'
        '7b00200000-7b00300000 rw-p 00200000 fd:03 456 /data/app/~~x/co.cache.cache-y/lib/arm64/libflutter.so\n',
      );
    final lib = nativeLibraryDir(mapsFile: maps.path);
    expect(lib, '/data/app/~~x/co.cache.cache-y/lib/arm64');
    expect(shimPath(lib), '/data/app/~~x/co.cache.cache-y/lib/arm64/libvalhalla_shim.so');
    expect(nativeLibraryDir(mapsFile: '${dir.path}/missing'), isNull);
    expect(shimPath(null), 'libvalhalla_shim.so');
  });

  test('routing is configured with the shim path it is given and the tiles of the first region', () {
    final files = Directory.systemTemp.createTempSync('files_');
    final support = Directory.systemTemp.createTempSync('support_');
    addTearDown(() {
      files.deleteSync(recursive: true);
      support.deleteSync(recursive: true);
    });
    Directory('${files.path}/packs/idaho/valhalla').createSync(recursive: true);
    File('${files.path}/packs/idaho/valhalla/tiles.tar').writeAsStringSync('x');
    final cfg = buildCoreExtras(filesDir: files, supportDir: support, shim: '/lib/libvalhalla_shim.so');
    final v = (cfg['routing'] as Map)['valhalla'] as Map;
    expect((v['tiles'] as String).replaceAll('\\', '/'), endsWith('/packs/idaho/valhalla/tiles.tar'));
    expect(v['shim'], '/lib/libvalhalla_shim.so');
  });

  test('linked routing does not need a dynamic library path, with or without a tiles.tar', () {
    final files = Directory.systemTemp.createTempSync('linked-files_');
    final support = Directory.systemTemp.createTempSync('linked-support_');
    addTearDown(() {
      files.deleteSync(recursive: true);
      support.deleteSync(recursive: true);
    });
    Map<String, dynamic> build() => buildCoreExtras(
      filesDir: files, supportDir: support, useLinkedRouter: true,
      shim: '/does-not-exist/libvalhalla_shim.so',
    );
    // No tiles.tar: still configured, on the region engine's folder.
    expect(((build()['routing'] as Map)['valhalla'] as Map)['tiles'], '');
    expect(((build()['routing'] as Map)['valhalla'] as Map)['shim'], 'linked');
    final tiles = File('${files.path}/packs/idaho/valhalla/tiles.tar')
      ..createSync(recursive: true)
      ..writeAsStringSync('fixture');
    final valhalla = (build()['routing'] as Map)['valhalla'] as Map;
    expect(valhalla['shim'], 'linked');
    expect(File(valhalla['tiles'] as String).absolute.uri, tiles.absolute.uri);
    tiles.deleteSync();
    expect(((build()['routing'] as Map)['valhalla'] as Map)['tiles'], '');
  });

  group('what is installed becomes the places, routing and user sections', () {
    late Directory files, support;
    setUp(() {
      files = Directory.systemTemp.createTempSync('files_');
      support = Directory.systemTemp.createTempSync('support_');
    });
    tearDown(() {
      files.deleteSync(recursive: true);
      support.deleteSync(recursive: true);
    });

    void touch(String rel) => File('${files.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');

    Map<String, dynamic> build({String shim = '/lib/libvalhalla_shim.so'}) => buildCoreExtras(filesDir: files, supportDir: support, shim: shim);

    test('everything installed', () {
      touch('packs/idaho/places.sqlite');
      touch('packs/idaho/valhalla/tiles.tar');
      touch('packs/idaho/offroad.sqlite');
      touch('packs/idaho/elevation.pmtiles');
      final c = build();
      expect((c['places'] as Map)['packs'], hasLength(1));
      final routing = c['routing'] as Map;
      expect((routing['valhalla'] as Map)['shim'], '/lib/libvalhalla_shim.so');
      expect((routing['offroad'] as Map).keys, ['pack', 'elevation']);
      expect((c['user'] as Map)['db_path'], endsWith('user.sqlite'));
    });

    test('off-road needs both files; with no tiles.tar the router is still configured, on the region engine\'s folder', () {
      touch('packs/idaho/places.sqlite');
      touch('packs/idaho/valhalla/tiles.tar');
      touch('packs/idaho/offroad.sqlite');
      // not both: off-road reads the packs downloaded with regions
      expect((build()['routing'] as Map)['offroad'], {'dir': '${support.path}/regions/offroad'});
      File('${files.path}/packs/idaho/valhalla/tiles.tar').deleteSync();
      final v = (build()['routing'] as Map)['valhalla'] as Map;
      expect(v['tiles'], '', reason: 'empty: the core routes on the regions folder');
      expect(v['shim'], '/lib/libvalhalla_shim.so');
      expect(build().containsKey('places'), isTrue);
    });

    test('the region engine is always configured, and a tiles.tar still wins when there is one', () {
      touch('packs/idaho/valhalla/tiles.tar');
      final c = build();
      expect(c['regions'], {
        'dir': '${support.path}/regions',
        'base_url': 'https://data.cached.info/routing/',
        'places_base_url': 'https://data.cached.info/places/',
      });
      final v = (c['routing'] as Map)['valhalla'] as Map;
      expect((v['tiles'] as String).replaceAll('\\', '/'), endsWith('/packs/idaho/valhalla/tiles.tar'));
    });

    test('places: the packs copied in by hand and the merged database of the downloaded regions', () {
      touch('packs/utah/places.sqlite');
      touch('packs/idaho/places.sqlite');
      touch('packs/idaho/valhalla/tiles.tar');
      final places = build()['places'] as Map;
      expect(places['merged_dir'], '${support.path}/regions/places');
      expect([for (final p in places['packs'] as List) (p as String).replaceAll('\\', '/').split('/').reversed.skip(1).first], ['idaho', 'utah']);
      expect(legacyPlacesPacks(files), places['packs'], reason: 'the same scan, callable again when the sources are refreshed');
      touch('packs/boise/places.sqlite');
      expect(legacyPlacesPacks(files), hasLength(3));
    });

    test('the data host can be another one that serves the same bucket', () {
      final c = buildCoreExtras(
        filesDir: files,
        supportDir: support,
        regionsBaseUrl: 'https://cache.echo6.co/routing/',
        placesBaseUrl: 'https://cache.echo6.co/places/',
      );
      expect((c['regions'] as Map)['base_url'], 'https://cache.echo6.co/routing/');
      expect((c['regions'] as Map)['places_base_url'], 'https://cache.echo6.co/places/');
      expect(kRoutingBaseUrl, '$kDataBaseUrl/routing/');
      expect(kPlacesBaseUrl, '$kDataBaseUrl/places/');
    });

    test('several regions give several places packs; no packs folder gives an empty list', () {
      expect((build()['places'] as Map)['packs'], isEmpty);
      touch('packs/idaho/places.sqlite');
      touch('packs/utah/places.sqlite');
      expect(((build()['places'] as Map)['packs'] as List).length, 2);
    });
  });
}

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

  test('routing is configured with the shim path it is given, on the region engine\'s folder; a hand-placed packs folder is not read', () {
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
    expect(v['tiles'], '', reason: 'empty: the core routes on the regions folder');
    expect(v['shim'], '/lib/libvalhalla_shim.so');
  });

  test('linked routing does not need a dynamic library path', () {
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
    expect(((build()['routing'] as Map)['valhalla'] as Map)['tiles'], '');
    expect(((build()['routing'] as Map)['valhalla'] as Map)['shim'], 'linked');
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

    test('places, routing and off-road come from region downloads only; hand-placed packs are not read', () {
      touch('packs/idaho/places.sqlite');
      touch('packs/idaho/valhalla/tiles.tar');
      touch('packs/idaho/offroad.sqlite');
      touch('packs/idaho/elevation.pmtiles');
      final c = build();
      expect(c['places'], {'packs': <String>[], 'merged_dir': '${support.path}/regions/places'});
      final routing = c['routing'] as Map;
      expect((routing['valhalla'] as Map)['tiles'], '');
      expect((routing['valhalla'] as Map)['shim'], '/lib/libvalhalla_shim.so');
      expect(routing['offroad'], {'dir': '${support.path}/regions/offroad'});
      expect((c['user'] as Map)['db_path'], endsWith('user.sqlite'));
      expect(c['regions'], {
        'dir': '${support.path}/regions',
        'base_url': 'https://data.cached.info/routing/',
        'places_base_url': 'https://data.cached.info/places/',
      });
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
  });
}

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
        '7b00000000-7b00200000 r-xp 00000000 fd:03 456 /data/app/~~x/co.cache.cache-y/lib/arm64/libcache_search.so\n'
        '7b00200000-7b00300000 rw-p 00200000 fd:03 456 /data/app/~~x/co.cache.cache-y/lib/arm64/libcache_search.so\n',
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
}

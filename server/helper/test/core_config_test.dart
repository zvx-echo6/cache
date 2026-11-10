import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../app/lib/search/core_config.dart';
import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../bin/core_open.dart';
import 'fake_native.dart';

/// The core config the server's helper builds (serverCoreExtras) and what `server.features` reports from it.
void main() {
  late Directory tmp, support, docs;
  late String shim;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('core_config_test');
    support = Directory('${tmp.path}/data/app/support')..createSync(recursive: true);
    docs = Directory('${tmp.path}/data/app/docs')..createSync(recursive: true);
    Directory('${tmp.path}/install/lib').createSync(recursive: true);
    shim = '${tmp.path}/install/lib/libvalhalla_shim.so';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the server passes the shim as a full path, and routing, places and regions sit under the data folder', () {
    final x = serverCoreExtras(AppDirs(support, docs, shim: shim));
    final routing = x['routing'] as Map;
    expect(routing['valhalla'], {'tiles': '', 'shim': shim});
    expect(File(shim).isAbsolute, isTrue);
    expect(routing['offroad'], {'dir': '${support.path}/regions/offroad'});
    expect(x['places'], {'packs': <String>[], 'merged_dir': '${support.path}/regions/places'});
    final regions = x['regions'] as Map;
    expect(regions['dir'], '${support.path}/regions');
    expect(regions['base_url'], kRoutingBaseUrl);
    expect(regions['places_base_url'], kPlacesBaseUrl);
  });

  test('the sections have the phone\'s shape: buildCoreExtras on the same folders, with the shim\'s full path', () {
    final server = serverCoreExtras(AppDirs(support, docs, shim: shim));
    final phone = buildCoreExtras(
      filesDir: docs,
      supportDir: support,
      layerDefsDir: Directory('${support.path}/layer-defs'),
      shim: shimPath('${tmp.path}/install/lib'),
      useLinkedRouter: false,
    );
    expect(jsonEncode(server), jsonEncode(phone));
    expect(server.keys.toSet(), {'indexes_dir', 'user', 'live', 'places', 'layers', 'routing', 'notebook', 'regions'});
  });

  test('CACHE_VALHALLA_SHIM from the environment; without it the bare name', () {
    final env = {'CACHE_APP_SUPPORT': support.path, 'CACHE_APP_DOCS': docs.path, 'CACHE_VALHALLA_SHIM': shim};
    expect(AppDirs.fromEnvironment(env)!.shim, shim);
    final bare = AppDirs.fromEnvironment({...env}..remove('CACHE_VALHALLA_SHIM'))!;
    expect(bare.shim, isNull);
    expect(((serverCoreExtras(bare)['routing'] as Map)['valhalla'] as Map)['shim'], 'libvalhalla_shim.so');
  });

  test('server.features: routing when the shim is a file, places when the merged database is there', () {
    final op = FeaturesOp(AppDirs(support, docs, shim: shim));
    expect(op.handles('server.features'), isTrue);
    var f = op.handle('server.features', {}) as Map;
    expect(f['routing'], {'available': false, 'shim': shim});
    expect(f['places'], {'available': false, 'merged_dir': '${support.path}/regions/places'});
    expect((f['extras'] as Map).containsKey('routing'), isFalse);
    expect((f['extras'] as Map).containsKey('places'), isTrue);

    File(shim).writeAsStringSync('');
    final places = Directory('${support.path}/regions/places')..createSync(recursive: true);
    File('${places.path}/CURRENT').writeAsStringSync('b7\n');
    f = op.handle('server.features', {}) as Map;
    expect((f['routing'] as Map)['available'], isTrue);
    expect((f['places'] as Map)['available'], isFalse, reason: 'CURRENT names a build that is not there');
    File('${places.path}/b7.sqlite').writeAsStringSync('');
    f = op.handle('server.features', {}) as Map;
    expect((f['places'] as Map)['available'], isTrue);
    expect((f['extras'] as Map)['routing'], (serverCoreExtras(AppDirs(support, docs, shim: shim))['routing']));
  });

  test('a bad CURRENT is not a places database', () {
    final places = Directory('${tmp.path}/p')..createSync();
    expect(mergedPlacesPresent(places.path), isFalse);
    File('${places.path}/CURRENT').writeAsStringSync('../x');
    File('${tmp.path}/x.sqlite').writeAsStringSync('');
    expect(mergedPlacesPresent(places.path), isFalse);
    expect(mergedPlacesPresent(''), isFalse);
  });

  test('open hands the core the shim\'s full path', () {
    final fake = FakeNative();
    final d = CoreDispatcher(() => fake);
    final logs = <String>[];
    OpenOp(AppDirs(support, docs, shim: shim), d, log: logs.add).handle('open', {'sources': []});
    final sent = jsonDecode(fake.calls.firstWhere((c) => c.startsWith('open:')).substring(5)) as Map;
    expect(((sent['routing'] as Map)['valhalla'] as Map)['shim'], shim);
    expect(logs.any((l) => l.contains('road routing: shim $shim missing')), isTrue);
  });
}

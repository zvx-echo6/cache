import 'dart:io';

import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_core.dart';
import 'package:cache_search/cache_search.dart';

import 'weather_fakes.dart';

/// The core's region engine with no network: regions download only when [finish] says so, the network rule pauses them, and a new
/// build is offered when [update] is set. [tileDir] is the folder the status names.
class FakeRegions implements RegionsCoreLike {
  FakeRegions({required this.tileDir});

  final String tileDir;
  final calls = <String>[];
  final policies = <Map<String, dynamic>>[];
  final added = <Map<String, dynamic>>[];
  final regions = <String, Map<String, dynamic>>{};

  /// Bytes a region's routing takes, by id (default 120 MB); what of it is already on the phone (default 40 MB).
  final Map<String, int> sizes = {};
  int alreadyBytes = 40 << 20;
  bool network = true;
  bool offline = false;
  bool closed = false;
  String build = '2026-10';

  /// A newer build {"build","download_bytes"}, or null.
  Map<String, dynamic>? update;

  int _size(String id) => sizes[id] ?? 120 << 20;

  /// The region's tiles are all here.
  void finish(String id) {
    final r = regions[id]!;
    r
      ..['state'] = 'ready'
      ..['done_tiles'] = r['tiles']
      ..['done_bytes'] = r['bytes'];
  }

  void _applyNetwork() {
    for (final r in regions.values) {
      if (!network && r['state'] == 'downloading') r['state'] = 'paused';
      if (network && r['state'] == 'paused') r['state'] = 'downloading';
    }
  }

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> args = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'status':
        return {
          'build': build,
          'tile_dir': tileDir,
          'regions': [for (final r in regions.values) Map<String, dynamic>.of(r)],
          'stream': {'tiles': 0, 'bytes': 0, 'cap': 1 << 30},
          'update': update,
          'paused': network ? null : 'No network it may use',
        };
      case 'set_policy':
        policies.add(Map.of(args));
        network = args['network'] == true;
        _applyNetwork();
        return {'ok': true};
      case 'plan':
        if (offline) throw const CacheSearchException('offline', 'The routing index could not be reached');
        final size = _size(args['id'] as String);
        return {'tiles': 100, 'bytes': size, 'download_bytes': size - alreadyBytes, 'shared_tiles': 30};
      case 'add':
        added.add(Map.of(args));
        final id = args['id'] as String;
        regions[id] = {
          'id': id,
          'name': args['name'],
          'state': network ? 'downloading' : 'paused',
          'tiles': 100,
          'bytes': _size(id),
          'done_tiles': 0,
          'done_bytes': 0,
          'error': null,
        };
        return {'ok': true};
      case 'remove':
        regions.remove(args['id']);
        return {'ok': true};
      case 'update':
        if (update != null) build = update!['build'] as String;
        update = null;
        return {'ok': true};
      default:
        return {'ok': true};
    }
  }

  @override
  Future<void> close() async => closed = true;
}

/// The trimmed catalogue fixtures (test/fixtures/regions_*), served where the real catalogue is. Every region's outline is the
/// Idaho fixture.
FakeWeb regionWeb() {
  final web = FakeWeb();
  List<int> f(String name) => File('test/fixtures/$name').readAsBytesSync();
  web.files['${kRegionCatalogueBase}index.json'] = f('regions_index.json');
  web.files['${kRegionCatalogueBase}us.json'] = f('regions_us.json');
  web.files['${kRegionCatalogueBase}us.search.json'] = f('regions_us.search.json');
  web.files['${kRegionCatalogueBase}search-global.json'] = f('regions_search_global.json');
  for (final id in ['us', 'us-id', 'us-ut', 'us-id-southern-idaho', 'us-id-magic-valley', 'us-id-twin-falls-county', 'us-id-twin-falls', 'us-id-jerome-county']) {
    web.files['${kRegionCatalogueBase}polygons/$id.geojson'] = f('regions_polygon_us-id.geojson');
  }
  return web;
}

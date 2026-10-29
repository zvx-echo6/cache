import 'dart:convert';
import 'dart:io';

import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_core.dart';
import 'package:cache_search/cache_search.dart';

import 'weather_fakes.dart';

/// The core's region engine with no network: regions download only when [finish] says so, the network rule pauses them, and a new
/// build is offered when [update] is set. [tileDir] is the folder the status names. With [placesEnabled] it also has the places
/// part (docs/PLACES-TILES.md): plans and statuses carry `parts`, and status has `places` and `updates`.
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

  /// The places part is on (the config has a places address and the core knows the part).
  bool placesEnabled = false;

  /// Bytes a region's places take (default 20 MB), and what of them is already on the phone (default 4 MB).
  int placesBytes = 20 << 20;
  int placesAlready = 4 << 20;

  /// The places part cannot be planned (its index is out of reach); road routing still is.
  bool placesOffline = false;

  /// The places index answers 404 (places not published yet).
  bool placesMissing = false;

  /// `places.generation`: one more on every merge, removal and build switch.
  int generation = 0;

  /// A newer places build {"build","download_bytes","downloading"}, or null.
  Map<String, dynamic>? placesUpdate;

  int _size(String id) => sizes[id] ?? 120 << 20;

  /// The region's tiles are all here (every part, or only [part]).
  void finish(String id, {String? part}) {
    final r = regions[id]!;
    void done(Map<String, dynamic> p) => p
      ..['state'] = 'ready'
      ..['done_tiles'] = p['tiles']
      ..['done_bytes'] = p['bytes'];
    final parts = r['parts'] as Map<String, dynamic>?;
    if (parts == null) {
      done(r);
      return;
    }
    for (final e in parts.entries) {
      if (part == null || e.key == part) {
        done(e.value as Map<String, dynamic>);
        if (e.key == 'places') generation++;
      }
    }
    _combine(r);
  }

  /// The region's state from its parts, and road routing's fields at the top, as the core gives them.
  void _combine(Map<String, dynamic> r) {
    final parts = (r['parts'] as Map<String, dynamic>).values.cast<Map<String, dynamic>>();
    final states = [for (final p in parts) p['state']];
    r['state'] = states.contains('failed')
        ? 'failed'
        : states.contains('paused')
            ? 'paused'
            : states.contains('downloading')
                ? 'downloading'
                : 'ready';
    final routing = (r['parts'] as Map)['routing'] as Map<String, dynamic>?;
    if (routing != null) {
      for (final k in ['tiles', 'bytes', 'done_tiles', 'done_bytes', 'error']) {
        r[k] = routing[k];
      }
    }
  }

  void _applyNetwork() {
    for (final r in regions.values) {
      final parts = r['parts'] as Map<String, dynamic>?;
      for (final p in parts == null ? [r] : parts.values.cast<Map<String, dynamic>>()) {
        if (!network && p['state'] == 'downloading') p['state'] = 'paused';
        if (network && p['state'] == 'paused') p['state'] = 'downloading';
      }
      if (parts != null) _combine(r);
    }
  }

  Map<String, dynamic> _copy(Map<String, dynamic> r) => {
    ...r,
    if (r['parts'] is Map) 'parts': {for (final e in (r['parts'] as Map).entries) e.key: Map<String, dynamic>.of(e.value as Map<String, dynamic>)},
  };

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> args = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'status':
        return {
          'build': build,
          'tile_dir': tileDir,
          'regions': [for (final r in regions.values) _copy(r)],
          'stream': {'tiles': 0, 'bytes': 0, 'cap': 1 << 30},
          'update': update,
          'paused': network ? null : 'No network it may use',
          if (placesEnabled) ...{
            'places': {
              'build': 'na-places-2026-11-15',
              'db': '$tileDir/../places/na-places-2026-11-15.sqlite',
              'tiles': 4,
              'generation': generation,
              'stream': {'tiles': 0, 'bytes': 0, 'cap': 1 << 29},
              'update': null,
            },
            'updates': {'routing': update, 'places': placesUpdate},
          },
        };
      case 'set_policy':
        policies.add(Map.of(args));
        network = args['network'] == true;
        _applyNetwork();
        return {'ok': true};
      case 'plan':
        if (offline) throw const CacheSearchException('offline', 'The routing index could not be reached');
        final size = _size(args['id'] as String);
        final routing = {'tiles': 100, 'bytes': size, 'download_bytes': size - alreadyBytes, 'shared_tiles': 30};
        if (!placesEnabled) return routing;
        return {
          ...routing,
          'parts': {
            'routing': routing,
            'places': placesOffline
                ? {'error': 'The places index could not be reached', 'code': 'offline'}
                : placesMissing
                ? {'error': 'HTTP 404 from https://data.cached.info/places/current.json', 'code': 'fetch_failed'}
                : {'tiles': 4, 'bytes': placesBytes, 'download_bytes': placesBytes - placesAlready, 'shared_tiles': 1},
          },
        };
      case 'add':
        added.add(Map.of(args));
        final id = args['id'] as String;
        if (placesEnabled) {
          final r = regions[id] ??= {'id': id, 'name': args['name'], 'parts': <String, dynamic>{}};
          for (final p in (args['parts'] as List? ?? const ['routing', 'places']).cast<String>()) {
            (r['parts'] as Map<String, dynamic>)[p] = {
              'state': network ? 'downloading' : 'paused',
              'tiles': p == 'routing' ? 100 : 4,
              'bytes': p == 'routing' ? _size(id) : placesBytes,
              'done_tiles': 0,
              'done_bytes': 0,
              'error': null,
            };
          }
          _combine(r);
          return {'ok': true};
        }
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
        final r = regions.remove(args['id']);
        if ((r?['parts'] as Map?)?.containsKey('places') ?? false) generation++;
        return {'ok': true};
      case 'update':
        final c = args['component'];
        if (c == null || c == 'routing') {
          if (update != null) build = update!['build'] as String;
          update = null;
        }
        if ((c == null || c == 'places') && placesUpdate != null) placesUpdate = {...placesUpdate!, 'downloading': true};
        return {'ok': true};
      default:
        return {'ok': true};
    }
  }

  @override
  Future<void> close() async => closed = true;
}

/// The trimmed catalogue fixtures (test/fixtures/regions_*), served where the real catalogue is; the outlines where the index
/// says they are (its `polygon_base`). Every region's outline is the Idaho fixture.
FakeWeb regionWeb() {
  final web = FakeWeb();
  List<int> f(String name) => File('test/fixtures/$name').readAsBytesSync();
  final polygons = (jsonDecode(File('test/fixtures/regions_index.json').readAsStringSync()) as Map)['polygon_base'] as String;
  web.files['${kRegionCatalogueBase}index.json'] = f('regions_index.json');
  web.files['${kRegionCatalogueBase}us.json'] = f('regions_us.json');
  web.files['${kRegionCatalogueBase}us.search.json'] = f('regions_us.search.json');
  web.files['${kRegionCatalogueBase}search-global.json'] = f('regions_search_global.json');
  for (final id in ['us', 'us-id', 'us-ut', 'us-id-southern-idaho', 'us-id-magic-valley', 'us-id-twin-falls-county', 'us-id-twin-falls', 'us-id-jerome-county']) {
    web.files['$polygons$id.geojson'] = f('regions_polygon_us-id.geojson');
  }
  return web;
}

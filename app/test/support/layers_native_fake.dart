import 'dart:io' show sleep;
import 'dart:convert';

import 'package:cache/maps/geo.dart';
import 'package:cache_search/cache_search.dart';

const GeoBounds layersHome = GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);

/// The core's layer engine as far as the app can tell: a stateful stand-in for the cs_layers_* calls and layer_download
/// jobs, living in the core's worker isolate (so it holds its state there). It answers like cache_search.h says.
class LayersNative implements CsNative {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  int port = 0;
  int scale = 1;
  int plans = 0;
  int planMs = 0;
  bool online = true;
  String? error;
  final Map<String, Map<String, dynamic>> user = {};
  final List<Map<String, dynamic>> areas = []; // the elevation store
  final Map<int, Map<String, dynamic>> jobs = {};
  final List<String> calls = [];
  int _job = 0;
  int frees = 0;

  Map<String, dynamic> _def(String id, String kind, {Map<String, dynamic> extra = const {}}) =>
      {'format': 1, 'id': id, 'title': id, 'description': 'd', 'kind': kind, 'transform': 'as_is', 'license': 'l', 'attribution': 'a', ...extra};

  List<Map<String, dynamic>> _defs() => [
        _def('contours', 'vector', extra: {'transform': 'contours', 'derived_from': 'elevation'}),
        _def('hillshade', 'elevation', extra: {'transform': 'hillshade', 'derived_from': 'elevation'}),
        _def('esri', 'raster', extra: {
          'transform': 'online_only',
          'source': {'type': 'xyz', 'url': 'https://e.test/{z}/{x}/{y}', 'maxzoom': 18},
          'offline': {'allowed': false}
        }),
        _def('elevation', 'elevation', extra: {
          'source': {'type': 'tilejson', 'url': 'https://t.test/t.json', 'maxzoom': 12, 'tile_size': 512, 'encoding': 'terrarium'},
        }),
        _def('basemap', 'vector', extra: {
          'layout': 'protomaps-v4',
          'source': {'type': 'pmtiles', 'url': 'https://p.test/p.pmtiles', 'minzoom': 0, 'maxzoom': 15},
        }),
        ...user.values,
      ];

  /// The areas kept in one layer's store (a basemap download lands in the basemap store; hillshade and contours share elevation's).
  List<Map<String, dynamic>> _storeOf(Object? store) => [for (final a in areas) if (a['layer'] == store) a];

  Map<String, dynamic> _list() => {
        'layers': [
          for (final d in _defs())
            {
              'definition': d,
              'origin': user.containsKey(d['id']) ? 'user' : 'folder',
              'download_layer': d['derived_from'] ?? d['id'],
              'downloadable': d['id'] != 'esri',
              'installed': _storeOf(d['derived_from'] ?? d['id']).isNotEmpty
                  ? {
                      'downloaded': _storeOf(d['derived_from'] ?? d['id']).isNotEmpty,
                      'bytes': _storeOf(d['derived_from'] ?? d['id']).fold<int>(0, (s, a) => s + (a['bytes'] as int)),
                      'areas': [for (final a in _storeOf(d['derived_from'] ?? d['id'])) if (a['partial'] != true) a],
                      'partial': [
                        for (final a in _storeOf(d['derived_from'] ?? d['id']))
                          if (a['partial'] == true) {'area': a['id'], 'name': a['name'], 'tiles_total': a['tiles_requested'], 'version': '1'}
                      ],
                    }
                  : {'downloaded': false, 'bytes': 0, 'areas': [], 'partial': []},
            }
        ],
        'online': online,
        'job_frees': frees,
        'viewed_cache': {'bytes': 1000, 'max_bytes': 268435456},
      };

  @override
  int open(String configJson) {
    port = ((jsonDecode(configJson) as Map)['test_port'] as num?)?.toInt() ?? 4321;
    scale = ((jsonDecode(configJson) as Map)['test_scale'] as num?)?.toInt() ?? 1;
    planMs = ((jsonDecode(configJson) as Map)['test_plan_ms'] as num?)?.toInt() ?? 0;
    return 7;
  }

  @override
  String? lastError(int handle) => error;

  @override
  void close(int handle) {}

  @override
  String? layers(int handle, String op, String? arg) {
    calls.add('$op:$arg');
    error = null;
    switch (op) {
      case 'server':
        if (arg != null) online = (jsonDecode(arg) as Map)['online'] as bool;
        return jsonEncode({'port': port, 'base_url': 'http://127.0.0.1:$port', 'online': online});
      case 'test_calls':
        // What the app asked of the core so far (the jobs with their requests).
        return jsonEncode({'calls': calls});
      case 'test_new_port':
        // The core's tile server lost its socket and the next 'server' call starts a new one on a new port.
        port = int.parse(arg!);
        return jsonEncode({'port': port});
      case 'list':
        return jsonEncode(_list());
      case 'refresh':
        if (!online) {
          error = jsonEncode({'code': 'offline', 'message': 'no connection'});
          return null;
        }
        return jsonEncode({'catalogues': [], 'updates': {}});
      case 'plan':
        final r = (jsonDecode(arg!) as Map).cast<String, dynamic>();
        final z = r['maxzoom'] as int;
        if (r['layer'] == 'esri') {
          error = jsonEncode({'code': 'offline', 'message': 'online only'});
          return null;
        }
        final tooBig = z > 13;
        final already = areas.isNotEmpty ? 40 : 0;
        plans++;
        // A plan reads the source over the network: the worker is busy for that long.
        if (planMs > 0) sleep(Duration(milliseconds: planMs));
        return jsonEncode({
          'tiles': 100 * z,
          'tiles_to_download': 100 * z - already,
          'tiles_already': already,
          'already_bytes': already * 1000,
          'estimated_bytes': scale * 1000 * (100 * z - already),
          'plans_so_far': plans,
          'ok_to_start': !tooBig,
          'problems': tooBig ? [{'code': 'limit_exceeded', 'message': 'too many tiles for one download'}] : [],
        });
      case 'delete':
        final r = (jsonDecode(arg!) as Map).cast<String, dynamic>();
        areas.removeWhere((a) => a['id'] == r['area']);
        return jsonEncode({'layer': r['layer'], 'removed': [r['area']]});
      case 'save':
        final d = (jsonDecode(arg!) as Map).cast<String, dynamic>();
        if (d['title'] == 'bad') {
          error = jsonEncode({'code': 'bad_json', 'message': 'title: not allowed'});
          return null;
        }
        user[d['id'] as String] = d;
        return jsonEncode({'id': d['id'], 'saved': true});
      case 'remove':
        user.remove(arg);
        return jsonEncode({'id': arg, 'removed': true});
    }
    throw ArgumentError(op);
  }

  @override
  int jobStart(String kind, String paramsJson) {
    final p = (jsonDecode(paramsJson) as Map).cast<String, dynamic>();
    calls.add('job:$kind:${jsonEncode({for (final e in p.entries) if (e.key != 'layers') e.key: e.value})}');
    final id = ++_job;
    // A resumed download (the same area id) carries on the unfinished one.
    if (p['update'] != true && !areas.any((a) => a['id'] == p['area'])) {
      areas.add({
        'id': p['area'],
        'name': p['name'],
        'layer': p['layer'] == 'basemap' ? 'basemap' : 'elevation',
        'bbox': p['bbox'],
        'minzoom': p['minzoom'],
        'maxzoom': p['maxzoom'],
        'tiles_requested': 20,
        'tiles_present': 0,
        'bytes': 0,
        'created': '2026-10-26T10:00:00Z',
        'partial': true,
      });
    }
    jobs[id] = {'area': p['area'], 'update': p['update'] == true, 'polls': 0, 'cancelled': false, 'fail': p['name'] == 'fails'};
    return id;
  }

  @override
  String? jobProgress(int job) {
    final j = jobs[job]!;
    j['polls'] = (j['polls'] as int) + 1;
    if (j['cancelled'] == true) return jsonEncode({'state': 'cancelled', 'done': 3, 'total': 20, 'error': null});
    if (j['fail'] == true && (j['polls'] as int) > 1) {
      return jsonEncode({'state': 'failed', 'done': 3, 'total': 20, 'error': {'code': 'offline', 'message': 'x'}});
    }
    if ((j['polls'] as int) < 3) {
      return jsonEncode({'state': 'running', 'done': 5, 'total': 20, 'error': null, 'detail': {'bytes': 5000}});
    }
    final a = areas.firstWhere((a) => a['id'] == j['area']);
    a
      ..['partial'] = false
      ..['tiles_present'] = 20
      ..['bytes'] = 20000
      ..['created'] = j['update'] == true ? '2026-10-27T10:00:00Z' : a['created'];
    return jsonEncode({'state': 'done', 'done': 20, 'total': 20, 'error': null, 'detail': {'bytes': 20000}});
  }

  @override
  int jobCancel(int job) {
    jobs[job]!['cancelled'] = true;
    return 0;
  }

  @override
  void jobFree(int job) => frees++;
}

CsNative makeLayersNative() => LayersNative();


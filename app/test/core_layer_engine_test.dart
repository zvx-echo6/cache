import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/core_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

const GeoBounds home = GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);

/// The core's layer engine as far as the app can tell: a stateful stand-in for the cs_layers_* calls and layer_download
/// jobs, living in the core's worker isolate (so it holds its state there). It answers like cache_search.h says.
class _LayersNative implements CsNative {
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

  Map<String, dynamic> _list() => {
        'layers': [
          for (final d in _defs())
            {
              'definition': d,
              'origin': user.containsKey(d['id']) ? 'user' : 'folder',
              'download_layer': d['derived_from'] ?? d['id'],
              'downloadable': d['id'] != 'esri',
              'installed': (d['derived_from'] ?? d['id']) == 'elevation'
                  ? {
                      'downloaded': areas.isNotEmpty,
                      'bytes': areas.fold<int>(0, (s, a) => s + (a['bytes'] as int)),
                      'areas': [for (final a in areas) if (a['partial'] != true) a],
                      'partial': [
                        for (final a in areas)
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
        'layer': 'elevation',
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

CsNative _makeNative() => _LayersNative();

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(ok(), isTrue, reason: 'timed out');
}

void main() {
  late SearchCore core;
  late CoreLayerEngine engine;
  late HttpServer server;
  late Directory layersDir;
  var connected = true;

  setUp(() async {
    connected = true;
    layersDir = Directory.systemTemp.createTempSync('layers');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      // The tile server stand-in: tiles under /layers/hillshade are on the phone, nothing else is.
      r.response.statusCode = r.uri.path.startsWith('/layers/hillshade/') ? 200 : 404;
      await r.response.close();
    });
    core = await SearchCore.open(const [], extra: {'test_port': server.port}, native: _makeNative);
    engine = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => connected,
      pollEvery: const Duration(milliseconds: 20),
    );
    await engine.start();
  });
  tearDown(() async {
    addTearDown(() {
      try {
        layersDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    engine.dispose();
    await core.close();
    await server.close(force: true);
  });

  test('start opens the tile server, reads the catalogue and orders it for drawing', () {
    expect(engine.ready, isTrue);
    expect(engine.problem, isNull);
    expect(engine.tilesUrl('basemap'), 'http://127.0.0.1:${server.port}/layers/basemap/{z}/{x}/{y}');
    expect(engine.tileJsonUrl('hillshade'), 'http://127.0.0.1:${server.port}/layers/hillshade/tilejson.json');
    expect([for (final l in engine.layers) l.id], ['basemap', 'elevation', 'esri', 'hillshade', 'contours']);
    expect(engine.layer('basemap')!.isBase, isTrue);
    expect(engine.layer('basemap')!.defaultOn, isTrue);
    expect(engine.layer('esri')!.onlineOnly, isTrue);
    // Hillshade has no source: it is served at the elevation layer's zooms and tile size; contours at 3 to 15.
    expect(engine.layer('hillshade')!.maxZoom, 12);
    expect(engine.layer('hillshade')!.tileSize, 512);
    expect(engine.layer('contours')!.minZoom, 3);
    expect(engine.layer('contours')!.maxZoom, 15);
  });

  test('a core that cannot open leaves the layers unavailable with a plain message', () async {
    final e = CoreLayerEngine(openCore: () async => null, layersConfig: () => {});
    await e.start();
    expect(e.ready, isFalse);
    expect(e.problem, 'Layers are not available on this device');
    e.dispose();
  });

  test('the estimate is the plan: it steps down to the detail that fits the source, and shows what is already here', () async {
    final e = await engine.estimate('basemap', home);
    expect(e.allowed, isTrue);
    expect(e.maxZoom, 13, reason: 'zoom 15 and 14 were over the layer\'s limit');
    expect(e.tiles, 1300);
    expect(e.bytes, 1300 * 1000);
    expect(e.tilesAlready, 0);
    final online = await engine.estimate('esri', home);
    expect(online.allowed, isFalse);
    expect(online.problem, contains('offline'));
  });

  test('estimates run on a core of their own, so the main core is never held up by them; the same one is asked once', () async {
    final opened = <Map<String, dynamic>>[];
    SearchCore? planner;
    final e = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      // The planner's stand-in answers ten times the main one's bytes, so the answer says which core planned.
      openPlanner: (layers) async {
        opened.add(layers);
        return planner = await SearchCore.open(const [], extra: {'layers': layers, 'test_scale': 10, 'test_plan_ms': 300}, native: _makeNative);
      },
    );
    await e.start();
    // The catalogue refresh that start begins (a changed catalogue drops the planner) is over before the estimates.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // While the slow plans run, the main core still answers at once (the map's start, the Library, the reader use it).
    final planning = e.estimate('basemap', home);
    await until(() => planner != null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final watch = Stopwatch()..start();
    await core.layers('list');
    expect(watch.elapsedMilliseconds, lessThan(250), reason: 'the main core did not wait for the plans (3 x 300 ms)');
    final first = await planning;
    expect(first.bytes, 10 * 1300 * 1000, reason: 'planned on the second core');
    expect(opened, [
      {'dir': layersDir.path, 'online': true},
    ], reason: 'opened once, with the layers section only');
    final again = await Future.wait([e.estimate('basemap', home), e.estimate('basemap', home)]);
    expect(again.map((a) => a.bytes), [first.bytes, first.bytes]);
    expect((await planner!.layers('plan', jsonEncode({'layer': 'elevation', 'bbox': [0, 0, 1, 1], 'maxzoom': 1})))['plans_so_far'], 4,
        reason: 'the three asks for the same area planned once (zooms 15, 14 and 13)');
    // A changed catalogue opens the planner again, with the new definitions, and drops what was kept.
    await e.saveDefinition(jsonEncode({'format': 1, 'id': 'mine', 'title': 'Mine', 'description': 'd', 'kind': 'raster', 'transform': 'as_is', 'license': 'l', 'attribution': 'a',
      'source': {'type': 'xyz', 'url': 'https://m.test/{z}/{x}/{y}', 'maxzoom': 10}}));
    await e.estimate('basemap', home);
    expect(opened, hasLength(2));
    e.dispose();
  });

  test('a download runs as a layer_download job, shows progress, then is a finished area', () async {
    final a = await engine.download('hillshade', home, label: 'This region');
    expect(a.phase, AreaPhase.running);
    expect(engine.areasOf('hillshade'), [a]);
    await until(() => a.phase == AreaPhase.done);
    expect(a.doneTiles, 20);
    expect(a.bytes, 20000);
    expect(a.bounds, home);
    expect(engine.storageOf('hillshade'), 20000);
    expect(engine.storageTotal, 20000 + 1000, reason: 'downloaded tiles plus the viewed-tile cache');
    expect(engine.areasOf('contours'), hasLength(1), reason: 'hillshade and contours share the elevation store');
    // Delete goes to the layer that holds the tiles.
    await engine.delete(a.id);
    expect(engine.areasOf('hillshade'), isEmpty);
    expect(engine.storageOf('hillshade'), 0);
  });

  test('cancel stops a first download and leaves nothing', () async {
    final a = await engine.download('hillshade', home, label: 'This region');
    // cancel returns when the download has ended and been cleaned up, so there is nothing to wait for afterwards.
    await engine.cancel(a.id);
    expect(engine.areasOf('hillshade'), isEmpty);
    expect(engine.storageOf('hillshade'), 0);
    // And nothing of it comes back when the lists are read again, nor on a later look at the downloads.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(engine.areasOf('hillshade'), isEmpty);
    expect(a.phase, isNot(AreaPhase.failed));
  });

  test('a cancel that is waiting when the engine is disposed returns, and nothing notifies a listener that is gone', () async {
    final e = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
    );
    await e.start();
    var calls = 0;
    e.addListener(() => calls++);
    final a = await e.download('hillshade', home, label: 'This region');
    final cancelled = e.cancel(a.id);
    e.dispose();
    await cancelled;
    final seen = calls;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(calls, seen, reason: 'no look at the downloads after dispose');
  });

  test('a finished job is freed once', () async {
    final a = await engine.download('hillshade', home, label: 'This region');
    await until(() => a.phase == AreaPhase.done);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await core.layers('list'))['job_frees'], 1);
    expect(engine.areasOf('hillshade'), [a]);
  });

  test('update fetches the area again and keeps the old copy in use until it is done', () async {
    final a = await engine.download('hillshade', home, label: 'This region');
    await until(() => a.phase == AreaPhase.done);
    final first = a.fetchedAt!;
    await engine.update(a.id);
    expect(a.phase, AreaPhase.running);
    expect(a.fetchedAt, first, reason: 'the old copy stays until the new one is complete');
    await until(() => a.phase == AreaPhase.done && a.fetchedAt!.isAfter(first));
  });

  test('a download that fails says why in plain words and can be continued', () async {
    final a = await engine.download('hillshade', home, label: 'fails');
    await until(() => a.phase != AreaPhase.running);
    expect(a.phase, AreaPhase.failed);
    expect(a.error, contains('No connection'));
  });

  test('a download cut off when the app was closed (iPhone stops it in the background) is carried on by Update after a restart', () async {
    final a = await engine.download('hillshade', home, label: 'cut off');
    expect(a.phase, AreaPhase.running);
    // The app is closed mid-download: the core's list keeps it as unfinished, the shape asked for is only in the app.
    engine.dispose();
    final again = engine = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
    );
    await again.start();
    final stopped = again.areasOf('hillshade').single;
    expect(stopped.phase, AreaPhase.failed);
    expect(stopped.error, contains('Stopped before it finished'));
    await again.update(stopped.id);
    for (final l in ['elevation', 'hillshade', 'contours']) {
      expect(again.areasOf(l).single.error, isNot(contains('cannot be continued')), reason: l);
    }
    await until(() => again.areasOf('hillshade').single.phase == AreaPhase.done);
    expect(again.areasOf('hillshade').single.error, isNull);
  });

  test('a download stopped in an older build, with no shape kept by the app, carries on from the shape the core stored', () async {
    // 1.0.27 said "This download cannot be continued. Delete it and start again." and offered nothing else; the core keeps the
    // shape of every unfinished area, so the app asks it to carry on by the area alone.
    final a = await engine.download('hillshade', home, label: 'Idaho');
    expect(a.phase, AreaPhase.running);
    engine.dispose();
    File('${layersDir.path}/unfinished-downloads.json').deleteSync();
    final again = engine = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
    );
    await again.start();
    final stopped = again.areasOf('hillshade').single;
    expect(stopped.phase, AreaPhase.failed);
    await again.update(stopped.id);
    await until(() => again.areasOf('hillshade').single.phase == AreaPhase.done);
    expect(again.areasOf('hillshade').single.error, isNull, reason: 'carried on, not "cannot be continued"');
  });

  test('definitions are saved, listed as the user\'s own, removed; the core refusing one is a format error', () async {
    await engine.saveDefinition(jsonEncode({'id': 'mine', 'title': 'My layer', 'kind': 'raster', 'source': {'url': 'https://example.com/{z}/{x}/{y}.png'}}));
    expect(engine.layer('mine'), isNotNull);
    expect(engine.canRemove('mine'), isTrue);
    expect(engine.canRemove('basemap'), isFalse);
    await engine.removeDefinition('mine');
    expect(engine.layer('mine'), isNull);
    expect(() => engine.saveDefinition('{"id": "x"}'), throwsFormatException);
    expect(() => engine.saveDefinition('not json'), throwsFormatException);
    expect(() => engine.saveDefinition(jsonEncode({'id': 'bad', 'title': 'bad'})), throwsFormatException);
  });

  test('losing the connection tells the engine it may not use the network; coverage is read from the tile server', () async {
    expect(await engine.hasTiles('hillshade', home, 8), isTrue);
    expect(await engine.hasTiles('basemap', home, 8), isFalse);
    connected = false;
    await engine.refreshOnline(force: true);
    expect(engine.online, isFalse);
    expect((await core.layers('list'))['online'], isFalse);
    connected = true;
    await engine.refreshOnline(force: true);
    expect(engine.online, isTrue);
    expect((await core.layers('list'))['online'], isTrue);
  });

  test('a stopped download never shows a server address', () {
    expect(CoreLayerEngine.words('internal', 'HTTP 500 from https://cache.echo6.co/basemap/x.pmtiles'), 'The download stopped. Tap Update to continue.');
    expect(CoreLayerEngine.words('internal', 'disk error'), 'The download stopped: disk error');
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/core_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layers_native_fake.dart';

const GeoBounds home = layersHome;

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
    core = await SearchCore.open(const [], extra: {'test_port': server.port}, native: makeLayersNative);
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
        return planner = await SearchCore.open(const [], extra: {'layers': layers, 'test_scale': 10, 'test_plan_ms': 300}, native: makeLayersNative);
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
    // done is shown when the job ends; the store's size comes with the list the core is read for next
    await until(() => a.phase == AreaPhase.done && engine.storageOf('hillshade') == 20000);
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

  test('a finished job is shown done at once even when the core\'s list is slow to answer, and the slow list is waited for, not asked again at every look (web-region-progress)', () async {
    // The browser: every call goes through the server one at a time, so the list read after a job ends can queue behind a long call.
    final slow = await SearchCore.open(const [], extra: {'test_port': server.port, 'test_list_block_ms': 3000}, native: makeLayersNative);
    final e = CoreLayerEngine(
      openCore: () async => slow,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
      reloadTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async {
      e.dispose();
      await slow.close();
    });
    await e.start();
    final a = await e.download('hillshade', home, label: 'slow list');
    final clock = Stopwatch()..start();
    while (clock.elapsedMilliseconds < 2000 && a.phase != AreaPhase.done) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // The list blocks for 3 s after the job reports done: the page must not wait for it.
    expect(a.phase, AreaPhase.done, reason: 'done within 2 s although the list takes 3 s');
    expect(a.doneTiles, 20);
    expect(a.bytes, 20000);
    // The look is not stuck, and does not pile calls on a call that is already slow: the list was asked for once more after the
    // start (the one that took 3 s), and not once per look in the meantime.
    final lists = ((await slow.layers('test_calls'))['calls'] as List).where((c) => (c as String).startsWith('list')).length;
    expect(lists, inInclusiveRange(2, 3), reason: 'start, and the read that was waited for');
    expect(a.phase, AreaPhase.done);
  });

  test('a download that ends with no connection after the app left the front is Paused, not Stopped: no connection (web-region-progress)', () async {
    final back = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
      inBackground: () => true,
    );
    addTearDown(back.dispose);
    await back.start();
    final a = await back.download('hillshade', home, label: 'fails');
    await until(() => a.phase == AreaPhase.failed);
    expect(a.paused, isTrue, reason: 'the phone cut a background app off the network: Resume carries it on');
    expect(a.error ?? '', isNot(contains('No connection')), reason: 'no "no connection" words for it');
    // in front the same end is a real failure, with its words
    final b = await engine.download('elevation', home, label: 'fails');
    await until(() => b.phase == AreaPhase.failed);
    expect(b.paused, isFalse);
    expect(b.error, isNotNull);
  });

  test('a look that fails with a raw object (a JS error in the browser) still ends with the area done and the list read; the failing step is named (web-region-progress)', () async {
    expect(CoreLayerEngine.said(Object()), 'Object');
    expect(CoreLayerEngine.said(_Named('QuotaExceededError')), '_Named (QuotaExceededError)');
    var thrown = 0;
    engine.stepHook = (step) {
      // a raw object, not an Exception or Error, as a JS error reaches Dart; once, at the step after the job ended
      if (step == 'reload' && thrown++ == 0) throw _Named('boom');
    };
    final a = await engine.download('hillshade', home, label: 'raw throw');
    await until(() => a.phase == AreaPhase.done);
    expect(a.doneTiles, 20);
    // the look that failed did not end the looking: the list is read at the next one
    await until(() => engine.areasOf('hillshade').single.fetchedAt != null);
    expect(thrown, greaterThanOrEqualTo(2), reason: 'the step was entered again by the retry');
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
    // done is shown when the job ends; the date comes with the list the core is read for next
    await until(() => a.phase == AreaPhase.done && a.fetchedAt != null);
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

  test('a page loaded again while the server keeps downloading takes the running job back, and Pause stops it (web-region-progress)', () async {
    // As in a browser: the engine keeps the job's number with the unfinished download.
    engine.dispose();
    engine = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
      reattachJobs: true,
    );
    await engine.start();
    final a = await engine.download('hillshade', home, label: 'reloaded');
    expect(a.phase, AreaPhase.running);
    // The tab is closed or reloaded; the server's job (the same core) goes on.
    engine.dispose();
    final again = engine = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
      reattachJobs: true,
    );
    await again.start();
    final back = again.areasOf('hillshade').single;
    expect(back.phase, AreaPhase.running, reason: 'before: it read as stopped part way while the server was still downloading');
    await again.pause(back.id);
    await until(() => back.phase == AreaPhase.failed);
    expect(back.paused, isTrue, reason: 'Pause reached the server job and the area reads as paused');
  });

  test('two downloads running together: when both jobs end every listing of both areas reads done at once, with the final size (web-region-progress)', () async {
    const other = GeoBounds(south: 42.70, west: -113.80, north: 42.80, east: -113.66);
    final a = await engine.download('hillshade', home, label: 'first');
    final b = await engine.download('elevation', other, label: 'second');
    expect(a.phase, AreaPhase.running);
    expect(b.phase, AreaPhase.running);
    // The engine says when it has something new (every look at the jobs ends with a notice, after the list is read again): the test
    // looks at the state then. It never polls and never keeps time, so a slow machine only makes it later, not wrong.
    bool listed(String layer) {
      final xs = engine.areasOf(layer);
      return xs.length == 2 && xs.every((x) => x.phase == AreaPhase.done && x.bytes == 20000 && x.doneTiles == 20);
    }

    // hillshade, contours and elevation share the store: each lists both areas, done, with the final size
    bool settled() => ['elevation', 'hillshade', 'contours'].every(listed);
    final seen = Completer<void>();
    void look() {
      if (settled() && !seen.isCompleted) seen.complete();
    }

    engine.addListener(look);
    look();
    await seen.future;
    engine.removeListener(look);
    expect(engine.allAreas.length, 2);
    for (final x in engine.allAreas) {
      expect(x.phase, AreaPhase.done, reason: x.id);
      expect(x.bytes, 20000, reason: 'the final size from the core, not the last progress read');
      expect(x.doneTiles, 20);
    }
    // every listing of an area (hillshade, contours and elevation share the store) is done too
    for (final l in ['elevation', 'hillshade', 'contours']) {
      expect(engine.areasOf(l), hasLength(2), reason: l);
      expect(engine.areasOf(l).every((x) => x.phase == AreaPhase.done), isTrue, reason: l);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an outline goes to the core with the download and again when an unfinished one is carried on; the bar counts its tiles', () async {
    final outline = [
      [
        [-113.8, 42.5],
        [-113.66, 42.5],
        [-113.73, 42.6],
        [-113.8, 42.5],
      ],
    ];
    Future<List<Map<String, dynamic>>> jobs() async => [
          for (final c in ((await core.layers('test_calls'))['calls'] as List).cast<String>())
            if (c.startsWith('job:layer_download:')) (jsonDecode(c.substring('job:layer_download:'.length)) as Map).cast<String, dynamic>(),
        ];
    final a = await engine.download('hillshade', home, label: 'Outline', outline: outline);
    // The estimate was of the box (1200 tiles here); the job counts the outline's, and the bar follows the job.
    expect(a.totalTiles, 1200);
    final first = (await jobs()).single;
    expect(first['polygon'], outline);
    expect(first['bbox'], [home.west, home.south, home.east, home.north], reason: 'the box stays: the zoom was chosen for it');
    await until(() => a.doneTiles > 0);
    expect(a.totalTiles, 20);
    await until(() => a.phase == AreaPhase.done);

    // Closed mid-download and opened again: Update carries it on with the same outline.
    await engine.download('hillshade', home, label: 'Cut off', outline: outline);
    engine.dispose();
    final again = engine = CoreLayerEngine(
      openCore: () async => core,
      layersConfig: () => {'dir': layersDir.path},
      connected: () async => true,
      pollEvery: const Duration(milliseconds: 20),
    );
    await again.start();
    final stopped = again.areasOf('hillshade').firstWhere((x) => x.label == 'Cut off');
    expect(stopped.phase, AreaPhase.failed);
    await again.update(stopped.id);
    expect((await jobs()).last['polygon'], outline);
    await until(() => again.areasOf('hillshade').firstWhere((x) => x.label == 'Cut off').phase == AreaPhase.done);

    // A box alone sends no outline.
    await again.download('hillshade', home, label: 'Box');
    expect((await jobs()).last.containsKey('polygon'), isFalse);
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

  test('the connection coming back gives the map new source addresses, so tiles it had no answer for are asked again', () async {
    expect(engine.sourcesGeneration, 0);
    connected = false;
    await engine.refreshOnline(force: true);
    expect(engine.sourcesGeneration, 0, reason: 'going offline reloads nothing');
    connected = true;
    await engine.refreshOnline(force: true);
    expect(engine.sourcesGeneration, 1);
    expect(engine.tilesUrl('basemap'), 'http://127.0.0.1:${server.port}/layers/basemap/{z}/{x}/{y}?g=1');
    expect(engine.tileJsonUrl('hillshade'), 'http://127.0.0.1:${server.port}/layers/hillshade/tilejson.json?g=1');
  });

  test('a tile server started again on a new port gives the map new addresses, and listeners hear of it', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    // The port each notification shows. The catalogue refresh that start() began may also notify meanwhile (it changes no
    // address), so the test looks at what the listeners see, not at how many times they are called.
    final heard = <int>[];
    engine.addListener(() => heard.add(engine.port));
    await engine.recheckServer();
    expect(engine.port, server.port, reason: 'the same port changes nothing');
    expect(heard.where((p) => p != server.port), isEmpty);
    await core.layers('test_new_port', '${other.port}');
    await engine.recheckServer();
    expect(engine.port, other.port);
    expect(heard.last, other.port, reason: 'listeners hear of the new port');
    expect(engine.tilesUrl('basemap'), 'http://127.0.0.1:${other.port}/layers/basemap/{z}/{x}/{y}');
    expect(engine.tileJsonUrl('hillshade'), 'http://127.0.0.1:${other.port}/layers/hillshade/tilejson.json');
  });

  test('a stopped download never shows a server address', () {
    expect(CoreLayerEngine.words('internal', 'HTTP 500 from https://cache.echo6.co/basemap/x.pmtiles'), 'The download stopped. Tap Update to continue.');
    expect(CoreLayerEngine.words('internal', 'disk error'), 'The download stopped: disk error');
  });
}

/// A thrown object that is neither an Exception nor an Error, with a `name` as a browser's error objects have.
class _Named {
  _Named(this.name);
  final String name;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/fake_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/layers/tile_math.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:flutter_test/flutter_test.dart';

const GeoBounds home = GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);

/// A pretend public host: the TileJSON for the base map and 1 KB for every other tile.
class Host {
  final List<Uri> calls = [];
  bool offline = false;
  Completer<void>? gate;

  Future<FetchedTile?> fetch(Uri u) async {
    if (offline) throw const SocketException('no route');
    calls.add(u);
    await gate?.future;
    if (u.path == '/planet') {
      return FetchedTile(utf8.encode(jsonEncode({'tiles': ['https://tiles.example/planet/v1/{z}/{x}/{y}.pbf']})));
    }
    return FetchedTile(List.filled(1000, 7), contentType: u.path.endsWith('.webp') ? 'image/webp' : 'application/x-protobuf');
  }
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(ok(), isTrue, reason: 'timed out');
}

void main() {
  late Directory dir;
  late Host host;
  late FakeLayerEngine engine;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mapsengine');
    host = Host();
    engine = FakeLayerEngine(dirOverride: dir, fetcher: host.fetch, onlineProbe: () async => !host.offline);
    await engine.start();
  });
  tearDown(() {
    engine.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> get(String path) async {
    final c = HttpClient();
    try {
      return await (await c.getUrl(Uri.parse('http://127.0.0.1:${engine.port}$path'))).close();
    } finally {
      c.close();
    }
  }

  test('the tile server answers in the same address shape the real engine will', () async {
    expect(engine.tilesUrl('openfreemap'), 'http://127.0.0.1:${engine.port}/layers/openfreemap/{z}/{x}/{y}');
    final res = await get('/layers/openfreemap/5/6/11');
    expect(res.statusCode, 200);
    expect(res.headers.value('content-encoding'), 'gzip');
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    // The client unpacks the gzip the server declares.
    expect(bytes.length, 1000);
    // The versioned tile address came from the TileJSON.
    expect(host.calls.last.toString(), 'https://tiles.example/planet/v1/5/6/11.pbf');
    expect((await get('/layers/nope/0/0/0')).statusCode, 404);
    // A layer the fake cannot reach has no tiles (204), never an error page.
    expect((await get('/layers/contours/10/1/1')).statusCode, 204);
    final tj = jsonDecode(await (await get('/layers/openfreemap.json')).transform(utf8.decoder).join());
    expect(tj['attribution'], contains('OpenFreeMap'));
  });

  test('estimate shows tiles and size inside the source\'s limits, or says it is too big', () async {
    final e = await engine.estimate('openfreemap', home);
    expect(e.allowed, isTrue);
    expect(e.tiles, lessThanOrEqualTo(3000));
    expect(e.bytes, lessThanOrEqualTo(50 * 1024 * 1024));
    expect(e.maxZoom, greaterThan(8));
    const country = GeoBounds(south: 30, west: -125, north: 49, east: -100);
    final big = await engine.estimate('openfreemap', country);
    expect(big.allowed, isFalse);
    expect(big.problem, contains('too big'));
    final unavailable = await engine.estimate('contours', home);
    expect(unavailable.allowed, isFalse);
    final onlineOnly = await engine.estimate('satellite', home);
    expect(onlineOnly.allowed, isFalse);
    expect(onlineOnly.problem, contains('offline'));
  });

  test('download fetches every tile politely, then the area works with no connection', () async {
    final e = await engine.estimate('hillshade', home);
    final a = await engine.download('hillshade', home, label: 'This region');
    await until(() => a.phase == AreaPhase.done);
    expect(a.doneTiles, e.tiles);
    expect(a.bytes, e.tiles * 1000);
    expect(engine.storageOf('hillshade'), a.bytes);
    expect(engine.storageTotal, greaterThanOrEqualTo(a.bytes));
    expect(host.calls.length, e.tiles);
    // No connection now: the downloaded area still serves and still counts as covered.
    host.offline = true;
    await engine.refreshOnline(force: true);
    expect(engine.online, isFalse);
    expect(await engine.hasTiles('hillshade', home, 8), isTrue);
    expect((await get('/layers/hillshade/8/${TileMath.tileX(home.centerLon, 8)}/${TileMath.tileY(home.centerLat, 8)}')).statusCode, 200);
    // Somewhere else there is nothing, and the server says so without breaking.
    const elsewhere = GeoBounds(south: -34, west: 18, north: -33, east: 19);
    expect(await engine.hasTiles('hillshade', elsewhere, 8), isFalse);
    expect((await get('/layers/hillshade/8/1/1')).statusCode, 503);
  });

  test('cancel stops a first download and leaves nothing', () async {
    host.gate = Completer<void>();
    final a = await engine.download('hillshade', home, label: 'This region');
    await until(() => host.calls.isNotEmpty);
    unawaited(engine.cancel(a.id));
    host.gate!.complete();
    await until(() => engine.areasOf('hillshade').isEmpty);
    expect(engine.storageOf('hillshade'), 0);
  });

  test('delete removes the tiles; update fetches again and swaps in the new copy', () async {
    final a = await engine.download('hillshade', home, label: 'This region');
    await until(() => a.phase == AreaPhase.done);
    final first = a.fetchedAt!;
    final before = host.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await engine.update(a.id);
    await until(() => a.phase == AreaPhase.done && a.fetchedAt!.isAfter(first));
    expect(host.calls.length, before * 2);
    expect(a.bytes, before * 1000);
    await engine.delete(a.id);
    expect(engine.areasOf('hillshade'), isEmpty);
    expect(Directory('${dir.path}/areas/${a.id}').existsSync(), isFalse);
    expect(engine.storageOf('hillshade'), 0);
  });

  test('a lost connection stops the download with a plain message and keeps what it has', () async {
    final a = await engine.download('hillshade', home, label: 'This region');
    host.offline = true;
    await until(() => a.phase != AreaPhase.running);
    expect(a.phase, AreaPhase.failed);
    expect(a.error, contains('No connection'));
  });

  test('definitions can be added, edited and removed (Advanced) and survive a restart', () async {
    await engine.saveDefinition(jsonEncode({
      'id': 'mine',
      'title': 'My layer',
      'description': 'd',
      'licence': 'l',
      'attribution': 'a',
      'kind': 'raster',
      'source': {'url': 'https://example.com/{z}/{x}/{y}.png'},
    }));
    expect(engine.layer('mine')!.sourceUrl, contains('example.com'));
    await engine.saveDefinition(jsonEncode({...engine.layer('mine')!.toJson(), 'title': 'Mine'}));
    expect(engine.layer('mine')!.title, 'Mine');
    expect(() => engine.saveDefinition('{"id": "x"}'), throwsFormatException);
    expect(() => engine.saveDefinition('not json'), throwsFormatException);
    engine.dispose();
    engine = FakeLayerEngine(dirOverride: dir, fetcher: host.fetch);
    await engine.start();
    expect(engine.layer('mine')!.title, 'Mine');
    await engine.removeDefinition('mine');
    expect(engine.layer('mine'), isNull);
  });

  group('the offline notice', () {
    late MapsState maps;
    setUp(() async {
      maps = MapsState(engine: engine, settingsDirOverride: dir);
      // MapsState owns the engine it is given; keep the test's tearDown from disposing it twice.
      await maps.init();
    });

    test('says what is missing only when a visible layer has no tiles here and there is no connection', () async {
      maps.setOn('openfreemap', false);
      maps.setOn('hillshade', true);
      maps.setOn('contours', true);
      await maps.checkCoverage(home, 10);
      expect(maps.notice, isNull, reason: 'online: layers stream');

      host.offline = true;
      await engine.refreshOnline(force: true);
      await maps.checkCoverage(home, 10);
      expect(maps.notice, isNotNull);
      expect(maps.notice, contains('Contours'));
      expect(maps.notice, contains('need a connection or a download here'));
    });

    test('a layer that is downloaded here raises no notice; one that is off never does', () async {
      maps.setOn('openfreemap', false);
      maps.setOn('hillshade', true);
      final a = await engine.download('hillshade', home, label: 'This region');
      await until(() => a.phase == AreaPhase.done);
      host.offline = true;
      await engine.refreshOnline(force: true);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, isNull);
      maps.setOn('hillshade', false);
      maps.setOn('contours', false);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, isNull);
    });

    test('online-only layers say they need a connection, and several are listed together', () async {
      maps.setOn('openfreemap', false);
      maps.setOn('satellite', true);
      host.offline = true;
      await engine.refreshOnline(force: true);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, 'Satellite needs a connection here');
      maps.setOn('contours', true);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, 'Satellite and Contours need a connection or a download here');
    });

    test('the base map missing is said first', () async {
      host.offline = true;
      await engine.refreshOnline(force: true);
      maps.setOn('contours', true);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, 'Base map needs a connection or a download here');
    });

    test('choices are remembered; one base map at a time', () async {
      maps.setOn('hillshade', true);
      maps.setOpacity('hillshade', 0.4);
      maps.rememberCamera(42.5, -113.8, 11);
      await maps.flush();
      final again = MapsState(engine: FakeLayerEngine(dirOverride: dir, fetcher: host.fetch), settingsDirOverride: dir);
      await again.init();
      expect(again.isOn('hillshade'), isTrue);
      expect(again.opacityOf('hillshade'), 0.4);
      expect(again.savedCamera!.zoom, 11);
      expect(again.isOn('openfreemap'), isTrue);
      again.engine.dispose();
    });
  });
}

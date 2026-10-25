import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/fake_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/layers/pmtiles.dart';
import 'pmtiles_test.dart' show PmWriter;
import 'package:cache/maps/layers/tile_math.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/network_access.dart';
import 'package:flutter_test/flutter_test.dart';

const GeoBounds home = GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);

/// A pretend public host: the TileJSON for the base map and 1 KB for every other tile.
class Host {
  final List<Uri> calls = [];
  bool offline = false;
  Completer<void>? gate;

  Future<FetchedTile?> fetch(Uri u) async {
    if (offline) throw const SocketException('no route');
    if (u.path.endsWith('catalogue.json')) {
      return FetchedTile(File('test/fixtures/catalogue.json').readAsBytesSync());
    }
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

class _Net implements NetworkAccess {
  _Net({this.allowed = false, this.willAllow = false});
  bool allowed;
  bool willAllow;
  int asked = 0;
  @override
  Future<bool> request() async {
    asked++;
    return allowed = willAllow;
  }
}

void main() {
  late Directory dir;
  late Host host;
  late FakeLayerEngine engine;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mapsengine');
    host = Host();
    engine = FakeLayerEngine(
      dirOverride: dir,
      fetcher: host.fetch,
      rangeFetcher: (u, o, l) async => throw PmTilesMissing(u),
      onlineProbe: () async => !host.offline,
    );
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
      maps = MapsState(engine: engine, settingsDirOverride: dir, network: _Net(allowed: true));
      // MapsState owns the engine it is given; keep the test's tearDown from disposing it twice.
      await maps.init();
    });

    test('says what is missing only when a visible layer has no tiles here and there is no connection', () async {
      maps.setOn('basemap', false);
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
      maps.setOn('basemap', false);
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
      maps.setOn('basemap', false);
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
      final again = MapsState(
          engine: FakeLayerEngine(dirOverride: dir, fetcher: host.fetch), settingsDirOverride: dir, network: _Net(allowed: true));
      await again.init();
      expect(again.isOn('hillshade'), isTrue);
      expect(again.opacityOf('hillshade'), 0.4);
      expect(again.savedCamera!.zoom, 11);
      expect(again.isOn('basemap'), isTrue);
      expect(again.isOn('openfreemap'), isFalse);
      again.engine.dispose();
    });
  });

  group('catalogue cuts and definitions', () {
    late FakeLayerEngine live;
    late MapsState maps;
    setUp(() async {
      live = FakeLayerEngine(
        dirOverride: Directory('${dir.path}/live'),
        fetcher: host.fetch,
        rangeFetcher: (u, o, l) async => throw PmTilesMissing(u),
        catalogueUrl: Uri.parse('https://example.test/catalogue.json'),
      );
      maps = MapsState(engine: live, settingsDirOverride: Directory('${dir.path}/live'), network: _Net(allowed: true));
      await maps.init();
      await live.refreshCatalogue();
    });

    test('the published catalogue is fetched, kept, and merged with the bundled definitions', () async {
      expect(live.layer('mvum'), isNotNull);
      expect(live.layer('basemap'), isNotNull);
      expect(File('${dir.path}/live/catalogue.json').existsSync(), isTrue);
      // Next start, offline: the kept copy is used.
      live.dispose();
      host.offline = true;
      final again = FakeLayerEngine(dirOverride: Directory('${dir.path}/live'), fetcher: host.fetch, catalogueUrl: Uri.parse('https://example.test/catalogue.json'));
      await again.start();
      expect(again.layer('mvum'), isNotNull);
      again.dispose();
      live = FakeLayerEngine(dirOverride: Directory('${dir.path}/live2'));
    });

    test('the catalogue shows one card per layer; a download takes the most specific cut that covers the area', () {
      final cards = [for (final l in maps.catalogueLayers) l.id];
      expect(cards, containsAll(['basemap', 'blm-routes', 'mvum', 'usfs-trails-roads']));
      expect(cards, isNot(contains('blm-routes-idaho')));
      final card = live.layer('blm-routes')!;
      expect(maps.downloadDefFor(card, home).id, 'blm-routes-idaho');
      const colorado = GeoBounds(south: 39.0, west: -105.1, north: 39.2, east: -104.9);
      expect(maps.downloadDefFor(card, colorado).id, 'blm-routes');
      const acrossBorder = GeoBounds(south: 48.5, west: -119.0, north: 49.4, east: -117.0);
      expect(maps.downloadDefFor(card, acrossBorder).id, 'blm-routes');
      expect([for (final l in maps.groupOf(card)) l.id], ['blm-routes', 'blm-routes-idaho']);
      // Other layers are never switched.
      expect(maps.downloadDefFor(live.layer('hillshade')!, home).id, 'hillshade');
    });

    test('a cut that is downloaded serves the layer, and shows under the card', () async {
      final card = live.layer('blm-routes')!;
      final cut = maps.downloadDefFor(card, home);
      // PMTiles are read by byte ranges; give the fake host a tiny archive for the Idaho cut.
      final w = PmWriter(minZoom: 6, maxZoom: 14);
      for (final t in TileMath.tiles(home, 6, 9)) {
        w.add(t.$1, t.$2, t.$3, [1, 2, 3, 4]);
      }
      final file = w.build();
      final e = FakeLayerEngine(
        dirOverride: Directory('${dir.path}/cuts'),
        fetcher: host.fetch,
        rangeFetcher: (u, o, l) async => file.sublist(o, (o + l).clamp(0, file.length)),
        catalogueUrl: Uri.parse('https://example.test/catalogue.json'),
      );
      final m = MapsState(engine: e, settingsDirOverride: Directory('${dir.path}/cuts'), network: _Net(allowed: true));
      await m.init();
      await e.refreshCatalogue();
      final area = await e.download(cut.id, home, label: 'This region');
      await until(() => area.phase == AreaPhase.done);
      expect(area.doneTiles, greaterThan(0));
      expect(m.areasOfCard(card), [area]);
      expect(m.storageOfCard(card), greaterThan(0));
      // The map asks for the broad layer; the downloaded cut answers.
      host.offline = true;
      await e.refreshOnline(force: true);
      expect(await e.hasTiles('blm-routes', home, 8), isTrue);
      e.dispose();
    });

    test('a definition that is off by default stays in the catalogue and is switched on under Advanced', () async {
      expect(live.layer('openfreemap'), isNotNull);
      expect(maps.isDefinitionEnabled(live.layer('openfreemap')!), isFalse);
      expect([for (final l in maps.catalogueLayers) l.id], isNot(contains('openfreemap')));
      maps.setOn('openfreemap', true);
      expect(maps.isOn('openfreemap'), isFalse, reason: 'a definition that is off cannot be drawn');
      maps.setDefinitionEnabled('openfreemap', true);
      expect([for (final l in maps.catalogueLayers) l.id], contains('openfreemap'));
      maps.setOn('openfreemap', true);
      expect(maps.isOn('openfreemap'), isTrue);
      expect(maps.isOn('basemap'), isFalse, reason: 'one base map at a time');
      expect(maps.uses.where((u) => u.def.isBase).single.def.id, 'openfreemap');
      // Switching a definition off takes it off the map, and the choice is remembered.
      maps.setDefinitionEnabled('openfreemap', false);
      expect(maps.isOn('openfreemap'), isFalse);
      await maps.flush();
      final again = MapsState(engine: FakeLayerEngine(dirOverride: Directory('${dir.path}/live')), settingsDirOverride: Directory('${dir.path}/live'), network: _Net(allowed: true));
      await again.init();
      expect(again.isDefinitionEnabled(again.engine.layer('openfreemap')!), isFalse);
      again.engine.dispose();
    });
  });

  group('network access (Android can switch it off, and the tile server needs it)', () {
    test('without it the layers are not started and the screen is told why; allowing starts them', () async {
      final net = _Net(willAllow: true);
      final fresh = FakeLayerEngine(dirOverride: Directory('${dir.path}/net1'), fetcher: host.fetch, canBind: () => net.allowed);
      final m = MapsState(engine: fresh, settingsDirOverride: dir, network: net);
      await m.init();
      expect(m.needsNetworkAccess, isTrue);
      expect(fresh.ready, isFalse);
      expect(net.asked, 0, reason: 'never asks until the user taps Allow');
      await m.allowNetwork();
      expect(net.asked, 1);
      expect(m.needsNetworkAccess, isFalse);
      expect(fresh.ready, isTrue);
      expect(m.isOn('basemap'), isTrue);
      fresh.dispose();
    });

    test('a refusal is remembered, and allowing it later in settings starts the layers on return', () async {
      final net = _Net();
      final fresh = FakeLayerEngine(dirOverride: Directory('${dir.path}/net2'), fetcher: host.fetch, canBind: () => net.allowed);
      final m = MapsState(engine: fresh, settingsDirOverride: dir, network: net);
      await m.init();
      await m.allowNetwork();
      expect(m.networkRefused, isTrue);
      expect(fresh.ready, isFalse);
      net.allowed = true;
      await m.recheckNetwork();
      expect(fresh.ready, isTrue);
      expect(m.networkRefused, isFalse);
      fresh.dispose();
    });
  });


  test('a base map saved as on whose definition is now off falls back to the default base map', () async {
    File('${dir.path}/maps.json').writeAsStringSync(jsonEncode({'enabled': ['openfreemap', 'hillshade'], 'opacity': {}}));
    final m = MapsState(engine: engine, settingsDirOverride: dir, network: _Net(allowed: true));
    await m.init();
    expect(m.isOn('openfreemap'), isFalse);
    expect(m.isOn('basemap'), isTrue);
    expect(m.isOn('hillshade'), isTrue, reason: 'other choices are kept');
  });

  test('credits on the map are short; a long credit is cut after its first sentence', () {
    expect(shortAttribution('© OpenStreetMap contributors · Protomaps'), '© OpenStreetMap contributors · Protomaps');
    expect(
      shortAttribution('Source: Bureau of Land Management (BLM National GTLF public datasets). Data were clipped to the region.'),
      'Source: Bureau of Land Management (BLM National GTLF public datasets)',
    );
    expect(shortAttribution('x' * 200).length, 80);
  });

  group('the base map comes from the published catalogue', () {
    test('until the catalogue has a basemap entry the bundled fallback has no address and the map says so', () async {
      final m = MapsState(engine: engine, settingsDirOverride: dir, network: _Net(allowed: true));
      await m.init();
      final b = engine.layer('basemap')!;
      expect(b.isFallback, isTrue);
      expect(b.sourceUrl, isEmpty);
      expect(b.hasNoSource, isTrue);
      expect(m.isOn('basemap'), isTrue);
      expect(m.baseProblem, 'Base map not published yet');
      // A base map that is off (or another base map) raises nothing.
      m.setOn('basemap', false);
      expect(m.baseProblem, isNull);
    });

    test('when the published catalogue gains the entry, it replaces the fallback and the message goes', () async {
      final published = {
        'format': 1,
        'layers': [
          {
            'format': 1,
            'id': 'basemap',
            'title': 'Base map',
            'description': 'The planet.',
            'kind': 'basemap',
            'layout': 'protomaps-v4',
            'transform': 'as_is',
            'source': {'type': 'pmtiles', 'url': 'https://cache.echo6.co/basemap/planet.pmtiles', 'minzoom': 0, 'maxzoom': 15, 'tile_format': 'mvt'},
            'attribution': '© OpenStreetMap contributors · Protomaps',
            'license': 'ODbL',
            'coverage': {'bbox': [-180.0, -85.0, 180.0, 85.0]},
            'offline': {'allowed': true},
          },
        ],
      };
      final e = FakeLayerEngine(
        dirOverride: Directory('${dir.path}/pub'),
        fetcher: (u) async => u.path.endsWith('catalogue.json') ? FetchedTile(utf8.encode(jsonEncode(published))) : null,
        catalogueUrl: Uri.parse('https://example.test/catalogue.json'),
      );
      final m = MapsState(engine: e, settingsDirOverride: Directory('${dir.path}/pub'), network: _Net(allowed: true));
      await m.init();
      expect(m.baseProblem, 'Base map not published yet');
      await e.refreshCatalogue();
      final b = e.layer('basemap')!;
      expect(b.isFallback, isFalse);
      expect(b.sourceUrl, endsWith('planet.pmtiles'));
      expect(b.layout, 'protomaps-v4');
      expect(m.isOn('basemap'), isTrue, reason: 'it stays the one that is on');
      expect(m.baseProblem, isNull);
      // The bundled copy is not kept next to it.
      expect([for (final l in e.layers) if (l.id == 'basemap') l].length, 1);
      e.dispose();
    });
  });
}

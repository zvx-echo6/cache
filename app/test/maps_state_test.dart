import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/network_access.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_layer_engine.dart';

const GeoBounds home = GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);

List<Map<String, dynamic>> _published(String file) => TestLayerEngine.layersOf(File('test/fixtures/$file').readAsStringSync());

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
  late TestLayerEngine engine;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mapsstate');
    engine = TestLayerEngine(published: _published('catalogue.json'));
    await engine.start();
  });
  tearDown(() {
    engine.dispose();
    dir.deleteSync(recursive: true);
  });

  group('the offline notice', () {
    late MapsState maps;
    setUp(() async {
      maps = MapsState(engine: engine, settingsDirOverride: dir, network: _Net(allowed: true));
      await maps.init();
    });

    test('says what is missing only when a visible layer has no tiles here and there is no connection', () async {
      maps.setOn('basemap', false);
      maps.setOn('hillshade', true);
      maps.setOn('contours', true);
      await maps.checkCoverage(home, 10);
      expect(maps.notice, isNull, reason: 'online: layers stream');

      engine.online = false;
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
      engine.online = false;
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
      engine.online = false;
      await maps.checkCoverage(home, 8);
      expect(maps.notice, 'Satellite needs a connection here');
      maps.setOn('contours', true);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, 'Satellite and Contours need a connection or a download here');
    });

    test('the base map missing is said first', () async {
      engine.online = false;
      maps.setOn('contours', true);
      await maps.checkCoverage(home, 8);
      expect(maps.notice, 'Base map needs a connection or a download here');
    });

    test('choices are remembered; one base map at a time', () async {
      maps.setOn('hillshade', true);
      maps.setOpacity('hillshade', 0.4);
      maps.rememberCamera(42.5, -113.8, 11);
      await maps.flush();
      final again = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir, network: _Net(allowed: true));
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
    late MapsState maps;
    setUp(() async {
      maps = MapsState(engine: engine, settingsDirOverride: dir, network: _Net(allowed: true));
      await maps.init();
    });

    test('the catalogue shows one card per layer; a download takes the most specific cut that covers the area', () {
      final cards = [for (final l in maps.catalogueLayers) l.id];
      expect(cards, containsAll(['basemap', 'blm-routes', 'mvum', 'usfs-trails-roads']));
      expect(cards, isNot(contains('blm-routes-idaho')));
      final card = engine.layer('blm-routes')!;
      expect(maps.downloadDefFor(card, home).id, 'blm-routes-idaho');
      const colorado = GeoBounds(south: 39.0, west: -105.1, north: 39.2, east: -104.9);
      expect(maps.downloadDefFor(card, colorado).id, 'blm-routes');
      const acrossBorder = GeoBounds(south: 48.5, west: -119.0, north: 49.4, east: -117.0);
      expect(maps.downloadDefFor(card, acrossBorder).id, 'blm-routes');
      expect([for (final l in maps.groupOf(card)) l.id], ['blm-routes', 'blm-routes-idaho']);
      // Other layers are never switched.
      expect(maps.downloadDefFor(engine.layer('hillshade')!, home).id, 'hillshade');
    });

    test('a cut that is downloaded serves the layer, and shows under the card', () async {
      final card = engine.layer('blm-routes')!;
      final cut = maps.downloadDefFor(card, home);
      final area = await engine.download(cut.id, home, label: 'This region');
      await until(() => area.phase == AreaPhase.done);
      expect(area.doneTiles, greaterThan(0));
      expect(maps.areasOfCard(card), [area]);
      expect(maps.storageOfCard(card), greaterThan(0));
      // The map asks for the broad layer; the downloaded cut answers.
      engine.online = false;
      expect(await engine.hasTiles('blm-routes', home, 8), isTrue);
    });

    test('a definition that is off by default stays in the catalogue and is switched on under Advanced', () async {
      expect(engine.layer('openfreemap'), isNotNull);
      expect(maps.isDefinitionEnabled(engine.layer('openfreemap')!), isFalse);
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
      final again = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir, network: _Net(allowed: true));
      await again.init();
      expect(again.isDefinitionEnabled(again.engine.layer('openfreemap')!), isFalse);
      again.engine.dispose();
    });

    test('the elevation layer feeds hillshade and contours and is never listed as a card', () async {
      final e = TestLayerEngine(published: [
        {'format': 1, 'id': 'elevation', 'title': 'Elevation', 'kind': 'elevation', 'transform': 'as_is', 'source': {'type': 'tilejson', 'url': 'https://example.test/t.json'}},
      ]);
      final m = MapsState(engine: e, settingsDirOverride: dir, network: _Net(allowed: true));
      await m.init();
      expect(e.layer('elevation')!.kind, LayerKind.elevation);
      expect([for (final l in m.catalogueLayers) l.id], isNot(contains('elevation')));
      e.dispose();
    });
  });

  group('network access (Android can switch it off, and the tile server needs it)', () {
    test('without it the layers are not started and the screen is told why; allowing starts them', () async {
      final net = _Net(willAllow: true);
      final fresh = TestLayerEngine(canBind: () => net.allowed);
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
      final fresh = TestLayerEngine(canBind: () => net.allowed);
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

  group('the base map comes from the catalogue', () {
    test('with no base map definition on the map says so, and the message goes when one is switched on', () async {
      final m = MapsState(engine: engine, settingsDirOverride: dir, network: _Net(allowed: true));
      await m.init();
      expect(m.baseProblem, isNull);
      m.setDefinitionEnabled('basemap', false);
      expect(m.baseProblem, 'No base map yet. Connect once to get the catalogue.');
      m.setDefinitionEnabled('basemap', true);
      m.setOn('basemap', true);
      expect(m.baseProblem, isNull);
    });
  });

  group('the published base map entry', () {
    final entry = _published('catalogue_basemap.json').first;

    test('is read as the base map although the catalogue calls it a vector layer', () {
      final d = LayerDef.fromJson(Map<String, dynamic>.from(entry));
      expect(d.kind, LayerKind.basemap);
      expect(d.isBase, isTrue);
      expect(d.layout, 'protomaps-v4');
      expect(d.defaultOn, isTrue, reason: 'the base map is on the first time the map opens');
      expect(d.sourceUrl, endsWith('protomaps-planet-20261025.pmtiles'));
      expect(d.minZoom, 0);
      expect(d.maxZoom, 15);
      expect(d.styleRole, '', reason: 'a base map has no overlay colour family');
    });

    test('is the base map in use, credited with Protomaps', () async {
      final e = TestLayerEngine(published: _published('catalogue_basemap.json'));
      final m = MapsState(engine: e, settingsDirOverride: dir, network: _Net(allowed: true));
      await m.init();
      expect([for (final l in e.layers) if (l.isBase) l.id], contains('basemap'));
      expect(m.uses.where((u) => u.def.isBase).single.def.id, 'basemap');
      expect(m.uses.where((u) => !u.def.isBase), isEmpty, reason: 'it is not drawn as an overlay');
      expect(m.baseProblem, isNull);
      expect(m.attributions, ['(c) OpenStreetMap contributors · Protomaps']);
      expect([for (final l in m.catalogueLayers) l.id].where((id) => id == 'basemap').length, 1);
      e.dispose();
    });
  });
}

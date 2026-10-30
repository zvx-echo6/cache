import 'dart:convert';
import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/ui/format.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/search_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/search/core_config.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMap, MapLibrePlatform;

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';
import 'navigation_camera_test.dart' show NoSurface;
import 'support/regions_fake.dart';
import 'support/settings_rig.dart';

const _county = 'us-id-twin-falls-county';

/// The settings rig plus the regions part on fakes: the trimmed catalogue fixtures, the fake region engine and the test layer
/// engine. The catalogue is read once up front (it reads files, which a widget test does only inside runAsync).
class _Rig {
  late SettingsRig s;
  late FakeRegions core;
  late RegionCatalogue catalogue;
  late RegionsState regions;
  late RegionShard us;
  Map<String, Object?>? config;

  RegionRecord get county => us[_county]!;

  static Future<_Rig> boot(
    WidgetTester tester, {
    ConnectionKind connection = ConnectionKind.wifi,
    bool places = false,
    Future<void> Function()? onPlacesChanged,
  }) async {
    final r = _Rig();
    r.s = await SettingsRig.create(tester, connection: connection);
    r.core = FakeRegions(tileDir: '${r.s.dir.path}/regions/tiles/2026-10')..placesEnabled = places;
    Directory(r.core.tileDir).createSync(recursive: true);
    final web = regionWeb();
    r.catalogue = RegionCatalogue(dir: () async => Directory('${r.s.dir.path}/region-catalogue'), fetch: web.fetch);
    r.regions = RegionsState(
      policy: r.s.policy,
      supportDir: () async => r.s.dir,
      catalogue: r.catalogue,
      maps: r.s.maps,
      opener: (config) async {
        r.config = config;
        return r.core;
      },
      onPlacesChanged: onPlacesChanged,
    );
    await tester.runAsync(() async {
      await r.regions.init();
      await r.catalogue.index();
      r.us = await r.catalogue.shard('us');
      await r.catalogue.globalSearch();
      await r.catalogue.shardSearch('us');
      for (final id in ['us-id', 'us-ut', _county]) {
        await r.catalogue.geometry(r.us[id]!);
      }
    });
    return r;
  }

  /// Lets real file writes and the fake engines' timers finish, and draws the result. Real writes (the regions file) can take
  /// a few hundred milliseconds on a busy machine, so this waits up to about a second.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  }
}

Future<void> _openCountySheet(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('region-search')), 'twin falls county');
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('hit-$_county')));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the tree browses regions at every scale, and a region shows under each region it is in', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('United States'), findsOneWidget);

    await tester.tap(find.text('United States'));
    await tester.pumpAndSettle();
    expect(find.text('Download United States'), findsOneWidget);
    expect(find.text('SEVERAL STATES'), findsOneWidget);
    await tester.tap(find.text('Pacific Northwest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Idaho'));
    await tester.pumpAndSettle();
    expect(find.text('Download Idaho'), findsOneWidget);
    expect(find.text('Southern Idaho'), findsOneWidget);
    expect(find.text('PARTS OF THE STATE'), findsOneWidget);
    expect(find.text('METRO AREAS'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a region of the catalogue: one pop-up with its parts and its size from the catalogue, nothing worked out; Download starts them', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    r.core.calls.clear();
    await _openCountySheet(tester);
    await r.settle(tester);
    expect(r.core.calls, isNot(contains('plan')), reason: 'the size comes with the catalogue (1.0.27 worked it out for a minute)');
    final offer = r.regions.offer(r.county);
    expect(offer.kind, RegionOfferKind.download);
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    expect(find.text(formatBytes(offer.bytes!)), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing, reason: 'no per-part sheet');
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await tester.pump();
    expect(find.text('Downloading Twin Falls County'), findsOneWidget, reason: 'the tap says what it did');
    await r.settle(tester);
    expect(r.core.added.single['id'], _county);
    expect(r.core.added.single['geometry'], isA<Map<String, dynamic>>());
    expect(r.s.engine.areasOf('basemap').single.label, 'Twin Falls County');

    // A drawn area is the one region worked out on the phone; without a connection the core cannot plan it and says so.
    r.core.offline = true;
    final p = (await tester.runAsync(() => r.regions.plan(r.us['us-ut']!)))!;
    expect(p.routing, isNull);
    expect(p.routingProblem, 'Needs a connection to work out the size.');
    await r.dispose(tester);
  });

  testWidgets('a region downloads, shows its progress, is ready, points routing at the tile folder, and is removed', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.regions.download(r.county, routing: true, map: true));
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
    await tester.pump();
    expect(find.text('Twin Falls County'), findsOneWidget);
    // each part on its own line of state, not one percentage for the whole region
    // only the parts not ready yet, each with where it stands, and a bar that says what it is
    expect(find.textContaining(RegExp(r'^(Map \d+% · )?Directions \d+%$')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('local-bar-$_county')), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+% (of .+ )?in all · now (map|directions)$')), findsOneWidget);
    // with no position known, everything downloads from the region's centre outwards
    final b = r.county.bounds!;
    final centre = [(b.south + b.north) / 2, (b.west + b.east) / 2];
    expect(r.core.added.single['near'], centre);
    expect(r.s.engine.nearOf['Twin Falls County'], (lat: centre[0], lon: centre[1]));

    r.core.finish(_county);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await r.regions.refresh();
    });
    await tester.pump();
    expect(find.textContaining('Ready · '), findsOneWidget);
    expect(find.textContaining('next time Cache opens'), findsNothing, reason: 'the next route uses it, nothing waits for a restart');

    final saved = jsonDecode(File('${r.s.dir.path}/$kRegionsAppFile').readAsStringSync()) as Map;
    expect((saved['routing'] as Map)['tile_dir'], r.core.tileDir);
    expect((saved['routing'] as Map)['regions'], ['Twin Falls County']);
    final files = Directory('${r.s.dir.path}/files')..createSync();
    // The core is always given the router and the region engine; it routes on the engine's folder, so nothing changes here.
    final extras = buildCoreExtras(filesDir: files, supportDir: r.s.dir);
    expect(((extras['routing'] as Map)['valhalla'] as Map)['tiles'], '');
    expect((extras['regions'] as Map)['dir'], '${r.s.dir.path}/regions');

    // press and hold: the region's menu; Delete asks first
    await tester.longPress(find.byKey(const ValueKey('local-$_county')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('region-action-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Twin Falls County?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await r.settle(tester);
    expect(r.core.regions, isEmpty);
    expect(r.core.calls, contains('remove'));
    expect(r.s.engine.storageTotal, 0, reason: 'its map area is deleted too');
    expect(find.text('Nothing downloaded yet'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('on mobile data with downloads off it asks first, then pauses and goes on when allowed', (tester) async {
    final r = await _Rig.boot(tester, connection: ConnectionKind.mobile);
    expect(r.core.policies.last, {'network': false}, reason: 'the same rule as sharing: no mobile data unless downloads may use it');
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    await _openCountySheet(tester);
    await r.settle(tester);
    // The pop-up says so and offers Wait for Wi-Fi first.
    expect(find.byKey(const ValueKey('download-mobile')), findsOneWidget);
    expect(r.core.added, isEmpty, reason: 'nothing starts before the person says so');
    await tester.tap(find.byKey(const ValueKey('download-now')));
    await r.settle(tester);
    expect(r.core.added, hasLength(1));
    expect(r.core.regions[_county]!['state'], 'paused');

    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Paused: mobile data is switched off for downloads'), findsWidgets);

    r.s.settings.setMobileForDownloads(true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(r.core.policies.last, {'network': true});
    await tester.runAsync(r.regions.refresh);
    await tester.pump();
    expect(r.core.regions[_county]!['state'], 'downloading');
    expect(find.textContaining('Paused'), findsNothing);
    expect(find.textContaining('Directions'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('a region downloads from where the phone is; each part says where it stands', (tester) async {
    final rig = await SettingsRig.create(tester);
    final s = RegionsState(
      policy: rig.policy,
      supportDir: () async => rig.dir,
      catalogue: RegionCatalogue(dir: () async => rig.dir),
      maps: rig.maps,
      position: () => (lat: 42.56, lon: -114.46),
    );
    const county = RegionRecord(id: 'c', name: 'C', kind: 'county', bbox: [-115.0, 42.0, -114.0, 43.0]);
    expect(s.nearFor(county), (lat: 42.56, lon: -114.46));
    final l = LocalRegion(
      id: 'c',
      name: 'C',
      routing: {'state': 'downloading', 'bytes': 100, 'done_bytes': 40},
      places: {'state': 'ready', 'bytes': 10, 'done_bytes': 10},
      areas: [DownloadedArea(id: 'a', layerId: 'basemap', bounds: const GeoBounds(south: 42, west: -115, north: 43, east: -114), label: 'C', minZoom: 0, maxZoom: 14, totalTiles: 10, doneTiles: 10, phase: AreaPhase.done)],
      offroad: const [OffroadPackState(name: 'Idaho', bytes: 1000, doneBytes: 0, done: false)],
    );
    // the parts that are ready are not named: they work already
    expect(l.partsLine, 'Directions 40% · Off-road waiting');
    expect([for (final p in l.parts) '${p.name} ${p.words}'], ['Map ready', 'Directions 40%', 'Places ready', 'Off-road waiting']);
    s.dispose();
    await rig.dispose(tester);
  });

  testWidgets('Local lists what is on the phone, largest first', (tester) async {
    final r = await _Rig.boot(tester);
    r.core.sizes
      ..['us-id'] = 900 << 20
      ..['us-ut'] = 500 << 20
      ..[_county] = 120 << 20;
    await tester.runAsync(() async {
      for (final id in [_county, 'us-id', 'us-ut']) {
        await r.regions.download(r.us[id]!, routing: true, map: false);
        r.core.finish(id);
      }
      await r.regions.refresh();
    });
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
    await tester.pump();
    expect([for (final l in r.regions.local) l.id], ['us-id', 'us-ut', _county]);
    final y = [for (final id in ['us-id', 'us-ut', _county]) tester.getTopLeft(find.byKey(ValueKey('local-$id'))).dy];
    expect(y[0] < y[1] && y[1] < y[2], isTrue);
    expect(find.text('Ready · 900 MB'), findsOneWidget);
    expect(find.text('Tap a region to open it. Press and hold for Carry on, Check for update and Delete.'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Updates groups road routing and maps, and Update all updates both', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() async {
      await r.regions.download(r.county, routing: true, map: true);
      r.core.finish(_county);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await r.regions.refresh();
    });
    await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 2));
    await tester.pump();
    expect(find.text('ROAD ROUTING'), findsOneWidget);
    expect(find.text('MAP'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.byKey(const ValueKey('map-$_county')), findsOneWidget);

    r.core.update = {'build': '2026-11', 'download_bytes': 5 << 20};
    await tester.tap(find.text('Check for updates'));
    await r.settle(tester);
    expect(r.core.calls, contains('check_update'));
    expect(find.text('New road routing'), findsOneWidget);
    expect(find.text('2026-11 · About 5.0 MB to download'), findsOneWidget);

    // below the fold on the test's screen: scrolled to, as on a phone
    await tester.ensureVisible(find.byKey(const ValueKey('update-all')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('update-all')));
    await r.settle(tester);
    expect(r.core.calls, contains('update'));
    expect(r.core.build, '2026-11');
    expect(find.text('Up to date'), findsOneWidget);
    expect(r.s.engine.areasOf('basemap').single.phase.name, 'done', reason: 'the map was fetched again');
    await r.dispose(tester);
  });

  testWidgets('Settings > Maps and the layer sheet open the regions screen', (tester) async {
    final r = await _Rig.boot(tester);
    final hub = SettingsHub(
      settings: r.s.settings,
      policy: r.s.policy,
      webSearch: r.s.webSearch,
      storage: r.s.storage,
      weather: r.s.weather,
      regions: r.regions,
    );
    final deps = SettingsDeps(
      app: r.s.app,
      chat: r.s.chat,
      sources: r.s.sources,
      maps: r.s.maps,
      video: r.s.video,
      browse: r.s.browse,
      location: r.s.location,
      hub: hub,
    );
    await r.s.show(tester, MapsPage(deps: deps));
    expect(find.text('Download a region'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('regions-row')));
    await tester.pumpAndSettle();
    expect(find.text('Regions'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);

    // a fresh app: the Regions screen opened above is still on top of the old one's navigator
    await tester.pumpWidget(const SizedBox());
    await r.s.show(tester, Scaffold(body: LayerSheet(maps: r.s.maps, location: r.s.location, regions: r.regions)));
    expect(find.text('Get more layers'), findsOneWidget, reason: 'the layer catalogue stays for single layers and drawn areas');
    await tester.ensureVisible(find.byKey(const ValueKey('download-region')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('download-region')));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    await r.dispose(tester);
  });

  group('places and addresses', () {
    testWidgets('places are offered once they are published (the catalogue has their size), and downloaded first', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      expect(r.config?['places_base_url'], kPlacesBaseUrl, reason: 'the engine is told where places are published');
      // The published catalogue has no places sizes yet: no region is offered places (they could only fail).
      expect(r.regions.offer(r.county).places, isFalse);
      final c = r.county;
      final withPlaces = RegionRecord(id: c.id, name: c.name, kind: c.kind, bbox: c.bbox, country: c.country,
          sizes: RegionSizes(routing: c.sizes!.routing, places: 16 << 20, map: c.sizes!.map, offroadPacks: c.sizes!.offroadPacks, offroadTerrain: c.sizes!.offroadTerrain));
      final o = r.regions.offer(withPlaces);
      expect(o.places, isTrue);
      expect(o.bytes, r.regions.offer(c).bytes! + (16 << 20));
      await tester.runAsync(() => r.regions.download(withPlaces, routing: o.routing, map: false, places: o.places, anyway: true));
      expect(r.core.added.single['parts'], ['places', 'routing']);
      expect(r.regions.regionOf(_county)!.hasPlaces, isTrue);

      // Places that cannot be planned say why; road routing is still planned.
      r.core.placesOffline = true;
      final p = (await tester.runAsync(() => r.regions.plan(r.us['us-ut']!)))!;
      expect(p.routing, isNotNull);
      expect(p.places, isNull);
      expect(p.placesProblem, 'Needs a connection to work out the size.');
      // Places not published for the area: plain words, not the server's answer.
      r.core.placesOffline = false;
      r.core.placesMissing = true;
      final q = (await tester.runAsync(() => r.regions.plan(r.us['us-ut']!)))!;
      expect(q.placesProblem, "Places for this area aren't available yet.");
      await r.dispose(tester);
    });

    test('download problems from the core are said in plain words', () {
      expect(regionPartWords(RegionPart.places, 'fetch_failed', 'HTTP 404 from https://data.cached.info/places/current.json'),
          "Places for this area aren't available yet.");
      expect(regionPartWords(RegionPart.routing, 'fetch_failed', 'HTTP 404 from https://x/routing.tar'), "Road routing for this area isn't available yet.");
      expect(regionPartWords(RegionPart.routing, 'fetch_failed', 'HTTP 503 from https://x/a'), "The download server couldn't send it just now. Try again later.");
      expect(regionPartWords(RegionPart.places, 'internal', 'checksum mismatch for https://x/a'), "Couldn't be downloaded. Try again later.");
      expect(regionPartWords(RegionPart.places, 'offline', 'the places server cannot be reached'), 'Needs a connection.');
      final s = LocalRegion(id: 'r', name: 'R', places: {'state': 'failed', 'error': 'HTTP 404 from https://data.cached.info/places/x.pack'});
      expect(s.error, "Places for this area aren't available yet.");
    });

    testWidgets('Local names the parts; a region from before places offers them, and Update adds only that part', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.us['us-id']!, routing: true, map: false, places: true);
        await r.regions.download(r.county, routing: true, map: true);
        r.core.finish('us-id');
        r.core.finish(_county);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await r.regions.refresh();
      });
      await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 1));
      await tester.pump();
      expect(find.text('Ready · ${formatBytes(140 << 20)}'), findsOneWidget);
      expect(r.regions.missesPlaces(r.regions.regionOf(_county)!), isTrue);
      expect(r.core.added.last['parts'], ['routing']);

      await tester.longPress(find.byKey(const ValueKey('local-$_county')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('region-action-update')));
      await r.settle(tester);
      expect(r.core.added.last['id'], _county);
      expect(r.core.added.last['parts'], ['places'], reason: 'only the missing part');
      r.core.finish(_county);
      await tester.runAsync(r.regions.refresh);
      await tester.pump();
      expect(r.regions.regionOf(_county)!.hasPlaces, isTrue);
      expect(r.regions.missesPlaces(r.regions.regionOf(_county)!), isFalse);

      await tester.longPress(find.byKey(const ValueKey('local-$_county')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('region-action-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Its map, directions, places and off-road data are removed from this phone. Parts another region uses stay.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await r.dispose(tester);
    });

    testWidgets('a places part that fails fails the region, with its reason', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.county, routing: true, map: false, places: true);
        r.core.finish(_county, part: 'routing');
        final p = (r.core.regions[_county]!['parts'] as Map)['places'] as Map;
        p
          ..['state'] = 'failed'
          ..['error'] = 'A places tile did not match its check';
        r.core.regions[_county]!['state'] = 'failed';
        await r.regions.refresh();
      });
      expect(r.regions.regionOf(_county)!.phase, RegionPhase.failed);
      expect(r.regions.regionOf(_county)!.error, 'A places tile did not match its check');
      await r.dispose(tester);
    });

    testWidgets('Updates has a Places group: a new build, Update all starts it', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      await tester.runAsync(() async {
        await r.regions.download(r.county, routing: true, map: false, places: true);
        r.core.finish(_county);
        await r.regions.refresh();
      });
      await r.s.show(tester, RegionsScreen(regions: r.regions, initialTab: 2));
      await tester.pump();
      expect(find.text('PLACES'), findsOneWidget);
      expect(find.text('Up to date'), findsNWidgets(2));

      r.core.placesUpdate = {'build': 'na-places-2026-12-15', 'download_bytes': 23 << 20, 'downloading': false};
      await tester.tap(find.text('Check for updates'));
      await r.settle(tester);
      expect(find.text('New places'), findsOneWidget);
      expect(find.text('na-places-2026-12-15 · About 23 MB to download'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('update-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('update-all')));
      await r.settle(tester);
      expect(r.core.calls.where((c) => c == 'update'), hasLength(1), reason: 'only places had a new build');
      expect(find.text('Downloading na-places-2026-12-15'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('when the places on the phone change, the callback runs once per change', (tester) async {
      var changed = 0;
      final r = await _Rig.boot(tester, places: true, onPlacesChanged: () async => changed++);
      expect(changed, 0, reason: 'the first status only sets where it starts');
      await tester.runAsync(() async {
        await r.regions.download(r.county, routing: false, map: false, places: true);
        await r.regions.refresh();
      });
      expect(changed, 0);
      r.core.finish(_county);
      await tester.runAsync(r.regions.refresh);
      expect(changed, 1);
      await tester.runAsync(r.regions.refresh);
      expect(changed, 1);
      await tester.runAsync(() => r.regions.remove(_county));
      expect(changed, 2);
      await r.dispose(tester);
    });

    testWidgets('the map search with no places offers a region, and Get a region opens Downloads', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      final backend = FakeBackend()
        ..onSearch = (q, {near, meaning}) async => MapSearchResponse(
              query: q,
              kind: 'text',
              meaning: 'off',
              results: const [],
              warningCode: 'no_places',
              places: const PlacesCoverage(installed: false, covers: false),
            );
      final nav = NavState(
        backend: backend,
        location: r.s.location,
        speaker: FakeSpeaker(),
        positionSource: FakeNavPosition(),
        fmt: const Fmt(UnitSystem.imperial),
        searchDebounce: const Duration(milliseconds: 1),
        meaningDebounce: const Duration(milliseconds: 2),
      );
      await r.s.show(tester, Scaffold(body: SafeArea(child: NavSearchBar(nav: nav, fmt: nav.fmt, regions: r.regions))));
      await tester.enterText(find.byKey(const ValueKey('map-search-field')), 'pharmacy');
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(find.text('No places on this phone.'), findsOneWidget);
      expect(find.text('Download a region to search places and addresses.'), findsOneWidget);
      expect(find.text('Nothing found for "pharmacy"'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('get-region')));
      await tester.pumpAndSettle();
      expect(find.text('Regions'), findsOneWidget);
      expect(find.byKey(const ValueKey('region-search')), findsOneWidget, reason: 'the Downloads tab');
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      await r.dispose(tester);
    });
  });

  testWidgets('the Regions sheet: the regions at a place with their sizes; Select ticks several and one Download goes through the pop-up', (tester) async {
    final r = await _Rig.boot(tester);
    final b = r.county.bounds!;
    await r.s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(
      onPressed: () => showRegionsSheet(c, r.regions, lat: (b.south + b.north) / 2, lon: (b.west + b.east) / 2),
      child: const Text('open'),
    ))));
    await tester.tap(find.text('open'));
    await r.settle(tester);
    expect(find.text('Regions'), findsOneWidget);
    expect(find.text('Each region has directions, map, places and off-road.'), findsOneWidget);
    expect(find.textContaining('County · ${formatBytes(r.regions.offer(r.county).bytes!)}'), findsOneWidget, reason: 'sizes at once');
    expect(find.text('Twin Falls County'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing, reason: 'no tick boxes until Select');
    expect(find.byTooltip('Download Twin Falls County'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('regions-select')));
    await tester.pump();
    expect(find.byType(Checkbox), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('region-$_county')));
    await tester.pump();
    expect(find.textContaining('Download 1 ·'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('regions-download-picked')));
    await r.settle(tester);
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await r.settle(tester);
    expect(r.core.added.single['id'], _county);
    await r.dispose(tester);
  });

  testWidgets('Draw your own area instead: the map draws, then the drawn area downloads as a region through the same sheet', (tester) async {
    final r = await _Rig.boot(tester);
    await tester.runAsync(() => r.catalogue.readShardAt(42.55, -114.4));
    await r.s.show(tester, Builder(builder: (c) => TextButton(onPressed: () => showRegionsSheet(c, r.regions, lat: 42.55, lon: -114.4), child: const Text('open'))));
    await tester.tap(find.text('open'));
    await r.settle(tester);
    await tester.tap(find.byKey(const ValueKey('regions-draw')));
    await r.settle(tester);
    expect(r.s.maps.drawRequest, isTrue, reason: 'the map is asked to draw');
    // what the map does with the rectangle: a region record of it, downloaded like any other
    final drawn = RegionRecord.drawn(const GeoBounds(south: 42.5, west: -114.5, north: 42.6, east: -114.3), at: DateTime(2026, 10, 30));
    expect((drawn.name, regionKindLabel(drawn.kind)), ('Drawn area', 'Drawn on the map'));
    final g = (await tester.runAsync(() => r.catalogue.geometry(drawn)))!;
    expect(g, {
      'type': 'Polygon',
      'coordinates': [
        [[-114.5, 42.5], [-114.3, 42.5], [-114.3, 42.6], [-114.5, 42.6], [-114.5, 42.5]],
      ],
    });
    await tester.runAsync(() => r.regions.download(drawn, routing: true, map: true, anyway: true));
    await r.settle(tester);
    expect(r.core.added.single['geometry'], g);
    expect(r.s.engine.areasOf('basemap').single.label, 'Drawn area');
    await r.dispose(tester);
  });

  testWidgets('Draw your own area from Home: the map, built only now, opens drawing; the drawn area goes to the same sheet', (tester) async {
    final r = await _Rig.boot(tester);
    final before = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    addTearDown(() => MapLibrePlatform.createInstance = before);
    final location = LocationService(source: FakeSource(), settingsDirOverride: r.s.dir);
    final nav = NavState(
      backend: FakeBackend(),
      location: location,
      speaker: FakeSpeaker(),
      positionSource: FakeNavPosition(),
      fmt: const Fmt(UnitSystem.imperial),
    );
    await tester.runAsync(() => r.catalogue.readShardAt(42.55, -114.4));
    // Home's "Get your area": the Regions sheet over Home, with no map on screen yet.
    await r.s.show(tester, Builder(builder: (c) => TextButton(onPressed: () => showRegionsSheet(c, r.regions, lat: 42.55, lon: -114.4), child: const Text('open'))));
    await tester.tap(find.text('open'));
    await r.settle(tester);
    await tester.tap(find.byKey(const ValueKey('regions-draw')));
    await r.settle(tester);
    expect(find.text('Draw your own area instead'), findsNothing, reason: 'the sheet closed');
    // The shell opens the Maps tab for the request; the map screen is built then, after the request was made.
    await r.s.show(tester, MapsScreen(
      location: location,
      maps: r.s.maps,
      nav: nav,
      themeId: CacheThemeId.dark,
      regions: r.regions,
      glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
    ));
    for (var i = 0; i < 100 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('Drag on the map to draw the area to download'), findsOneWidget, reason: 'the request was not lost');
    expect(r.s.maps.drawRequest, isFalse, reason: 'taken once');
    expect(find.text('Use this area'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    await r.dispose(tester);
  });

  testWidgets('the search field does not take the focus back when the region sheet closes', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    await _openCountySheet(tester);
    await r.settle(tester);
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download Twin Falls County?'), findsNothing);
    final field = tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('region-search')), matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse, reason: 'no keyboard');
    await r.dispose(tester);
  });
}

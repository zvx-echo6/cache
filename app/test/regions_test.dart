import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/ui/format.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/search_panel.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/search/core_config.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/hub.dart';
import 'package:flutter/material.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
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

  testWidgets('the size before downloading counts only what is new; parts can be picked; Download starts them', (tester) async {
    final r = await _Rig.boot(tester);
    final est = (await tester.runAsync(() => r.s.engine.estimate('basemap', r.county.bounds!)))!;
    expect(est.allowed, isTrue);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    await _openCountySheet(tester);

    expect(find.text('Download Twin Falls County'), findsOneWidget);
    expect(find.text('Road routing'), findsOneWidget);
    expect(find.text('About 80 MB · 40 MB already on this phone'), findsOneWidget, reason: 'only the routing tiles not on the phone are counted');
    expect(find.text('About ${formatBytes(est.bytes)} · Base map · detail down to zoom ${est.maxZoom}'), findsOneWidget);
    expect(find.text('About ${formatBytes((80 << 20) + est.bytes)} to download'), findsOneWidget);
    // The size in all counts what Local will count: the routing tiles already on the phone too.
    final already = (40 << 20) + est.bytesAlready;
    expect(find.text('About ${formatBytes((80 << 20) + est.bytes + already)} on this phone in all, ${formatBytes(already)} of it already here'), findsOneWidget);
    expect(r.core.calls, contains('plan'));

    // Untick the map: only road routing is counted and downloaded.
    await tester.tap(find.byKey(const ValueKey('part-map')));
    await tester.pump();
    expect(find.text('About 80 MB to download'), findsOneWidget);
    expect(find.text('About 120 MB on this phone in all, 40 MB of it already here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('part-map')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('region-download')));
    await r.settle(tester);
    // The one download pop-up: the region and its size.
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await r.settle(tester);
    expect(r.core.added.single['id'], _county);
    expect(r.core.added.single['geometry'], isA<Map<String, dynamic>>());
    expect(r.s.engine.areasOf('basemap').single.label, 'Twin Falls County');
    expect(find.text('Download Twin Falls County'), findsNothing, reason: 'the sheet closes once the download starts');

    // Without a connection the core cannot plan; the sheet says so instead of a size.
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
    expect(find.textContaining('Downloading'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    r.core.finish(_county);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await r.regions.refresh();
    });
    await tester.pump();
    expect(find.textContaining('Road routing and map'), findsOneWidget);
    expect(find.textContaining('next time Cache opens'), findsNothing, reason: 'the next route uses it, nothing waits for a restart');

    final saved = jsonDecode(File('${r.s.dir.path}/$kRegionsAppFile').readAsStringSync()) as Map;
    expect((saved['routing'] as Map)['tile_dir'], r.core.tileDir);
    expect((saved['routing'] as Map)['regions'], ['Twin Falls County']);
    final files = Directory('${r.s.dir.path}/files')..createSync();
    // The core is always given the router and the region engine; it routes on the engine's folder, so nothing changes here.
    final extras = buildCoreExtras(filesDir: files, supportDir: r.s.dir);
    expect(((extras['routing'] as Map)['valhalla'] as Map)['tiles'], '');
    expect((extras['regions'] as Map)['dir'], '${r.s.dir.path}/regions');

    await tester.tap(find.byTooltip('Delete Twin Falls County'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Twin Falls County?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
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

    await tester.tap(find.byKey(const ValueKey('region-download')));
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
    expect(find.textContaining('Downloading'), findsOneWidget);
    await r.dispose(tester);
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
    expect(find.text('900 MB · Road routing'), findsOneWidget);
    expect(find.text('Largest first. A part two regions share is kept once.'), findsOneWidget);
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
    expect(find.text('Road routing and map for a region'), findsOneWidget);
    await tester.tap(find.text('Nothing downloaded'));
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
    testWidgets('the sheet has a third part with its own size, counted in the total; Download asks for every part picked', (tester) async {
      final r = await _Rig.boot(tester, places: true);
      expect(r.config?['places_base_url'], kPlacesBaseUrl, reason: 'the engine is told where places are published');
      final est = (await tester.runAsync(() => r.s.engine.estimate('basemap', r.county.bounds!)))!;
      await r.s.show(tester, RegionsScreen(regions: r.regions));
      await _openCountySheet(tester);

      expect(find.byKey(const ValueKey('part-routing')), findsOneWidget);
      expect(find.byKey(const ValueKey('part-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('part-places')), findsOneWidget);
      expect(find.text('Places and addresses'), findsOneWidget);
      expect(find.text('About 16 MB · 4.0 MB already on this phone'), findsOneWidget);
      expect(find.text('About ${formatBytes((80 << 20) + est.bytes + (16 << 20))} to download'), findsOneWidget);
      final y = [for (final k in ['part-routing', 'part-map', 'part-places']) tester.getTopLeft(find.byKey(ValueKey(k))).dy];
      expect(y[0] < y[1] && y[1] < y[2], isTrue, reason: 'under the two parts there were');

      await tester.tap(find.byKey(const ValueKey('part-places')));
      await tester.pump();
      expect(find.text('About ${formatBytes((80 << 20) + est.bytes)} to download'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('part-places')));
      await tester.tap(find.byKey(const ValueKey('part-routing')));
      await tester.pump();
      expect(find.text('About ${formatBytes(est.bytes + (16 << 20))} to download'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('part-routing')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('region-download')));
      await r.settle(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-download')));
      await r.settle(tester);
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
      expect(find.text('${formatBytes(140 << 20)} · Road routing and places'), findsOneWidget);
      expect(find.textContaining('Road routing and map · Places not downloaded'), findsOneWidget);
      expect(r.core.added.last['parts'], ['routing']);

      await tester.tap(find.byTooltip('Update Twin Falls County'));
      await r.settle(tester);
      expect(r.core.added.last['id'], _county);
      expect(r.core.added.last['parts'], ['places'], reason: 'only the missing part');
      r.core.finish(_county);
      await tester.runAsync(r.regions.refresh);
      await tester.pump();
      expect(find.textContaining('Road routing, map and places'), findsOneWidget);
      expect(find.textContaining('Places not downloaded'), findsNothing);

      await tester.tap(find.byTooltip('Delete Twin Falls County'));
      await tester.pumpAndSettle();
      expect(find.text('Its road routing, map and places are removed from this phone. Parts another region uses stay.'), findsOneWidget);
      await tester.tap(find.text('Keep'));
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
    expect(find.text('Each region has routing, map and places.'), findsOneWidget);
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

  testWidgets('the search field does not take the focus back when the region sheet closes', (tester) async {
    final r = await _Rig.boot(tester);
    await r.s.show(tester, RegionsScreen(regions: r.regions));
    await _openCountySheet(tester);
    expect(find.text('Download Twin Falls County'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download Twin Falls County'), findsNothing);
    final field = tester.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('region-search')), matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse, reason: 'no keyboard');
    await r.dispose(tester);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/ui/format.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/search/core_config.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/hub.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  RegionRecord get county => us[_county]!;

  static Future<_Rig> boot(WidgetTester tester, {ConnectionKind connection = ConnectionKind.wifi}) async {
    final r = _Rig();
    r.s = await SettingsRig.create(tester, connection: connection);
    r.core = FakeRegions(tileDir: '${r.s.dir.path}/regions/tiles/2026-10');
    Directory(r.core.tileDir).createSync(recursive: true);
    final web = regionWeb();
    r.catalogue = RegionCatalogue(dir: () async => Directory('${r.s.dir.path}/region-catalogue'), fetch: web.fetch);
    r.regions = RegionsState(
      policy: r.s.policy,
      supportDir: () async => r.s.dir,
      catalogue: r.catalogue,
      maps: r.s.maps,
      opener: (_) async => r.core,
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

  /// Lets real file writes and the fake engines' timers finish, and draws the result.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
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
    expect(r.core.calls, contains('plan'));

    // Untick the map: only road routing is counted and downloaded.
    await tester.tap(find.byKey(const ValueKey('part-map')));
    await tester.pump();
    expect(find.text('About 80 MB to download'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('part-map')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('region-download')));
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
    expect(find.text(const MobileDataBlocked().message), findsOneWidget);
    expect(r.core.added, isEmpty, reason: 'nothing starts before the person says so');
    await tester.tap(find.byKey(const ValueKey('download-anyway')));
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

    final before = r.routingChanges;
    await tester.tap(find.byKey(const ValueKey('update-all')));
    await r.settle(tester);
    expect(r.core.calls, contains('update'));
    expect(r.core.build, '2026-11');
    expect(find.text('Up to date'), findsOneWidget);
    expect(r.s.engine.areasOf('basemap').single.phase.name, 'done', reason: 'the map was fetched again');
    expect(r.routingChanges, before + 1, reason: 'a new build changes the tile folder the core uses');
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
      locationAccess: r.s.access,
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

    await r.s.show(tester, Scaffold(body: LayerSheet(maps: r.s.maps, location: r.s.location, regions: r.regions)));
    expect(find.text('Get more layers'), findsOneWidget, reason: 'the layer catalogue stays for single layers and drawn areas');
    await tester.tap(find.byKey(const ValueKey('download-region')));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    await r.dispose(tester);
  });
}

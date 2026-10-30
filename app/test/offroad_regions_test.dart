import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/zim_download.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/maps/ui/format.dart';
import 'package:cache/regions/offroad_catalogue.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/region_actions.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';
import 'support/settings_rig.dart';
import 'support/weather_fakes.dart';

const _county = 'us-id-twin-falls-county';

Map<String, dynamic> _pack(String id, String name, List<double> bbox, int bytes) => {
      'id': id,
      'name': name,
      'country': 'US',
      'bbox': bbox,
      'build': 'offroad-2026-10',
      'land_access': 'us',
      'bytes': bytes + 100,
      'files': {
        'offroad.sqlite': {
          'path': 'offroad-2026-10/$id/offroad.sqlite',
          'url': '${kOffroadBaseUrl}offroad-2026-10/$id/offroad.sqlite',
          'bytes': bytes,
          'sha256': 'AB' * 32,
        },
      },
    };

String _catalogue(List<Map<String, dynamic>> packs) => jsonEncode({
      'format': 1,
      'component': 'offroad',
      'base_url': kOffroadBaseUrl,
      'elevation': {'minzoom': 12, 'maxzoom': 12},
      'regions': packs,
    });

final _idaho = _pack('idaho', 'Idaho', [-118.0, 41.5, -110.3, 49.5], 300 << 20);
final _utah = _pack('utah', 'Utah', [-114.8, 36.5, -108.3, 42.5], 200 << 20);
final _nevada = _pack('nevada', 'Nevada', [-120.7, 34.5, -113.3, 42.5], 250 << 20);

/// The download of a pack: the bytes written to the hidden file, its URL and checksum noted.
class _Packs extends ZimDownloader {
  final List<(Uri, String?)> fetched = [];

  @override
  Future<DownloadResult> download({
    required Uri url,
    required File part,
    Uri? sha256Url,
    Uri? md5Url,
    String? expectedSha256,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) async {
    fetched.add((url, expectedSha256));
    await part.writeAsBytes(utf8.encode('pack'));
    return DownloadResult(file: part, bytes: 4, verified: true, checksumKind: 'sha256');
  }
}

void main() {
  group('the catalogue and the packs a region needs', () {
    final packs = parseOffroadCatalogue(_catalogue([_idaho, _utah, _nevada, {'id': 'broken'}]));

    test('entries that cannot be read are left out', () {
      expect(packs.map((p) => p.id), ['idaho', 'utah', 'nevada']);
      expect(packs.first.sha256, 'ab' * 32);
      expect(packs.first.relativePath(), 'offroad-2026-10/idaho/offroad.sqlite');
      expect(() => parseOffroadCatalogue('{"component":"routing"}'), throwsFormatException);
    });

    test('the smallest pack that holds the region; across a border, every pack it meets; none near, none', () {
      List<String> ids(GeoBounds b) => [for (final p in packsCovering(packs, b)) p.id];
      // Twin Falls County: inside Idaho's box, and inside Nevada's and Utah's (their boxes reach 42.5): the smallest holds it
      expect(ids(const GeoBounds(south: 41.99, west: -115.04, north: 42.92, east: -114.0)), ['idaho']);
      // Utah and Nevada both hold this box; Utah's is smaller
      expect(ids(const GeoBounds(south: 40.0, west: -114.0, north: 41.0, east: -113.5)), ['utah']);
      // the Pacific Northwest: no pack holds it, so the packs it meets
      expect(ids(const GeoBounds(south: 42.0, west: -125.0, north: 49.0, east: -111.0)), ['idaho', 'utah', 'nevada']);
      expect(ids(const GeoBounds(south: 25.0, west: -82.0, north: 31.0, east: -80.0)), isEmpty);
    });
  });

  testWidgets('a region download includes its off-road pack (checked) and terrain heights; the row is there only when a pack covers it', (tester) async {
    final s = await SettingsRig.create(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    final web = regionWeb();
    final offroadWeb = FakeWeb()..files['${kOffroadBaseUrl}current.json'] = utf8.encode(_catalogue([_idaho, _utah]));
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: web.fetch);
    final packs = _Packs();
    final regions = RegionsState(
      policy: s.policy,
      supportDir: () async => s.dir,
      catalogue: catalogue,
      maps: s.maps,
      opener: (_) async => core,
      offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: offroadWeb.fetch),
      packDownloader: packs,
    );
    late RegionRecord county;
    await tester.runAsync(() async {
      await s.engine.saveDefinition(File('../packages/cache_search/layers/mapterhorn.json').readAsStringSync());
      await regions.init();
      final us = await catalogue.shard('us');
      county = us[_county]!;
      await catalogue.geometry(county);
    });
    final idaho = parseOffroadCatalogue(_catalogue([_idaho])).single;
    // The terrain heights are the region's own (where the pack covers it), not the whole state's.
    final countyBox = terrainBox(county.bounds!, idaho.bounds);
    final terrain = (await tester.runAsync(() => s.engine.estimate(kOffroadElevationLayer, countyBox, zoom: 12)))!;
    final wholeState = (await tester.runAsync(() => s.engine.estimate(kOffroadElevationLayer, idaho.bounds, zoom: 12)))!;
    expect(terrain.bytes, lessThan(wholeState.bytes));
    final plan = (await tester.runAsync(() => regions.plan(county)))!;
    expect(plan.offroad!.packs.map((p) => p.pack.id), ['idaho']);
    expect(plan.offroad!.packsOnPhone, isFalse);
    expect(plan.offroad!.downloadBytes, (300 << 20) + terrain.bytes, reason: 'the pack and the county\'s z12 terrain heights');

    await s.show(tester, RegionsScreen(regions: regions));
    await tester.runAsync(() async {
      await tester.enterText(find.byKey(const ValueKey('region-search')), 'twin falls county');
    });
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byKey(const ValueKey('hit-$_county')));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // One pop-up: the parts, with off-road among them, and the size from the catalogue (nothing worked out on the phone).
    expect(find.text('Download Twin Falls County?'), findsOneWidget);
    expect(find.textContaining('off-road'), findsOneWidget);
    final offer = regions.offer(county);
    expect(offer.offroad, isTrue);
    expect(offer.bytes, isNotNull);
    expect(find.text(formatBytes(offer.bytes!)), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pump();

    await tester.runAsync(() async {
      await regions.download(county, routing: true, map: false, offroad: true, anyway: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    // the pack: the published address and checksum, renamed into the folder the router reads once complete
    expect(packs.fetched.single, (Uri.parse('${kOffroadBaseUrl}offroad-2026-10/idaho/offroad.sqlite'), 'ab' * 32));
    final file = File('${s.dir.path}/regions/offroad/offroad-2026-10/idaho/offroad.sqlite');
    expect(file.existsSync(), isTrue);
    expect(File('${file.parent.path}/.offroad.sqlite.part').existsSync(), isFalse);
    // the terrain heights: z12 only, over the county
    final area = s.engine.areasOf(kOffroadElevationLayer).single;
    expect((area.label, area.minZoom, area.maxZoom), ('Off-road terrain for Twin Falls County', 12, 12));
    expect([area.bounds.west, area.bounds.south, area.bounds.east, area.bounds.north], [countyBox.west, countyBox.south, countyBox.east, countyBox.north]);
    final l = regions.regionOf(_county)!;
    expect(l.hasOffroad, isTrue);
    expect(partsWords(l), 'Road routing and off-road');

    // a second region in the same pack shares the pack and the terrain heights
    final idahoState = (await tester.runAsync(() async {
      final us = await catalogue.shard('us');
      await catalogue.geometry(us['us-id']!);
      return us['us-id']!;
    }))!;
    // a second region in the pack: the pack adds nothing ("Already on this phone"), only its own terrain heights are new
    final second = (await tester.runAsync(() => regions.plan(idahoState)))!;
    expect(second.offroad!.packsOnPhone, isTrue);
    expect(second.offroad!.downloadBytes, second.offroad!.packs.single.elevation.bytes, reason: 'no pack bytes');
    // the catalogue's off-road size for it leaves the pack out, and the download pop-up says so
    final cost = regions.costOf(idahoState);
    expect(cost.offroadShared, isTrue);
    expect(cost.offroad, idahoState.sizes!.offroadTerrain, reason: 'only its terrain heights');
    await tester.pumpWidget(const SizedBox()); // a fresh app: the pop-up opened above is not under this one
    await s.show(tester, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openRegionOffer(c, regions, idahoState), child: const Text('open')))));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('already on this phone')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pump();
    await tester.runAsync(() => regions.download(idahoState, routing: false, map: false, offroad: true, anyway: true));
    expect(packs.fetched, hasLength(1), reason: 'the pack is downloaded once');
    expect(s.engine.areasOf(kOffroadElevationLayer), hasLength(2), reason: 'each region its own terrain heights');
    // Storage > Regions lists the pack once, with the regions that use it
    expect(regions.offroadPacks.map((p) => p.name), ['Idaho']);
    expect(regions.offroadPacks.single.usedBy, unorderedEquals(['Twin Falls County', 'Idaho']));
    await tester.pumpWidget(const SizedBox());
    await s.show(tester, Scaffold(body: LocalTab(regions: regions)));
    await tester.pump();
    expect(find.text('OFF-ROAD DATA'), findsOneWidget, reason: 'the group, under the regions');
    expect(find.descendant(of: find.byKey(const ValueKey('offroad-pack-Idaho')), matching: find.textContaining('used by ', findRichText: true)), findsOneWidget);
    // removing one keeps what the other uses; removing both removes the pack
    await tester.runAsync(() => regions.remove(_county));
    expect(file.existsSync(), isTrue, reason: 'Idaho still uses the pack');
    expect(regions.offroadPacks.single.usedBy, ['Idaho']);
    await tester.runAsync(() => regions.remove('us-id'));
    expect(file.existsSync(), isFalse);

    // no pack covers the region: no off-road part, and no problem to show
    offroadWeb.files['${kOffroadBaseUrl}current.json'] = utf8.encode(_catalogue([_utah]));
    final none = RegionsState(
      policy: s.policy,
      supportDir: () async => s.dir,
      catalogue: catalogue,
      maps: s.maps,
      opener: (_) async => core,
      offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${s.dir.path}/other-catalogue'), fetch: offroadWeb.fetch),
      packDownloader: packs,
    );
    final p = (await tester.runAsync(() => none.plan(const RegionRecord(id: 'far', name: 'Far away', kind: 'county', bbox: [-80.0, 25.0, -79.0, 26.0]))))!;
    expect((p.offroad, p.offroadProblem), (null, null));
    none.dispose();

    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });
}

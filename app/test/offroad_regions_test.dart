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

/// Lets timers and file work run until [done] (at most [turns] turns of 40 ms, then the test's own expects say what is missing).
Future<void> _settleUntil(WidgetTester tester, bool Function() done, {int turns = 300}) async {
  for (var i = 0; i < turns && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  // one more turn, so what arrived with the last change is drawn
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pump(const Duration(milliseconds: 50));
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

    test('a box alone (no state known): the pack it lies deepest in; across a border, the packs that cover it; none near, none', () {
      List<String> ids(GeoBounds b) => [for (final p in packsCovering(packs, b)) p.id];
      // Twin Falls County: Idaho's box holds all of it; Utah's and Nevada's reach only its south (they end at 42.5)
      expect(ids(const GeoBounds(south: 41.99, west: -115.04, north: 42.92, east: -114.0)), ['idaho']);
      // Utah's and Nevada's boxes both hold this box in western Utah: it lies deeper in Utah's (Nevada's edge is 0.2 degrees off)
      expect(ids(const GeoBounds(south: 40.0, west: -114.0, north: 41.0, east: -113.5)), ['utah']);
      // The Pacific Northwest's box: no pack holds it. Idaho's covers most of it and Nevada's adds ground west of Idaho's.
      // Utah's reaches only a strip Idaho's already covers: it was listed here too (every pack the box met), a whole pack that
      // brought nothing new.
      expect(ids(const GeoBounds(south: 42.0, west: -125.0, north: 49.0, east: -111.0)), ['idaho', 'nevada']);
      expect(ids(const GeoBounds(south: 25.0, west: -82.0, north: 31.0, east: -80.0)), isEmpty);
    });

    test('a county on a state line gets its own state\'s pack, not the neighbour whose box also holds it', () {
      // The published boxes of two neighbouring states. Each is the state plus about 50 km, so Oregon's reaches into Idaho.
      final line = parseOffroadCatalogue(_catalogue([
        _pack('idaho', 'Idaho', [-118.0, 41.5, -110.3, 49.5], 300 << 20),
        _pack('oregon', 'Oregon', [-125.3, 41.5, -115.8, 46.8], 250 << 20),
      ]));
      // An Idaho county by the Oregon line. Both boxes hold all of it and Oregon's is the smaller box, so the smallest box that
      // held a region gave it Oregon's pack (the region list was sized by the same rule and still names Oregon's for it).
      const county = GeoBounds(south: 43.11, west: -116.51, north: 43.81, east: -115.97);
      const idaho = RegionRecord(id: 'us-id', name: 'Idaho', kind: 'region', country: 'US');
      const oregon = RegionRecord(id: 'us-or', name: 'Oregon', kind: 'region', country: 'US');
      List<String> ids(GeoBounds b, [List<RegionRecord> states = const []]) => [for (final p in packsCovering(line, b, states: states)) p.id];
      expect(ids(county, [idaho]), ['idaho'], reason: 'the state the region list says it is in');
      expect(ids(county), ['idaho'], reason: 'with no state known, the box it lies deepest in');
      // a county on the Oregon side of the line, in both boxes too, gets Oregon's
      const across = GeoBounds(south: 43.6, west: -117.6, north: 44.3, east: -117.0);
      expect(ids(across, [oregon]), ['oregon']);
      expect(ids(across), ['oregon']);
      // a metro area across the line is in both states: one pack each
      expect(ids(const GeoBounds(south: 43.6, west: -117.3, north: 44.2, east: -116.6), [idaho, oregon]), ['idaho', 'oregon']);
      // a state with no pack of its own falls back to the box
      const other = RegionRecord(id: 'us-xx', name: 'Elsewhere', kind: 'region', country: 'US');
      expect(ids(county, [other]), ['idaho']);
      // a state of the same name in another country is not this pack's
      const abroad = RegionRecord(id: 'xx-id', name: 'Idaho', kind: 'region', country: 'XX');
      expect(ids(across, [abroad]), ['oregon']);
    });

    test('the region list says which state a region is in, and which states a larger region holds', () {
      final us = RegionShard.parse('us', File('test/fixtures/regions_us.json').readAsStringSync()).records;
      List<String> states(String id) => [for (final r in statesIn(us, id)) r.id];
      expect(states('us-id'), ['us-id'], reason: 'a state is its own');
      expect(states('us-id-twin-falls-county'), ['us-id'], reason: 'a county, through its parents');
      expect(states('us-id-twin-falls'), ['us-id'], reason: 'a city, through its county');
      expect(states('us-metro-twin-falls-id'), ['us-id']);
      expect(states('us-id-magic-valley'), ['us-id']);
      expect(states('us-pacific-northwest'), ['us-id'], reason: 'a region of several states: the states in it (the fixture has Idaho of them)');
      expect(states('us-intermountain-west'), ['us-id', 'us-ut']);
      expect(states('us-mountain-west'), ['us-id', 'us-ut'], reason: 'at any distance: Idaho is in the Intermountain West, which is in it');
      expect(states('us'), ['us-id', 'us-ut']);
      expect(states('nowhere'), isEmpty);
    });
  });

  testWidgets('a region near a state line is planned with its own state\'s pack, not the smaller neighbouring box that also holds it', (tester) async {
    final s = await SettingsRig.create(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    // A neighbouring state's pack whose box (the state plus its margin) also holds Twin Falls County and is smaller than Idaho's:
    // what Oregon's published box is to the Idaho counties on its line.
    final neighbour = _pack('utah', 'Utah', [-115.2, 36.5, -108.3, 43.0], 200 << 20);
    final offroadWeb = FakeWeb()..files['${kOffroadBaseUrl}current.json'] = utf8.encode(_catalogue([_idaho, neighbour]));
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final regions = RegionsState(
      policy: s.policy,
      supportDir: () async => s.dir,
      catalogue: catalogue,
      maps: s.maps,
      opener: (_) async => core,
      offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: offroadWeb.fetch),
      packDownloader: _Packs(),
    );
    late RegionRecord county;
    await tester.runAsync(() async {
      await s.engine.saveDefinition(File('../packages/cache_search/layers/mapterhorn.json').readAsStringSync());
      await regions.init();
      county = (await catalogue.shard('us'))[_county]!;
      await catalogue.geometry(county);
    });
    // The case is the one that went wrong: both boxes hold the county, and the neighbour's is the smaller.
    final both = parseOffroadCatalogue(_catalogue([_idaho, neighbour]));
    final b = county.bounds!;
    expect(both.every((p) => p.bbox[0] <= b.west && p.bbox[1] <= b.south && p.bbox[2] >= b.east && p.bbox[3] >= b.north), isTrue);
    double area(OffroadPack p) => (p.bbox[2] - p.bbox[0]) * (p.bbox[3] - p.bbox[1]);
    expect(area(both.last), lessThan(area(both.first)), reason: 'the smallest box that holds it is the neighbour\'s: what was picked');
    final states = (await tester.runAsync(() => regions.statesOf(county)))!;
    expect(states.map((r) => r.id), ['us-id'], reason: 'the region list says the county is in Idaho');
    final plan = (await tester.runAsync(() => regions.plan(county)))!;
    expect(plan.offroad!.packs.map((p) => p.pack.id), ['idaho']);
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
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
    // The search and the pop-up's plan run outside the test's clock: wait for what they show, not a fixed number of turns (a
    // busy runner took longer than 6, Tests 41547954797).
    await _settleUntil(tester, () => find.byKey(const ValueKey('hit-$_county')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('hit-$_county')));
    await _settleUntil(tester, () => find.text('Download Twin Falls County?').evaluate().isNotEmpty && find.textContaining('off-road').evaluate().isNotEmpty);
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
    await _settleUntil(tester, () => find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('already on this device')).evaluate().isNotEmpty);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('already on this device')), findsOneWidget);
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

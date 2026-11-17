// The region download pop-up and the progress total say what a region takes on the device, not only the gzip the catalogue counts
// (web-region-progress, approved by cache-pm: "30 MB on this device (15 MB to download)"; offline "15 MB to download").
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/layers/tile_math.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/maps/ui/format.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/regions/ui/region_actions.dart' show regionMapNotes;
import 'package:cache/regions/ui/region_page.dart' show offerLine;
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';
import 'support/settings_rig.dart';

const _county = 'us-id-twin-falls-county';

Future<void> _settleUntil(WidgetTester tester, bool Function() done, {int turns = 200}) async {
  for (var i = 0; i < turns && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<(RegionsState, FakeRegions, SettingsRig)> _boot(WidgetTester tester) async {
  final s = await SettingsRig.create(tester);
  final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
  Directory(core.tileDir).createSync(recursive: true);
  final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
  final regions = RegionsState(policy: s.policy, supportDir: () async => s.dir, catalogue: catalogue, maps: s.maps, opener: (_) async => core);
  await tester.runAsync(() async {
    await regions.init();
    // the country's list is read, so the search finds the county
    await catalogue.shard('us');
  });
  return (regions, core, s);
}

Future<void> _openDialog(WidgetTester tester, SettingsRig s, RegionsState regions) async {
  await s.show(tester, RegionsScreen(regions: regions));
  await tester.runAsync(() async {
    await tester.enterText(find.byKey(const ValueKey('region-search')), 'twin falls county');
  });
  await _settleUntil(tester, () => find.byKey(const ValueKey('hit-$_county')).evaluate().isNotEmpty);
  await tester.tap(find.byKey(const ValueKey('hit-$_county')));
  await _settleUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
}

void main() {
  testWidgets('the pop-up says what the region takes on the device and what is fetched, from the core\'s plan', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20; // on the device
    core.alreadyBytes = 70 << 20; // so 50 MB is fetched
    await _openDialog(tester, s, regions);
    await _settleUntil(tester, () => find.textContaining('Takes ', findRichText: true).evaluate().isNotEmpty);
    final text = find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('Takes ', findRichText: true));
    expect(text, findsOneWidget, reason: 'before: only the catalogue\'s transfer size, as if it were what the region takes');
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('to download)', findRichText: true)), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  testWidgets('offline, with no plan to ask, the pop-up gives the catalogue\'s figure as the download only', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.offline = true;
    await _openDialog(tester, s, regions);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('to download', findRichText: true)), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('on this device', findRichText: true)), findsNothing);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  testWidgets('a row\'s total is the core\'s on-device total once it knows the part, so the bytes done never pass it', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    late RegionRecord county;
    await tester.runAsync(() async {
      county = (await regions.catalogue.shard('us'))[_county]!;
      await regions.catalogue.geometry(county);
      await regions.download(county, routing: true, map: false, anyway: true);
    });
    final l = regions.regionOf(_county)!;
    final catalogueRouting = county.sizes!.routing!;
    expect(catalogueRouting, isNot(120 << 20), reason: 'the catalogue\'s figure is the transfer size, not the core\'s total');
    expect(regions.totalBytesOf(l), 120 << 20, reason: 'before: the catalogue\'s transfer number, so 12 MB done read "of 5 MB"');
    final done = l.parts.fold<int>(0, (a, p) => a + p.bytes);
    expect(done, lessThanOrEqualTo(regions.totalBytesOf(l)!));
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  test('a list row labels the catalogue\'s figure as the download, so it never reads like disk space', () {
    const rec = RegionRecord(id: 'x', name: 'Example', kind: 'county', country: 'US');
    final download = RegionOffer(RegionOfferKind.download, routing: true, map: true, bytes: 15 << 20);
    expect(offerLine(rec, download), 'County · ${formatBytes(15 << 20)} to download', reason: 'before: "County · 15 MB"');
    expect(offerLine(rec, const RegionOffer(RegionOfferKind.download)), 'County · Size unknown');
    expect(offerLine(rec, const RegionOffer(RegionOfferKind.carryOn, bytes: 5 << 20)), 'County · ${formatBytes(5 << 20)} to download');
  });

  testWidgets('the pop-up is on screen at once with the catalogue\'s download figure, and changes in place when the plan arrives', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    core.alreadyBytes = 70 << 20;
    core.planGate = Completer<void>();
    await _openDialog(tester, s, regions);
    Finder inDialog(String t) => find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(t, findRichText: true));
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'before: the pop-up waited for the plan (up to 12 s)');
    expect(inDialog('to download'), findsOneWidget, reason: 'the catalogue\'s figure, said to be the download');
    expect(inDialog('on this device'), findsNothing, reason: 'the plan has not arrived');
    core.planGate!.complete();
    await _settleUntil(tester, () => inDialog('Takes ').evaluate().isNotEmpty);
    expect(inDialog('Takes '), findsOneWidget, reason: 'updated in place, the same pop-up');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  testWidgets('a plan that finds nothing (roads not published, map too big) never reads "0 B": the catalogue\'s figure stays as the download', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 0; // no road tiles published for the area
    core.alreadyBytes = 0;
    for (final l in s.maps.catalogueLayers) {
      s.maps.setOn(l.id, false); // no map part to plan (a country's map is excluded the same way)
    }
    await _openDialog(tester, s, regions);
    // give a plan every chance to arrive and change the line
    await _settleUntil(tester, () => core.calls.contains('plan'), turns: 100);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 100));
    Finder inDialog(String t) => find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(t, findRichText: true));
    expect(inDialog('0 B'), findsNothing, reason: 'before: "0 B on this device (0 B to download)"');
    expect(inDialog('on this device'), findsNothing);
    expect(inDialog('to download'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });
  _regionNotesTests();
}

// ---- what the pop-up says of a map layer left out or stepped down (region-layer-left-out) -------------------------------------

Map<String, dynamic> _layerJson(String id, String title, {bool unavailable = false, int? limitTiles}) => {
      'format': 1,
      'id': id,
      'title': title,
      'description': 'd',
      'license': 'l',
      'attribution': 'a',
      'kind': 'hillshade',
      'transform': 'as_is',
      'encoding': 'terrarium',
      'source': {'type': 'xyz', 'url': 'https://t.test/{z}/{x}/{y}.webp', 'minzoom': 0, 'maxzoom': 14, 'tile_size': 512},
      'approx_tile_bytes': 1000,
      if (unavailable) 'fake_unavailable': true,
      'download_limit_tiles': ?limitTiles,
    };

/// Only these layers are on (the first one is wholly allowed at full detail, so the map part is planned); the pop-up for the county is
/// open and its plan has arrived.
Future<void> _openWith(WidgetTester tester, RegionsState regions, SettingsRig s, List<Map<String, dynamic>> layers) async {
  await tester.runAsync(() async {
    for (final l in layers) {
      await s.engine.saveDefinition(jsonEncode(l));
    }
  });
  for (final l in s.maps.catalogueLayers) {
    s.maps.setOn(l.id, layers.any((j) => j['id'] == l.id));
  }
  await _openDialog(tester, s, regions);
  await _settleUntil(tester, () => find.textContaining('Takes ', findRichText: true).evaluate().isNotEmpty);
}

Finder _inDialog(String t) => find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(t, findRichText: true));

Future<void> _close(WidgetTester tester, RegionsState regions, SettingsRig s) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
  await tester.pumpWidget(const SizedBox());
  regions.dispose();
  await s.dispose(tester);
}

/// The most tiles a layer may have for the county at zoom [z] and every zoom above it: its top zoom (14) then does not fit.
Future<int> _tilesUpTo(WidgetTester tester, RegionsState regions, int z) async {
  final b = (await tester.runAsync(() async => (await regions.catalogue.shard('us'))[_county]!.bounds!))!;
  return TileMath.countRange(b, 0, z);
}

void _regionNotesTests() {
  const lessText = 'is less detailed at close zoom to fit one download.';

  testWidgets('everything fits at full detail: no note under the size', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    await _openWith(tester, regions, s, [_layerJson('okshade', 'Hillshade')]);
    expect(_inDialog('left out'), findsNothing);
    expect(_inDialog(lessText), findsNothing);
    expect(_inDialog('less detailed'), findsNothing);
    await _close(tester, regions, s);
  });

  testWidgets('a layer too big at every zoom is left out, by its own name, and the size is of what downloads', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    await _openWith(tester, regions, s, [_layerJson('okmap', 'Okay layer'), _layerJson('bigshade', 'Hillshade', unavailable: true)]);
    expect(_inDialog('Hillshade is left out: too big for one download.'), findsOneWidget);
    expect(_inDialog('less detailed'), findsNothing);
    await _close(tester, regions, s);
  });

  testWidgets('a layer stepped down to a lower top zoom says so, once', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    final limit = await _tilesUpTo(tester, regions, 13); // the top zoom (14) does not fit, 13 does
    await _openWith(tester, regions, s, [_layerJson('okmap', 'Okay layer'), _layerJson('stepshade', 'Hillshade', limitTiles: limit)]);
    expect(_inDialog('Hillshade $lessText'), findsOneWidget);
    expect(_inDialog('left out'), findsNothing);
    await _close(tester, regions, s);
  });

  testWidgets('both: left out first, then less detailed (two lines)', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    final limit = await _tilesUpTo(tester, regions, 13);
    await _openWith(tester, regions, s, [
      _layerJson('okmap', 'Okay layer'),
      _layerJson('bigshade', 'Hillshade', unavailable: true),
      _layerJson('stepdetail', 'Land detail', limitTiles: limit),
    ]);
    expect(_inDialog('Hillshade is left out: too big for one download.'), findsOneWidget);
    expect(_inDialog('Land detail $lessText'), findsOneWidget);
    final left = tester.getTopLeft(_inDialog('is left out')).dy, less = tester.getTopLeft(_inDialog('less detailed')).dy;
    expect(left, lessThan(less), reason: 'left out comes first');
    await _close(tester, regions, s);
  });

  testWidgets('several layers left out are named together', (tester) async {
    final (regions, core, s) = await _boot(tester);
    core.sizes[_county] = 120 << 20;
    await _openWith(tester, regions, s, [
      _layerJson('okmap', 'Okay layer'),
      _layerJson('bigshade', 'Hillshade', unavailable: true),
      _layerJson('bigcontours', 'Contour lines', unavailable: true),
    ]);
    expect(_inDialog('Hillshade and contour lines are left out: too big for one download.'), findsOneWidget);
    await _close(tester, regions, s);
  });

  test('the base map is "the map" in the notes', () {
    LayerDef base(String id) => LayerDef.parse(jsonEncode({
          'format': 1,
          'id': id,
          'title': 'Base map (Example)',
          'description': 'd',
          'license': 'l',
          'attribution': 'a',
          'kind': 'basemap',
          'transform': 'as_is',
          'source': {'type': 'xyz', 'url': 'https://t.test/{z}/{x}/{y}.pbf', 'minzoom': 0, 'maxzoom': 15},
        }));
    final d = base('examplebase');
    final stepped = RegionPlan(map: [MapLayerPlan(d, AreaEstimate(tiles: 1, bytes: 1, maxZoom: d.maxZoom - 2, allowed: true))]);
    expect(regionMapNotes(stepped), ['The map $lessText']);
    final left = RegionPlan(map: [MapLayerPlan(d, const AreaEstimate(tiles: 0, bytes: 0, maxZoom: 0, allowed: false))]);
    expect(regionMapNotes(left), ['The map is left out: too big for one download.']);
  });
}

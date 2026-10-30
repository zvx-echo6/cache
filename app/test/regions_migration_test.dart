// The phone the owner tested 1.0.27 with: map downloads made layer by layer by 1.0.0 builds (hillshade twice, BLM, motor vehicle use
// map, and a Forest Service download that stopped), and Idaho downloaded as a region, partly (directions ready, places 40%, off-road
// waiting). 1.0.27 listed seven "Idaho" rows in Settings > Maps, worked out sizes for a minute, said "Can't be downloaded here" for
// Idaho, opened an old checkbox sheet whose Download did nothing, and showed core text when Update failed.

import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/ui/format.dart';
import 'package:cache/regions/problem_words.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/owner_state.dart';

Future<void> _show(WidgetTester tester, OwnerState o, Widget page) async {
  await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page));
  await o.settle(tester);
}

void main() {
  testWidgets('old per-layer downloads join the region they are in; exact duplicates go; nothing else is deleted', (tester) async {
    final o = await OwnerState.boot(tester, legacyOutside: true);
    final engine = o.s.engine;
    final local = o.regions.local;
    expect([for (final l in local) l.name], unorderedEquals(['Idaho', 'Utah']), reason: 'one line per region, one per area outside them');
    final idaho = o.regions.regionOf('us-id')!;
    // Hillshade (one of the two), BLM, motor vehicle use map and the Forest Service download are Idaho's map now.
    expect(idaho.areas.map((a) => a.id), unorderedEquals([o.legacy['blm']!.id, o.legacy['mvum']!.id, o.legacy['usfs']!.id, anyOf(o.legacy['hillshade']!.id, o.legacy['hillshade again']!.id)]));
    // The duplicate hillshade is removed (its tiles are the other one's); the rest stay, the stopped one too.
    expect(engine.allAreas, hasLength(5));
    expect(engine.allAreas.where((a) => a.layerId == 'hillshade' && a.label == 'Idaho'), hasLength(1));
    expect(o.regions.tidyNote, contains('Removed 1 duplicate'));
    // The old download outside every region is an area of its own: map only, never offered places or off-road.
    final utah = local.firstWhere((l) => l.name == 'Utah');
    expect(utah.isArea, isTrue);
    expect(utah.hasRouting || utah.hasPlaces || utah.hasOffroad, isFalse);
    expect(o.regions.missesPlaces(utah), isFalse);
    // Running the migration again changes nothing.
    await tester.runAsync(o.regions.migrateOldDownloads);
    expect(engine.allAreas, hasLength(5));
    await o.dispose(tester);
  });

  testWidgets('Idaho says where each part stands, and stopped is not failed: Carry on, not "Can\'t be downloaded here"', (tester) async {
    final o = await OwnerState.boot(tester);
    final l = o.regions.regionOf('us-id')!;
    expect(l.phase, RegionPhase.stopped);
    expect(l.partsLine, matches(RegExp(r'^Map stopped at \d+% · Places 40% · Off-road waiting$')));
    expect(l.error, isNull, reason: 'nothing failed: it stopped part way');
    // The catalogue's sizes, at once: what is left, what is here.
    final offer = o.regions.offer(o.idaho);
    expect(offer.kind, RegionOfferKind.carryOn);
    expect(offer.bytes, isNotNull);
    expect(offerLine(o.idaho, offer), 'State · ${formatBytes(offer.bytes!)} to go');
    await o.dispose(tester);
  });

  testWidgets('Settings > Maps: one line per region with its fix, no per-layer list', (tester) async {
    final o = await OwnerState.boot(tester);
    await _show(tester, o, MapsPage(deps: o.s.deps));
    expect(find.byKey(const ValueKey('local-us-id')), findsOneWidget);
    expect(find.text('Idaho'), findsOneWidget, reason: 'seven "Idaho" rows in 1.0.27');
    expect(find.byKey(const ValueKey('local-fix-us-id')), findsOneWidget);
    expect(find.text('Carry on'), findsOneWidget);
    expect(find.textContaining('Hillshade'), findsNothing);
    expect(find.textContaining('Stopped before it finished'), findsNothing);
    // The note about the duplicate, once.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Removed 1 duplicate'), findsOneWidget);
    expect(o.regions.tidyNote, isNull);
    await o.dispose(tester);
  });

  testWidgets('the Regions sheet: sizes at once from the catalogue; Idaho offers Carry on; the pop-up carries on only what stopped', (tester) async {
    final o = await OwnerState.boot(tester);
    var plans = 0;
    o.core.calls.clear();
    await _show(tester, o, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showRegionsSheet(c, o.regions, lat: 42.56, lon: -114.46), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await o.settle(tester);
    await o.settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    plans = o.core.calls.where((c) => c == 'plan').length;
    expect(plans, 0, reason: 'nothing is worked out on the phone for a region of the catalogue');
    expect(find.textContaining('Working out the size'), findsNothing);
    expect(find.textContaining("Can't be downloaded here"), findsNothing);
    final county = o.us['us-id-twin-falls-county']!;
    // Its size counts off-road: only its terrain, as the state's pack comes with Idaho, and the line says so.
    final lines = [for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? ''];
    final line = tester.widgetList<Text>(find.byKey(ValueKey('region-line-${county.id}'))).firstOrNull?.data;
    expect(line, isNotNull, reason: 'the sheet shows: $lines');
    expect(line, 'County · ${formatBytes(o.regions.offer(county).bytes!)} · off-road shared with Idaho');
    expect(find.byKey(const ValueKey('region-fix-us-id')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('region-fix-us-id')));
    await o.settle(tester);
    expect(find.text('Carry on with Idaho?'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing, reason: 'the old per-part sheet is gone');
    final usfs = o.legacy['usfs']!;
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await tester.pump();
    expect(find.text('Carrying on with Idaho'), findsOneWidget, reason: 'the tap says what it did at once');
    await o.settle(tester);
    expect(usfs.phase, isNot(AreaPhase.failed), reason: 'the stopped map download carries on');
    expect(o.core.calls.where((c) => c == 'add'), isEmpty, reason: 'directions and places had not stopped: nothing asked again');
    await o.dispose(tester);
  });

  testWidgets('the Idaho page: each part with its state, the fix beside what stopped, Delete', (tester) async {
    final o = await OwnerState.boot(tester);
    await _show(tester, o, RegionPage(regions: o.regions, id: 'us-id'));
    for (final k in ['part-map', 'part-routing', 'part-places', 'part-offroad']) {
      expect(find.byKey(ValueKey(k.replaceFirst('routing', 'directions'))), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('fix-map')), findsOneWidget);
    expect(find.text('Forest Service trails and roads'), findsOneWidget);
    expect(find.byKey(const ValueKey('region-delete')), findsOneWidget);
    await o.dispose(tester);
  });

  test('a core error is said in plain words with the next step, never as the core wrote it', () {
    const raw = 'a download needs "bbox" [west, south, east, north] or "polygon" [[lon, lat], ...]';
    final w = downloadProblemWords(const CacheSearchException('bad_json', raw), what: 'carry on with Idaho');
    expect(w, isNot(contains('bbox')));
    expect(w, startsWith("Couldn't carry on with Idaho."));
    expect(downloadProblemWords(const CacheSearchException('offline', 'HTTP 503 from https://x'), what: 'carry on with Idaho'),
        "Couldn't carry on with Idaho: no connection. Connect, then try again.");
    expect(downloadProblemWords(StateError(raw), what: 'x'), isNot(contains('bbox')));
    expect(areaProblemWords('No connection. Connect and tap Update to continue.'), 'No connection');
  });

  test('a region the catalogue has no sizes for says "Size unknown", never waits', () {
    expect(RegionSizes.fromJson(null), isNull);
    final s = RegionSizes.fromJson({'routing': 5, 'map': {'basemap': [4, 15]}, 'offroad': {'packs': {'idaho': 9}, 'terrain': 3}})!;
    expect((s.routing, s.map['basemap'], s.offroadPacks['idaho'], s.offroadTerrain, s.places), (5, 4, 9, 3, null));
  });
}

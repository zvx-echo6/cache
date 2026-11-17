// The region download pop-up's parts line ("Map, directions and off-road.") comes from the real checks, not from a default:
// off-road only when the off-road catalogue has a pack over the region (the rule that greys "Add off-road"), directions only when
// the routing plan has data, and what the line says is what is downloaded. The pop-up still opens at once; a check not known yet
// shows the map part and the line changes in place when it arrives (region-offer-honest-parts, approved by cache-pm).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/regions/offroad_catalogue.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';
import 'support/settings_rig.dart';
import 'support/weather_fakes.dart';

const _county = 'us-id-twin-falls-county';

Map<String, dynamic> _pack(String id, String name, List<double> bbox) => {
  'id': id,
  'name': name,
  'country': 'US',
  'bbox': bbox,
  'build': 'offroad-2026-10',
  'land_access': 'us',
  'bytes': 300 << 20,
  'files': {
    'offroad.sqlite': {'path': 'offroad-2026-10/$id/offroad.sqlite', 'url': '${kOffroadBaseUrl}offroad-2026-10/$id/offroad.sqlite', 'bytes': 300 << 20, 'sha256': 'AB' * 32},
  },
};

String _packs(List<Map<String, dynamic>> packs) =>
    jsonEncode({'format': 1, 'component': 'offroad', 'base_url': kOffroadBaseUrl, 'elevation': {'minzoom': 12, 'maxzoom': 12}, 'regions': packs});

/// The region list with the county as a Germany would be: no `sizes` at all (an unsized country shard), or sized with places.
FakeWeb _web({required bool sized}) {
  final web = regionWeb();
  final us = jsonDecode(utf8.decode(web.files['${kRegionCatalogueBase}us.json']!)) as Map<String, dynamic>;
  for (final r in (us['regions'] as List).cast<Map<String, dynamic>>()) {
    if (r['id'] != _county) continue;
    if (sized) {
      (r['sizes'] as Map<String, dynamic>)['places'] = 3 << 20;
    } else {
      r.remove('sizes');
    }
  }
  web.files['${kRegionCatalogueBase}us.json'] = utf8.encode(jsonEncode(us));
  return web;
}

Future<void> _settleUntil(WidgetTester tester, bool Function() done, {int turns = 200}) async {
  for (var i = 0; i < turns && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pump(const Duration(milliseconds: 50));
}

/// Opens the county's download pop-up. [packs]: the off-road packs the off-road catalogue lists; [routingBytes]: what the core's plan says
/// road routing takes (0: nothing published); [gate]: holds the core's plan back until it is completed.
Future<(RegionsState, FakeRegions, SettingsRig)> _open(
  WidgetTester tester, {
  required bool sized,
  required List<Map<String, dynamic>> packs,
  int routingBytes = 120 << 20,
  Completer<void>? gate,
}) async {
  final s = await SettingsRig.create(tester);
  final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
  Directory(core.tileDir).createSync(recursive: true);
  core.sizes[_county] = routingBytes;
  core.alreadyBytes = 0;
  if (gate != null) core.planGate = gate;
  final offroadWeb = FakeWeb()..files['${kOffroadBaseUrl}current.json'] = utf8.encode(_packs(packs));
  final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: _web(sized: sized).fetch);
  final regions = RegionsState(
    policy: s.policy,
    supportDir: () async => s.dir,
    catalogue: catalogue,
    maps: s.maps,
    opener: (_) async => core,
    offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: offroadWeb.fetch),
  );
  await tester.runAsync(() async {
    await regions.init();
    await catalogue.shard('us');
  });
  await s.show(tester, RegionsScreen(regions: regions));
  await tester.runAsync(() async {
    await tester.enterText(find.byKey(const ValueKey('region-search')), 'twin falls county');
  });
  await _settleUntil(tester, () => find.byKey(const ValueKey('hit-$_county')).evaluate().isNotEmpty);
  await tester.tap(find.byKey(const ValueKey('hit-$_county')));
  await _settleUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
  return (regions, core, s);
}

Finder _inDialog(String t) => find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(t, findRichText: true));

Future<void> _close(WidgetTester tester, RegionsState regions, SettingsRig s) async {
  if (find.byType(AlertDialog).evaluate().isNotEmpty) {
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')));
  }
  await tester.pumpWidget(const SizedBox());
  regions.dispose();
  await s.dispose(tester);
}

void main() {
  final idaho = _pack('idaho', 'Idaho', [-118.0, 41.5, -110.3, 49.5]);
  final maine = _pack('maine', 'Maine', [-71.2, 43.0, -66.9, 47.5]);

  testWidgets('Germany-shaped: no sizes, no pack over it, routing 0: the line says "Map." and nothing else is downloaded', (tester) async {
    final (regions, core, s) = await _open(tester, sized: false, packs: [maine], routingBytes: 0);
    await _settleUntil(tester, () => _inDialog('Map.').evaluate().isNotEmpty);
    expect(_inDialog('Map.'), findsOneWidget);
    expect(_inDialog('directions'), findsNothing, reason: 'the routing plan has no data');
    expect(_inDialog('off-road'), findsNothing, reason: 'no pack covers it');
    // Download: only the map is asked for (what the line says is what is downloaded)
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Download')));
    await _settleUntil(tester, () => false, turns: 20);
    expect(core.calls.where((c) => c == 'add'), isEmpty, reason: 'no routing or places part was requested');
    await _close(tester, regions, s);
  });

  testWidgets('Idaho-shaped: sized, routing, places and a pack over it: "Map, directions, places and off-road."', (tester) async {
    final (regions, _, s) = await _open(tester, sized: true, packs: [idaho]);
    await _settleUntil(tester, () => _inDialog('Takes ').evaluate().isNotEmpty);
    expect(_inDialog('Map, directions, places and off-road.'), findsOneWidget);
    await _close(tester, regions, s);
  });

  testWidgets('a sized region whose off-road catalogue has no pack over it does not say off-road', (tester) async {
    final (regions, _, s) = await _open(tester, sized: true, packs: [maine]);
    await _settleUntil(tester, () => _inDialog('Map, directions and places.').evaluate().isNotEmpty);
    expect(_inDialog('off-road'), findsNothing);
    await _close(tester, regions, s);
  });

  testWidgets('a check that arrives late changes the line in place: the pop-up opens at once with the map, then directions and off-road appear', (tester) async {
    final gate = Completer<void>();
    final (regions, _, s) = await _open(tester, sized: false, packs: [idaho], gate: gate);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the pop-up is not held back by the checks');
    expect(_inDialog('Map.'), findsOneWidget, reason: 'only the map is known: nothing is assumed');
    expect(_inDialog('directions'), findsNothing);
    gate.complete();
    await _settleUntil(tester, () => _inDialog('directions').evaluate().isNotEmpty);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the same pop-up');
    expect(_inDialog('Map, directions and off-road.'), findsOneWidget, reason: 'updated in place when the checks came back');
    await _close(tester, regions, s);
  });
}

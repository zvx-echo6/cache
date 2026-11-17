// The region page after its layer downloads end (web-region-progress): the rows must read Ready with the final size at once, with
// no reload. A real layer engine on the fake core (test/support/layers_native_fake.dart) inside the maps and regions states.
import 'dart:io';

import 'package:cache/maps/layers/core_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layers_native_fake.dart';
import 'support/regions_fake.dart';
import 'support/settings_rig.dart';

void main() {
testWidgets('the region page rows read Ready, with the final size, when the layer jobs end, with no reload (web-region-progress)', (tester) async {
    final s = await SettingsRig.create(tester);
    final layersDir = Directory.systemTemp.createTempSync('layers');
    late SearchCore core;
    await tester.runAsync(() async {
      core = await SearchCore.open(const [], extra: {'test_port': 4321}, native: makeLayersNative);
    });
    final engine = CoreLayerEngine(openCore: () async => core, layersConfig: () => {'dir': layersDir.path}, connected: () async => true, pollEvery: const Duration(milliseconds: 20));
    await tester.runAsync(engine.start);
    final maps = MapsState(engine: engine, settingsDirOverride: s.dir);
    final core2 = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core2.tileDir).createSync(recursive: true);
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final regions = RegionsState(policy: s.policy, supportDir: () async => s.dir, catalogue: catalogue, maps: maps, opener: (_) async => core2);
    const id = 'us-id-twin-falls-county';
    await tester.runAsync(() async {
      await maps.init();
      await regions.init();
      final county = (await catalogue.shard('us'))[id]!;
      await catalogue.geometry(county);
      await regions.download(county, routing: false, map: true, anyway: true);
    });
    final started = regions.regionOf(id)!;
    expect(started.areas, isNotEmpty, reason: 'the region started map downloads');
    await s.show(tester, RegionPage(regions: regions, id: id));
    // the jobs end (the fake finishes each after a few looks); wait on the state itself
    for (var i = 0; i < 400 && !(regions.regionOf(id)?.parts.every((p) => p.complete) ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    final l = regions.regionOf(id)!;
    expect([for (final a in l.areas) a.phase], everyElement(AreaPhase.done), reason: 'areas: ${[for (final a in l.areas) '${a.layerId}:${a.phase.name}']}');
    expect(find.textContaining('so far'), findsNothing, reason: 'before: rows kept "so far" and Pause after their jobs ended');
    expect(find.textContaining('Ready'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    engine.dispose();
    await tester.runAsync(() => core.close());
    layersDir.deleteSync(recursive: true);
    await s.dispose(tester);
  });
}

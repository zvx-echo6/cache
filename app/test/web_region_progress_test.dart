import 'dart:io';

import 'package:cache/downloads/download_row.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';
import 'support/settings_rig.dart';

void main() {
  group('a download never shows more done than the total (web-region-progress)', () {
    test('12 MB of a 5.8 MB estimate reads as "so far", with no bar, not as "12 of 5.8 MB"', () {
      const done = 12 << 20, total = 6081740;
      expect(dlBytes(done, total), isNot(contains(' of ')));
      expect(dlBytes(done, total), endsWith('so far'));
      expect(const DlState(DlPhase.running, done: done, total: total).fraction, isNull, reason: 'no bar to fill past full');
      expect(dlLine(const DlState(DlPhase.running, done: done, total: total, speed: 0)), isNot(contains(' of ')));
      // a total that holds still reads as before
      expect(dlBytes(4 << 20, 5 << 20), '4.0 of 5.0 MB');
      expect(const DlState(DlPhase.running, done: 4 << 20, total: 5 << 20).fraction, closeTo(0.8, 0.001));
    });
  });

  testWidgets('Pause tells the server engine to hold, and the region reads as paused', (tester) async {
    final s = await SettingsRig.create(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final regions = RegionsState(policy: s.policy, supportDir: () async => s.dir, catalogue: catalogue, maps: s.maps, opener: (_) async => core);
    await tester.runAsync(() async {
      await regions.init();
      final county = (await catalogue.shard('us'))['us-id-twin-falls-county']!;
      await catalogue.geometry(county);
      await regions.download(county, routing: true, map: false, anyway: true);
      expect(regions.regionOf('us-id-twin-falls-county')!.phase, RegionPhase.downloading);
      await regions.pauseAll();
    });
    expect(core.policies.last['hold'], isTrue, reason: 'the engine on the server is told, not only this tab');
    expect(regions.held, isTrue);
    expect(regions.regionOf('us-id-twin-falls-county')!.phase, RegionPhase.paused);
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });
}

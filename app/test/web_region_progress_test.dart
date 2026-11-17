import 'dart:io';

import 'package:cache/downloads/download_row.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/maps/layers/layer_def.dart' show AreaPhase;
import 'package:cache/chat/ask_focus.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/region_download.dart';
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

  testWidgets('a global Pause shows on every row: no part reads as running, and a download started while it is on is held too', (tester) async {
    final s = await SettingsRig.create(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final regions = RegionsState(policy: s.policy, supportDir: () async => s.dir, catalogue: catalogue, maps: s.maps, opener: (_) async => core);
    late LocalRegion l;
    await tester.runAsync(() async {
      await s.engine.saveDefinition(File('../packages/cache_search/layers/mapterhorn.json').readAsStringSync());
      await regions.init();
      final county = (await catalogue.shard('us'))['us-id-twin-falls-county']!;
      await catalogue.geometry(county);
      await regions.pauseAll();
      // a download asked for while the Pause is on
      await regions.download(county, routing: true, map: true, anyway: true);
      l = regions.regionOf('us-id-twin-falls-county')!;
    });
    expect(regions.held, isTrue);
    expect(s.engine.allAreas.where((a) => a.phase == AreaPhase.running), isEmpty, reason: 'before: a map layer started while paused ran on');
    const running = RegionPartStatus(RegionPartKind.map, PartState.downloading, fraction: 0.2, bytes: 2 << 20, totalBytes: 10 << 20);
    final row = partDl(regions, l, running, own: true);
    expect(row.phase, DlPhase.paused, reason: 'before: a part that is downloading read as running whatever the Pause said');
    expect(dlLine(row), contains('all downloads paused'));
    expect(regionDl(regions, l).phase, DlPhase.paused);
    expect(dlLine(regionDl(regions, l)), contains('all downloads paused'));
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  testWidgets('Ask holds the downloads with a lease, apart from the person\'s Pause: asked, renewed while Ask answers, ended when it stops', (tester) async {
    final s = await SettingsRig.create(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final focus = AskFocus();
    final regions = RegionsState(policy: s.policy, supportDir: () async => s.dir, catalogue: catalogue, maps: s.maps, opener: (_) async => core, focus: focus);
    await tester.runAsync(() => regions.init());
    core.policies.clear();
    await tester.runAsync(() async {
      focus.begin();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(core.policies.any((p) => p['ask'] == true), isTrue, reason: 'Ask asks for a lease');
    expect(core.policies.every((p) => p['hold'] != true), isTrue, reason: 'it is not the person\'s Pause: before, Ask sent hold: true');
    expect(regions.askHolds, isTrue);
    expect(regions.held, isFalse);
    core.policies.clear();
    await tester.runAsync(() async {
      focus.end();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(core.policies.any((p) => p['ask'] == false), isTrue, reason: 'the lease is ended when Ask stops');
    expect(regions.askHolds, isFalse);
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  testWidgets('until the connection is known after launch, a download the engine pauses for the network reads Paused, not "Stopped: no connection"', (tester) async {
    final s = await SettingsRig.create(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final regions = RegionsState(policy: s.policy, supportDir: () async => s.dir, catalogue: catalogue, maps: s.maps, opener: (_) async => core);
    late LocalRegion l;
    await tester.runAsync(() async {
      await regions.init();
      core.network = false; // the engine reports the download paused for the network
      final county = (await catalogue.shard('us'))['us-id-twin-falls-county']!;
      await catalogue.geometry(county);
      await regions.download(county, routing: true, map: false, anyway: true);
      l = regions.regionOf('us-id-twin-falls-county')!;
    });
    expect(l.phase, RegionPhase.paused);
    regions.connectionKnown = false; // just launched: the probe has not answered
    expect(regionDl(regions, l).phase, DlPhase.paused, reason: 'before: "Stopped: no connection" on a guess');
    expect(dlLine(regionDl(regions, l)), startsWith('Paused'));
    regions.connectionKnown = true;
    expect(regionDl(regions, l).phase, isNot(DlPhase.paused), reason: 'once the probe has answered the engine\'s reason is said');
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });
}

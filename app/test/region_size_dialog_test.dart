// The region download pop-up and the progress total say what a region takes on the device, not only the gzip the catalogue counts
// (web-region-progress, approved by cache-pm: "30 MB on this device (15 MB to download)"; offline "15 MB to download").
import 'dart:io';

import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';
import 'support/settings_rig.dart';

const _county = 'us-id-twin-falls-county';

Future<void> _settleUntil(WidgetTester tester, bool Function() done, {int turns = 1500}) async {
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
  await tester.runAsync(() => regions.init());
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
    final text = find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('on this device (', findRichText: true));
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
}

// The region list's off-road part, read by the app's own readers. With REGION_LIST_DIR (a folder of <iso>.json shards) and
// OFFROAD_CATALOGUE (the off-road current.json) set, every region of every shard must resolve to exactly the packs the app itself
// chooses for it (packsCovering with statesIn), each named pack must exist in the off-road catalogue, and its size must be that
// pack's file size. Without them the test has nothing to read and is skipped (the rule itself is tested in offroad_regions_test.dart).
import 'dart:io';

import 'package:cache/regions/offroad_catalogue.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Platform.environment['REGION_LIST_DIR'];
  final off = Platform.environment['OFFROAD_CATALOGUE'];
  final skip = dir == null || off == null ? 'set REGION_LIST_DIR and OFFROAD_CATALOGUE to read a built region list' : false;

  test('every region of the built list resolves to the packs and sizes the app chooses itself', () {
    final packs = parseOffroadCatalogue(File(off!).readAsStringSync());
    final byId = {for (final p in packs) p.id: p};
    var checked = 0, packRows = 0;
    for (final f in Directory(dir!).listSync().whereType<File>().where((f) => RegExp(r'/[a-z]{2}\.json$').hasMatch(f.path))) {
      final iso = f.uri.pathSegments.last.replaceAll('.json', '');
      final shard = RegionShard.parse(iso, f.readAsStringSync());
      expect(shard.records, isNotEmpty);
      for (final r in shard.records.values) {
        final sz = r.sizes;
        if (sz == null || !sz.hasOffroad) continue;
        final b = r.bounds;
        expect(b, isNotNull, reason: '${r.id} has off-road packs but no box');
        final want = packsCovering(packs, b!, states: statesIn(shard.records, r.id));
        expect(sz.offroadPacks.keys.toSet(), {for (final p in want) p.id}, reason: '${r.id} (${r.name})');
        for (final e in sz.offroadPacks.entries) {
          expect(byId[e.key], isNotNull, reason: '${r.id}: ${e.key} is not in the off-road catalogue');
          expect(e.value, byId[e.key]!.bytes, reason: '${r.id}: ${e.key} size');
        }
        checked++;
        packRows += sz.offroadPacks.length;
      }
    }
    // ignore: avoid_print
    print('REGION-LIST-CHECK regions checked: $checked, pack rows: $packRows');
    expect(checked, greaterThan(0));
  }, skip: skip);
}

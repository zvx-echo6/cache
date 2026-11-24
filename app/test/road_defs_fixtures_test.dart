import 'dart:io';

import 'package:cache/roads/road_fixtures.dart';
import 'package:cache/roads/road_sources.dart';
import 'package:flutter_test/flutter_test.dart';


/// The core's tests (packages/cache_search/native/cache_live/tests/road_events.rs) read the definitions in
/// tests/fixtures/road/generated/. They must be what the app makes now: when this fails, run `dart run tool/road_defs_fixtures.dart`.
void main() {
  test('the definitions the core tests read are the ones the app makes', () {
    final f = RoadSourcesFile.parse(File('assets/roads/road_sources.json').readAsStringSync());
    for (final e in roadFixtures(f).entries) {
      final file = File('$kFixtureDir/${e.key}');
      expect(file.existsSync(), isTrue, reason: e.key);
      expect(file.readAsStringSync(), e.value, reason: '${e.key} is stale');
    }
  });
}

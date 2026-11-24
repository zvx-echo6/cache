// Writes the road source definitions the app makes to the core's test fixtures (see lib/roads/road_fixtures.dart).
// A Dart test (test/road_defs_fixtures_test.dart) fails when the files there are not what this makes.
//
// Run from app/: dart run tool/road_defs_fixtures.dart

import 'dart:io';

import 'package:cache/roads/road_fixtures.dart';
import 'package:cache/roads/road_sources.dart';

void main() {
  final f = RoadSourcesFile.parse(File('assets/roads/road_sources.json').readAsStringSync());
  final dir = Directory(kFixtureDir)..createSync(recursive: true);
  for (final e in roadFixtures(f).entries) {
    File('${dir.path}/${e.key}').writeAsStringSync(e.value);
  }
  stdout.writeln('wrote ${roadFixtures(f).length} definitions to ${dir.path}');
}

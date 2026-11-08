import 'dart:convert';
import 'dart:io';

import 'package:cache/discover/recipe.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live sources Cache's connector catalogue offers (data.cached.info/connectors/catalogue.json, 2026-11-03) and the built-in
/// ones: a recipe may name only these.
const _knownSources = {
  'nws-alerts-point', 'ipaws-alerts-near', 'avalanche-forecast-zones', 'usgs-quakes-day-m25', 'usgs-quakes-near', 'firms-viirs-near',
  'wfigs-incidents-near', 'wfigs-perimeters-near', 'nwps-gauge-forecast', 'nwps-gauges-near', 'usgs-water-idaho', 'idaho511-events',
  'idaho511-winter-roads', 'wzdx-idaho', 'swpc-alerts', 'swpc-f107', 'swpc-kp', 'swpc-scales', 'tomtom-flow-point',
  'nws-forecast-point', 'nws-observations-latest', 'openmeteo-forecast', 'weather', 'alerts',
};

void main() {
  final text = File('assets/discover/catalogue.json').readAsStringSync();

  test('the copy in the app is the file in the repository', () {
    expect(text, File('../docs/discover-catalogue.json').readAsStringSync());
  });

  group("Cache's own file", () {
    final c = DiscoverCatalogue.parse(text);

    test('reads, with its activities and collections', () {
      expect(c.activities.map((a) => a.id), ['ready', 'backcountry', 'homestead']);
      expect(c.collections.map((x) => x.id), ['preparedness', 'medical-repair']);
      expect(c.libraries, isNotEmpty);
    });

    test('names only items Cache already offers: live sources of the catalogue, the starter logs and templates of the app', () {
      final starters = (jsonDecode(File('assets/notebook/starters.json').readAsStringSync())['templates'] as List).map((t) => t['id']).toSet();
      final templates = (jsonDecode(File('assets/notebook/templates.json').readAsStringSync())['templates'] as List).map((t) => t['id']).toSet();
      for (final a in c.activities) {
        for (final i in a.items) {
          switch (i.kind) {
            case ItemKind.liveSource:
              expect(_knownSources, contains(i.id), reason: '${a.id}: ${i.id}');
            case ItemKind.notebook:
              expect({...starters, ...templates}, contains(i.id), reason: '${a.id}: ${i.id}');
            case ItemKind.library:
              expect(i.name, isNotEmpty);
              expect(i.approxBytes, greaterThan(0), reason: '${a.id}: ${i.name} has a size for offline');
            case ItemKind.mapRegion:
              expect(kRegionParts.containsAll(i.parts), isTrue);
            case ItemKind.checklist || ItemKind.askStarters:
              fail('${a.id}: Cache ships no checklists or starter questions yet (they need the owner\'s approval)');
          }
        }
      }
    });
  });

  group('the format', () {
    Map<String, dynamic> file({int version = 1, List<Map<String, dynamic>>? items, List<Map<String, dynamic>> settings = const []}) => {
      'format': 'cache-discover',
      'version': version,
      'updated': '2026-11-08',
      'activities': [
        {'id': 'a', 'title': 'A', 'items': items ?? [{'kind': 'library', 'name': 'x'}], 'settings': settings},
      ],
    };

    test('refuses another format and a newer version', () {
      expect(() => DiscoverCatalogue.parse('{"format":"other","version":1}'), throwsA(isA<RecipeException>()));
      expect(() => DiscoverCatalogue.parse(jsonEncode(file(version: kDiscoverVersion + 1))), throwsA(isA<RecipeException>()));
      expect(() => DiscoverCatalogue.parse('not json'), throwsA(isA<RecipeException>()));
    });

    test('refuses a kind it does not know, an item listed twice and a setting it cannot put back', () {
      expect(() => DiscoverCatalogue.parse(jsonEncode(file(items: [{'kind': 'module', 'id': 'x'}]))), throwsA(isA<RecipeException>()));
      expect(() => DiscoverCatalogue.parse(jsonEncode(file(items: [{'kind': 'library', 'name': 'x'}, {'kind': 'library', 'name': 'x'}]))), throwsA(isA<RecipeException>()));
      expect(() => DiscoverCatalogue.parse(jsonEncode(file(settings: [{'key': 'theme', 'value': true}]))), throwsA(isA<RecipeException>()));
    });

    test('reads checklists and starter questions (none ship yet)', () {
      final c = DiscoverCatalogue.parse(jsonEncode(file(items: [
        {'kind': 'checklist', 'id': 'trip-plan', 'title': 'Trip plan', 'lines': ['Route left with someone', 'Water']},
        {'kind': 'ask_starters', 'id': 'trip', 'lines': ['What should I pack?']},
      ])));
      final items = c.activities.single.items;
      expect(items.map((i) => i.key), ['checklist:trip-plan', 'ask:trip']);
      expect(items.first.lines, hasLength(2));
      expect(() => DiscoverCatalogue.parse(jsonEncode(file(items: [{'kind': 'checklist', 'id': 'x', 'lines': ['a']}]))), throwsA(isA<RecipeException>()),
          reason: 'a checklist needs a title');
    });

    test('an item round-trips through JSON', () {
      final i = RecipeItem.fromJson({'kind': 'map_region', 'parts': ['routing', 'map'], 'title': 'Area'});
      expect(RecipeItem.fromJson(i.toJson()).toJson(), i.toJson());
    });
  });
}

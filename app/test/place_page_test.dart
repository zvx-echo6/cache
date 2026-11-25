// The setup wizard's "Choose a place": a new person has no regions and often no position, so the search reads the country list the
// query or the device's locale points to, and finds towns that the global list does not hold. Every name here is made up or a plain
// place name from the test catalogue.

import 'dart:convert';
import 'dart:io';

import 'package:cache/discover/ui/place_page.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/regions_fake.dart';

Future<RegionCatalogue> _catalogue(Directory dir) async {
  final web = regionWeb();
  // The US list also holds Hilo (in Hawaii); the global list has the state of Hawaii but not Hilo or Twin Falls.
  final us = (jsonDecode(File('test/fixtures/regions_us.search.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
  us.add({'id': 'us-hi-hilo', 'name': 'Hilo', 'kind': 'locality', 'in': 'Hawaii County, Hawaii', 'pop': 45000});
  us.add({'id': 'us-hi', 'name': 'Hawaii', 'kind': 'region', 'in': 'United States'});
  web.files['${kRegionCatalogueBase}us.search.json'] = utf8.encode(jsonEncode(us));
  final global = (jsonDecode(File('test/fixtures/regions_search_global.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
  global.add({'id': 'us-hi', 'name': 'Hawaii', 'kind': 'region', 'in': 'United States', 'shard': 'us'});
  web.files['${kRegionCatalogueBase}search-global.json'] = utf8.encode(jsonEncode(global));
  return RegionCatalogue(dir: () async => dir, fetch: web.fetch);
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('discover-search')), text);
  await tester.pump(const Duration(milliseconds: 300));
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('place-page'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester, RegionCatalogue c, {String? locale}) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: PlacePage(catalogue: c, localeCountry: locale)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  testWidgets('a fresh setup (no regions, no position, locale US): "Twin Falls" finds the town', (tester) async {
    final c = await _catalogue(dir);
    await show(tester, c, locale: 'US');
    await _search(tester, 'Twin Falls');
    expect(find.byKey(const ValueKey('place-us-id-twin-falls')), findsOneWidget);
    expect(c.loadedShards, isEmpty, reason: 'the list was read for the search, not as a whole shard');
  });

  testWidgets('"Hilo Hawaii" finds Hilo: the state named in the query points to the list, and the word may be the place it is in', (tester) async {
    final c = await _catalogue(dir);
    await show(tester, c, locale: '');
    await _search(tester, 'Hilo Hawaii');
    expect(find.byKey(const ValueKey('place-us-hi-hilo')), findsOneWidget);
  });

  testWidgets('with no locale country and no word that names one, only the global list is searched (no guess)', (tester) async {
    final c = await _catalogue(dir);
    await show(tester, c, locale: '');
    await _search(tester, 'Twin Falls');
    expect(find.byKey(const ValueKey('place-us-id-twin-falls')), findsNothing);
  });
}

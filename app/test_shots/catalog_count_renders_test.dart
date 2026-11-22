// Catalog with two libraries of books of different sizes, each row showing its own count (a phone, 390 x 844, light).
// flutter test test_shots/catalog_count_renders_test.dart --update-goldens  (picture in test_shots/catalog-count/)

import 'package:cache/library/catalog_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

import '../test/library/catalog_count_world.dart';
import '../test/library/library_fixtures.dart' show testDeps;
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('Catalog: each library its own count', (tester) async {
    phone(tester, size: const Size(390, 844), ratio: 2);
    final w = CatalogCountWorld();
    await tester.runAsync(w.make);
    addTearDown(w.dispose);
    await tester.pumpWidget(shotApp(CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves)), theme: CacheThemeId.light));
    await tester.pump();
    await snap(tester, 'catalog-count', '390-catalog-light');
  });
}

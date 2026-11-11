import 'package:cache/library/catalog_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_count_world.dart';
import 'library_fixtures.dart';

void main() {
  testWidgets('each Books library in Catalog shows its own book count, shelved or not', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final w = CatalogCountWorld();
    await tester.runAsync(w.make);
    addTearDown(w.dispose);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves))));
    await tester.pump();
    expect(find.text('Ready · 7 books'), findsOneWidget, reason: 'Recon: 7 books, none shelved');
    expect(find.text('Ready · 3 books'), findsOneWidget, reason: 'Field: 3 books, 2 shelved');
    expect(find.text('Ready · 2 books'), findsNothing, reason: 'not the count of shelved books');
  });
}

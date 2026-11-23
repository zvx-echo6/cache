// In a browser the Catalog's Pause all shows while the server has any index work: helper index jobs (serverIndexBusy) or a server
// library build (serverIndex.busy). plat.isWeb is a compile-time constant, so the page takes a debugWeb override.
import 'package:cache/library/catalog_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_count_world.dart';
import 'library_fixtures.dart';

void main() {
  Future<CatalogCountWorld> open(WidgetTester tester, {required bool helperBusy, required bool buildBusy, bool web = true}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final w = CatalogCountWorld();
    await tester.runAsync(w.make);
    addTearDown(w.dispose);
    w.sources.serverIndexBusy = helperBusy;
    if (buildBusy) {
      w.sources.serverIndex.update({'items': [{'key': 'library/trail', 'state': 'running', 'done': 1, 'total': 7}], 'done': 1, 'total': 7});
    }
    expect(w.sources.serverIndex.busy, buildBusy);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(debugWeb: web, deps: testDeps(browse: w.browse, shelves: w.shelves))));
    await tester.pump();
    return w;
  }

  testWidgets('browser: a server library build alone shows Pause all', (tester) async {
    await open(tester, helperBusy: false, buildBusy: true);
    expect(find.byKey(const ValueKey('catalog-pause-all')), findsOneWidget);
    expect(find.textContaining("Pause and Resume are also on the Library's indexing line."), findsOneWidget);
  });

  testWidgets('browser: helper index work alone still shows Pause all', (tester) async {
    await open(tester, helperBusy: true, buildBusy: false);
    expect(find.byKey(const ValueKey('catalog-pause-all')), findsOneWidget);
  });

  testWidgets('browser: no server work shows neither Pause all nor Resume', (tester) async {
    await open(tester, helperBusy: false, buildBusy: false);
    expect(find.byKey(const ValueKey('catalog-pause-all')), findsNothing);
    expect(find.byKey(const ValueKey('catalog-resume-all')), findsNothing);
  });

  testWidgets('phone: server build state does not add the browser button', (tester) async {
    await open(tester, helperBusy: false, buildBusy: true, web: false);
    expect(find.textContaining('Pause, resume and fixes live here.'), findsOneWidget);
    expect(find.textContaining("Pause and Resume are also on"), findsNothing);
  });
}

import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Widget app(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: child);

void main() {
  late Directory tmp;
  late FakeSources sources;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('screens');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  BrowseState make(Future<String> Function(Uri) fetch) => BrowseState(
        sources: sources,
        catalog: catalogWith(fetch),
        policy: testPolicy(),
        settingsDirOverride: Directory('${tmp.path}/s')..createSync(),
        phoneLanguage: 'en',
      );

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(4000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the catalogue shows title, description, language, size and date, and the category chips', (tester) async {
    wide(tester);
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(CatalogueScreen(browse: b)));
    await tester.pumpAndSettle();
    expect(find.text('Wikivoyage - Europe'), findsNWidgets(2));
    expect(find.text('Selection of Europe destinations from Wikivoyage'), findsNWidgets(2));
    expect(find.textContaining('Full · eng · 367 MB · 2026-09-14'), findsOneWidget);
    expect(find.textContaining('No pictures · eng · 79.7 MB'), findsOneWidget);
    expect(find.text('Download · 367 MB'), findsOneWidget);
    expect(find.text('English'), findsOneWidget); // language chip
    expect(find.text('Stack Exchange'), findsOneWidget);
    expect(find.text('Wikipedia'), findsOneWidget);
    expect(find.text('Medicine'), findsOneWidget);
  });

  testWidgets('choosing a category asks the catalogue for it', (tester) async {
    wide(tester);
    final asked = <Uri>[];
    final b = make((u) {
      asked.add(u);
      return recorded(u);
    });
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(CatalogueScreen(browse: b)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wikipedia'));
    await tester.pumpAndSettle();
    expect(asked.last.queryParameters['category'], 'wikipedia');
    expect(asked.last.queryParameters['lang'], 'eng');
  });

  testWidgets('an installed entry says so instead of offering Download', (tester) async {
    File('${sources.zimsDir!.path}/wikivoyage_en_europe_maxi_2026-09.zim').writeAsBytesSync([0]);
    await sources.refresh();
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(CatalogueScreen(browse: b)));
    await tester.pumpAndSettle();
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.textContaining('Download ·'), findsOneWidget); // the other variant
  });

  testWidgets('the Browse tab lists ZIMs by their real title, not the file name, and offers the update', (tester) async {
    File('${sources.zimsDir!.path}/wikivoyage_en_europe_maxi_2026-03.zim').writeAsBytesSync(List.filled(2048, 0));
    await sources.refresh();
    final f = File(sources.zims.single.path);
    sources.titles[f.path] = 'Wikivoyage Europe';
    sources.ids[f.path] = '17e9fb54-9554-d2cd-e15f-17cf750882d1';
    sources.ready.add(f.path);
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(BrowseScreen(browse: b, active: true)));
    await tester.pumpAndSettle();
    expect(find.text('Wikivoyage Europe'), findsOneWidget);
    expect(find.textContaining('wikivoyage_en_europe_maxi'), findsNothing);
    expect(find.text('1 update available · 367 MB'), findsOneWidget);
    expect(find.textContaining('Update to 2026-09'), findsOneWidget);
    expect(find.text('Get more from the Kiwix library'), findsOneWidget);
  });

  testWidgets('with nothing installed the Browse tab explains and points to the library', (tester) async {
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(BrowseScreen(browse: b, active: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('No ZIMs on this phone yet'), findsOneWidget);
  });
}

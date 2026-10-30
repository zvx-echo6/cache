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

  testWidgets('Add to Library: your own library first, then each collection with its name, description and size, and its own download button', (tester) async {
    wide(tester);
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(AddToLibraryScreen(browse: b)));
    await tester.pumpAndSettle();
    expect(find.text('Add to Library'), findsOneWidget);
    expect(find.text('READY-MADE COLLECTIONS · FREE FROM KIWIX'), findsOneWidget);
    expect(find.text('Wikivoyage - Europe'), findsNWidgets(2));
    expect(find.text('Selection of Europe destinations from Wikivoyage · 367 MB'), findsOneWidget);
    expect(find.text('Selection of Europe destinations from Wikivoyage · 79.7 MB'), findsOneWidget);
    expect(find.byTooltip('Download Wikivoyage - Europe'), findsNWidgets(2));
    expect(find.text('English'), findsOneWidget); // language chip
    expect(find.text('Stack Exchange'), findsOneWidget);
    expect(find.text('Medicine'), findsOneWidget);
  });

  testWidgets('a collection\'s download button opens the download pop-up with its size and the storage after', (tester) async {
    wide(tester);
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(AddToLibraryScreen(browse: b)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download Wikivoyage - Europe').first);
    await tester.pumpAndSettle();
    expect(find.text('Download Wikivoyage - Europe?'), findsOneWidget);
    expect(find.textContaining('Selection of Europe destinations'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(b.transfers, isEmpty, reason: 'Cancel starts nothing');
  });

  testWidgets('choosing a category asks the catalogue for it', (tester) async {
    wide(tester);
    final asked = <Uri>[];
    final b = make((u) {
      asked.add(u);
      return recorded(u);
    });
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(AddToLibraryScreen(browse: b)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wikipedia'));
    await tester.pumpAndSettle();
    expect(asked.last.queryParameters['category'], 'wikipedia');
    expect(asked.last.queryParameters['lang'], 'eng');
  });

  testWidgets('an installed entry says "On this phone" instead of a download button', (tester) async {
    File('${sources.zimsDir!.path}/wikivoyage_en_europe_maxi_2026-09.zim').writeAsBytesSync([0]);
    await sources.refresh();
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(AddToLibraryScreen(browse: b)));
    await tester.pumpAndSettle();
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.byTooltip('Download Wikivoyage - Europe'), findsOneWidget); // the other variant
  });

  testWidgets('the Library lists ZIMs by their real title in one line, with an "Update ready" badge only for the exception', (tester) async {
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
    expect(find.text('Update ready'), findsOneWidget);
    expect(find.text('Ready'), findsNothing, reason: 'no badge for the ordinary state');
    expect(find.text('Add to Library'), findsOneWidget);
    expect(find.text('Get more from the Kiwix library'), findsNothing);
    // Tapping the badge offers the update in the download pop-up.
    await tester.tap(find.text('Update ready'));
    await tester.pumpAndSettle();
    expect(find.text('Update Wikivoyage - Europe?'), findsOneWidget);
  });

  testWidgets('press and hold opens the one menu; Delete asks first with what it frees', (tester) async {
    File('${sources.zimsDir!.path}/wikivoyage_en_europe_maxi_2026-03.zim').writeAsBytesSync(List.filled(2048, 0));
    await sources.refresh();
    final f = File(sources.zims.single.path);
    sources.titles[f.path] = 'Wikivoyage Europe';
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(BrowseScreen(browse: b, active: true)));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Wikivoyage Europe'));
    await tester.pumpAndSettle();
    expect(find.text('Check for update'), findsOneWidget);
    expect(find.text('Change icon'), findsOneWidget);
    expect(find.text('Delete · frees 2 KB'), findsOneWidget);
    await tester.tap(find.text('Delete · frees 2 KB'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Wikivoyage Europe?'), findsOneWidget);
    expect(find.text('You can download it again later.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sources.zims, hasLength(1), reason: 'nothing deleted');
    await tester.longPress(find.text('Wikivoyage Europe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete · frees 2 KB'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(sources.zims, isEmpty);
  });

  testWidgets('with nothing installed the Library explains and offers Add to Library', (tester) async {
    final b = make(recorded);
    await tester.runAsync(b.init);
    await tester.pumpWidget(app(BrowseScreen(browse: b, active: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-empty')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-to-library')));
    await tester.pumpAndSettle();
    expect(find.byType(AddToLibraryScreen), findsOneWidget);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/book_pages.dart';
import 'package:cache/library/catalog_page.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_docs_page.dart';
import 'package:cache/library/shelf_source.dart' show DocPlace;
import 'package:cache/pdf/pdf_reader_screen.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart' show testPolicy;
import 'catalog_count_world.dart' show ReadyLibrarySources;
import 'fake_shelves.dart';
import 'library_fixtures.dart';

/// Catalog -> a library's books: Field library holds 8 documents: three shelved, one Unsorted, one Hidden, one of two files that
/// are one book (the other file is in Trail library), and two the library lists that Bookshelves has no copy for ("On no shelf":
/// no pack). Trail library holds only that book's second file. Homestead library holds one book of 8 files. Waiting library holds nothing.
class _World {
  late Directory tmp;
  late ReadyLibrarySources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;

  Future<void> make() async {
    tmp = Directory.systemTemp.createTempSync('catalog-library-docs-test');
    final root = Directory('${tmp.path}/libraries');
    writeBookLibrary(
      root,
      'field',
      const [
        ('a1', 'Wilderness first aid handbook', '210', null),
        ('a2', 'The water purification handbook', '530', null),
        ('a3', 'Map and compass', '870', null),
        ('b1', 'Where there is no doctor', '210', null),
        ('u1', 'Small engine repair', null, null),
        ('h1', 'Old seed catalogue', '310', null),
      ],
      pdfs: {'n1'},
    );
    final tsv = File('${root.path}/field/documents.tsv');
    tsv.writeAsStringSync('${tsv.readAsStringSync()}n1\t1\tRoadside emergency repairs\t${sampleHash('n1')}\t10\t88\nn2\t1\tScanned field notes, 1987\t${sampleHash('n2')}\t10\t40\n');
    writeBookLibrary(root, 'trail', const [('b2', 'Where there is no doctor', '210', null)]);
    writeBookLibrary(root, 'homestead', [for (var i = 1; i <= 8; i++) ('hs$i', 'Homestead field notes', i == 1 ? '250' : null, null)]);
    Directory('${root.path}/empty/shard').createSync(recursive: true);
    File('${root.path}/empty/documents.tsv').writeAsStringSync('doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n');
    for (final (id, title) in [('field', 'Field library'), ('trail', 'Trail library'), ('homestead', 'Homestead library'), ('empty', 'Waiting library')]) {
      File('${root.path}/$id/cache-library.json').writeAsStringSync('{"format":1,"library_id":"$id","title":"$title","version":"1"}');
    }
    sources = ReadyLibrarySources(Directory('${tmp.path}/zims')..createSync(recursive: true))
      ..titles0['field'] = 'Field library'
      ..titles0['trail'] = 'Trail library'
      ..titles0['homestead'] = 'Homestead library'
      ..titles0['empty'] = 'Waiting library';
    libs = await librariesAt(root, sources);
    final dir = writeShelves(
      Directory('${tmp.path}/bookshelves'),
      placed: const [('a1', '210', 1), ('a2', '530', 1), ('a3', '870', 1), ('b1', '210', 2), ('h1', '310', 1), ('hs1', '250', 1)],
      checked: const ['a1', 'a2', 'a3', 'b1', 'b2', 'u1', 'h1', 'hs1', 'hs2', 'hs3', 'hs4', 'hs5', 'hs6', 'hs7', 'hs8'],
    );
    File('${dir.path}/log/tablet.jsonl').writeAsStringSync(
      [
        {'v': 1, 'at': 2000, 'dev': 'tablet', 'ev': 'remove', 'copy': 'h1'},
        {'v': 1, 'at': 2001, 'dev': 'tablet', 'ev': 'same', 'copy': 'b1', 'with': 'b2', 'by': 'user'},
        for (var i = 2; i <= 8; i++) {'v': 1, 'at': 2002 + i, 'dev': 'tablet', 'ev': 'same', 'copy': 'hs1', 'with': 'hs$i', 'by': 'user'},
      ].map((e) => '${jsonEncode(e)}\n').join(),
      mode: FileMode.append,
    );
    shelves = CdsShelfSource(libs, calls: FakeShelvesCalls(), bookshelvesDir: () async => dir, deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
  }

  LibraryItem library(String title) => libs.libraries.firstWhere((l) => libs.titleOf(l) == title);

  void dispose() {
    shelves.dispose();
    browse.dispose();
    libs.dispose();
    sources.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  late _World w;

  Future<void> pumpWorld(WidgetTester tester, Widget Function(_World w) page) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    w = _World();
    await tester.runAsync(w.make);
    addTearDown(w.dispose);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page(w)));
    await tester.pump();
  }

  Future<void> openField(WidgetTester tester) => pumpWorld(tester, (w) => LibraryDocsPage(deps: testDeps(browse: w.browse, shelves: w.shelves), library: w.library('Field library')));

  testWidgets('tapping a library of books in Catalog opens its books', (tester) async {
    await pumpWorld(tester, (w) => CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves)));
    expect(find.byType(LibraryDocsPage), findsNothing);
    await tester.tap(find.text('Field library'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryDocsPage), findsOneWidget);
    expect(find.byKey(const ValueKey('doc-a1')), findsOneWidget);
  });

  testWidgets('a row that opens something shows a chevron; with no way to list the documents the row does not', (tester) async {
    await pumpWorld(tester, (w) => CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves)));
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(4), reason: 'the four libraries of books');
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves, docs: false))));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('sections and counts: the unshelved ones first, then the books on Bookshelves, each with its place', (tester) async {
    await openField(tester);
    expect(find.text('ON NO SHELF · 2'), findsOneWidget);
    expect(find.text('ON BOOKSHELVES · 6'), findsOneWidget);
    // the unshelved section sits above the shelved one
    expect(tester.getTopLeft(find.text('ON NO SHELF · 2')).dy, lessThan(tester.getTopLeft(find.text('ON BOOKSHELVES · 6')).dy));
    expect(tester.getTopLeft(find.byKey(const ValueKey('doc-n1'))).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('doc-a1'))).dy));
    expect(find.text('CDS 210-001 · First aid and emergency care'), findsOneWidget);
    expect(find.text('CDS 530-001 · Water treatment'), findsOneWidget);
    expect(find.text('Unsorted'), findsOneWidget);
    expect(find.text('Hidden'), findsOneWidget);
    expect(find.text('Old seed catalogue'), findsOneWidget, reason: 'a hidden book is listed');
  });

  testWidgets('On no shelf: the two documents Bookshelves has no book for, with the note, and nothing for a library that has none', (tester) async {
    await openField(tester);
    expect(find.text('Roadside emergency repairs'), findsOneWidget);
    expect(find.text('Scanned field notes, 1987'), findsOneWidget);
    expect(find.text('On no shelf'), findsNWidgets(2));
    expect(find.text('These books are in this library, but not on your Bookshelves.'), findsOneWidget);
    expect(find.textContaining('Tap one'), findsNothing);
    expect(w.shelves.documentsIn(w.library('Field library')).where((d) => d.place == DocPlace.none).length, 2);
    // Trail library has no such document: no section, no second label
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: LibraryDocsPage(deps: testDeps(browse: w.browse, shelves: w.shelves), library: w.library('Trail library'))));
    await tester.pump();
    expect(find.textContaining('ON NO SHELF'), findsNothing);
    expect(find.textContaining('ON BOOKSHELVES'), findsNothing);
    expect(find.text('Where there is no doctor'), findsOneWidget);
  });

  testWidgets('copies: "2 copies" on its own line for a book with two files, and only there', (tester) async {
    await openField(tester);
    expect(find.text('2 copies'), findsOneWidget);
    expect(find.byKey(const ValueKey('doc-copies-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('doc-copies-a1')), findsNothing);
    // its shelf line is not shared with the copies
    expect(find.text('CDS 210-002 · First aid and emergency care'), findsOneWidget);
    expect(find.textContaining('· 2 copies'), findsNothing);
  });

  testWidgets('tapping a book opens its book page', (tester) async {
    await openField(tester);
    await tester.tap(find.byKey(const ValueKey('doc-a1')));
    await tester.pumpAndSettle();
    expect(find.byType(BookPage), findsOneWidget);
  });

  testWidgets('tapping a document on no shelf opens its PDF when it is on this device', (tester) async {
    await openField(tester);
    expect(find.text('Opens the PDF'), findsOneWidget, reason: 'n1 has its PDF here; n2 has none');
    await tester.tap(find.byKey(const ValueKey('doc-n1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PdfReaderScreen), findsOneWidget);
    expect(find.byType(BookPage), findsNothing);
  });

  testWidgets('tapping a document on no shelf with no PDF here says so', (tester) async {
    await openField(tester);
    expect(find.text('Not on this device'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('doc-n2')));
    await tester.pump();
    expect(find.text('This book is not on your shelves, and its PDF is not on this device.'), findsOneWidget);
    expect(find.byType(PdfReaderScreen), findsNothing);
  });

  testWidgets('a library with no books says so in plain words', (tester) async {
    await pumpWorld(tester, (w) => LibraryDocsPage(deps: testDeps(browse: w.browse, shelves: w.shelves), library: w.library('Waiting library')));
    expect(find.text('No books in this library yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-docs-none-note')), findsNothing);
  });

  testWidgets('a book of 8 files is one row with "8 copies", and the counts are in books, in the list and in Catalog', (tester) async {
    await pumpWorld(tester, (w) => LibraryDocsPage(deps: testDeps(browse: w.browse, shelves: w.shelves), library: w.library('Homestead library')));
    expect(find.text('Homestead field notes'), findsOneWidget, reason: 'one row for the book, not one for each file');
    expect(find.text('8 copies'), findsOneWidget);
    expect(find.text('CDS 250-001 · Herbal and traditional medicine'), findsOneWidget);
    expect(w.shelves.documentsIn(w.library('Homestead library')).length, 1);
    expect(w.shelves.booksIn(w.library('Homestead library')), 1);
    // Catalog says the same: 1 book, not 8
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves))));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('catalog-library/homestead')), matching: find.text('Ready · 1 book')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('catalog-library/field')), matching: find.text('Ready · 8 books')), findsOneWidget, reason: 'the number of rows in its list');
  });
}

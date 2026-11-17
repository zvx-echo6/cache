// Catalog -> a library's books (board: catalog-library-row), for review: the Catalog's "Your books" rows before (nothing to tap) and
// after (a chevron, tappable), and the page a tap opens: shelved books, Unsorted, Hidden, a book with 2 copies, a long title, and
// two documents On no shelf (in the library, but Bookshelves resolves them to no book), listed first. A phone (390 x 844) and the
// Linux desktop window (1440 x 900), light. All sample data.
// flutter test test_shots/catalog_library_docs_renders_test.dart --update-goldens  (pictures in test_shots/catalog-library-docs/)

import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/catalog_page.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_docs_page.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart' show EdgeInsets, Size, Widget;
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show testPolicy;
import '../test/library/catalog_count_world.dart' show ReadyLibrarySources;
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart';
import 'shot_kit.dart';

const _out = 'catalog-library-docs';

const String _longTitle = 'The Complete Illustrated Guide to Backcountry Navigation, Map Reading, Compass Use and Route Finding for Hikers, Hunters and Search and Rescue Volunteers';

class _World {
  late Directory tmp;
  late ReadyLibrarySources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;

  Future<void> make() async {
    tmp = Directory.systemTemp.createTempSync('catalog-library-docs');
    final root = Directory('${tmp.path}/libraries');
    writeBookLibrary(root, 'field', const [
      ('a1', 'Wilderness first aid handbook', '210', null),
      ('a2', 'The water purification handbook', '530', null),
      ('a3', _longTitle, '870', null),
      ('b1', 'Where there is no doctor', '210', null),
      ('u1', 'Small engine repair', null, null),
      ('h1', 'Old seed catalogue', '310', null),
    ]);
    // two documents the library lists that Bookshelves has no copy for (no pack): the case behind a count that differs from Bookshelves
    final tsv = File('${root.path}/field/documents.tsv');
    tsv.writeAsStringSync('${tsv.readAsStringSync()}n1\t1\tRoadside emergency repairs\t${sampleHash('n1')}\t10\t88\nn2\t1\tScanned field notes, 1987\t${sampleHash('n2')}\t10\t40\n');
    writeBookLibrary(root, 'trail', const [('b2', 'Where there is no doctor', '210', null)]);
    Directory('${root.path}/empty/shard').createSync(recursive: true);
    File('${root.path}/empty/documents.tsv').writeAsStringSync('doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n');
    for (final (id, title) in [('field', 'Field library'), ('trail', 'Trail library'), ('empty', 'Waiting library')]) {
      File('${root.path}/$id/cache-library.json').writeAsStringSync('{"format":1,"library_id":"$id","title":"$title","version":"1"}');
    }
    sources = ReadyLibrarySources(Directory('${tmp.path}/zims')..createSync(recursive: true))
      ..titles0['field'] = 'Field library'
      ..titles0['trail'] = 'Trail library'
      ..titles0['empty'] = 'Waiting library';
    libs = await librariesAt(root, sources);
    final dir = writeShelves(
      Directory('${tmp.path}/bookshelves'),
      placed: const [('a1', '210', 1), ('a2', '530', 1), ('a3', '870', 1), ('b1', '210', 2), ('h1', '310', 1)],
      checked: const ['a1', 'a2', 'a3', 'b1', 'b2', 'u1', 'h1'],
    );
    // the person hid one book, and said the two files of "Where there is no doctor" are one book
    File('${dir.path}/log/tablet.jsonl').writeAsStringSync(
      [
        {'v': 1, 'at': 2000, 'dev': 'tablet', 'ev': 'remove', 'copy': 'h1'},
        {'v': 1, 'at': 2001, 'dev': 'tablet', 'ev': 'same', 'copy': 'b1', 'with': 'b2', 'by': 'user'},
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
  setUpAll(loadShotFonts);

  const sizes = {'390': Size(390, 844), '1440': Size(1440, 900)};
  for (final e in sizes.entries) {
    testWidgets('Catalog library books at ${e.key}', (tester) async {
      phone(tester, size: e.value, ratio: e.key == '390' ? 2 : 1);
      final desktop = e.key == '1440';
      final w = _World();
      await tester.runAsync(w.make);
      addTearDown(w.dispose);
      final insets = desktop ? EdgeInsets.zero : null;
      Widget app(Widget page) => shotApp(page, theme: CacheThemeId.light, desktop: desktop, insets: insets);

      // the Catalog's rows before (nothing to tap) and after (a chevron: tap to open the library's books)
      await tester.pumpWidget(app(CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves, docs: false))));
      await tester.pump();
      await snap(tester, _out, '${e.key}-catalog-before-light');
      await tester.pumpWidget(app(CatalogPage(deps: testDeps(browse: w.browse, shelves: w.shelves))));
      await tester.pump();
      await snap(tester, _out, '${e.key}-catalog-after-light');

      // the library's books
      await tester.pumpWidget(app(LibraryDocsPage(deps: testDeps(browse: w.browse, shelves: w.shelves), library: w.library('Field library'))));
      await tester.pump();
      await snap(tester, _out, '${e.key}-library-books-light');

      if (!desktop) {
        await tester.pumpWidget(app(LibraryDocsPage(deps: testDeps(browse: w.browse, shelves: w.shelves), library: w.library('Waiting library'))));
        await tester.pump();
        await snap(tester, _out, '${e.key}-library-books-empty-light');
      }
    });
  }
}

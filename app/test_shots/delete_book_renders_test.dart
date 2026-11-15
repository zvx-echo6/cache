// Delete on a Book page (owner's design, 2026-11-15): one "Delete" button on the book page; it always asks "Delete this book?" with
// Cancel and Delete, and, when the book is synced with another device, the line "Deleting this will delete this from all synced
// devices.". 390 wide, light. Sample data: the library tests' own fixtures.
// flutter test test_shots/delete_book_renders_test.dart --update-goldens  (pictures in test_shots/delete_book_v2/)
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart';
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  const folder = 'delete_book_v2';

  Future<void> bookPage(WidgetTester tester, {required bool synced, required List<String> pictures, bool tapDelete = true}) async {
    phone(tester, size: const Size(390, 844), ratio: 2);
    Directory? tmp;
    FakeSources? sources;
    LibrariesState? libs;
    CdsShelfSource? shelves;
    BrowseState? browse;
    addTearDown(() {
      shelves?.dispose();
      browse?.dispose();
      libs?.dispose();
      sources?.dispose();
      indexSchedulerShared = null;
      try {
        tmp?.deleteSync(recursive: true);
      } catch (_) {}
    });
    await tester.runAsync(() async {
      tmp = Directory.systemTemp.createTempSync('delete-shot');
      writeBookLibrary(Directory('${tmp!.path}/libraries'), 'my-books', const [
        ('water', 'The water purification handbook', '530', null),
        ('aid', 'Wilderness first aid', '210', null),
      ], pdfs: {'water'}, own: true);
      sources = FakeSources(Directory('${tmp!.path}/zims')..createSync(recursive: true));
      libs = await librariesAt(Directory('${tmp!.path}/libraries'), sources!);
      shelves = CdsShelfSource(libs!, calls: FakeShelvesCalls(), bookshelvesDir: () async => Directory('${tmp!.path}/bookshelves'), deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
      await shelves!.whenRead();
      browse = BrowseState(sources: sources!, libraries: libs!, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    });
    final files = FakeBookFiles(remove: false)..synced = synced;
    await tester.pumpWidget(shotApp(LibraryPanes(
      root: (_) => LibraryRootPage(deps: testDeps(browse: browse!, shelves: shelves!, files: files)),
      prefs: PanePrefs(dirOverride: tmp!),
    )));
    await tester.pumpAndSettle();
    Future<void> tap(String key) async {
      final f = find.byKey(ValueKey(key));
      await tester.ensureVisible(f.first);
      await tester.tap(f.first);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    for (final k in ['library-bookshelves', 'shelf-500', 'shelf-530', 'book-water']) {
      await tap(k);
    }
    if (pictures.contains('page')) await snap(tester, folder, '1-book-page');
    if (pictures.contains('dialog')) {
      await tap('book-delete');
      await snap(tester, folder, synced ? '2-confirm-synced' : '3-confirm-not-synced');
    }
  }

  testWidgets('1. the book page, with the Delete button', (tester) async {
    await bookPage(tester, synced: false, pictures: ['page']);
  });
  testWidgets('2. the confirmation, synced', (tester) async {
    await bookPage(tester, synced: true, pictures: ['dialog']);
  });
  testWidgets('3. the confirmation, not synced', (tester) async {
    await bookPage(tester, synced: false, pictures: ['dialog']);
  });
}

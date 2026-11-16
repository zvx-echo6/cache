// The Move sheet of a filed book, before and after the "Unsorted" row (390 wide, light). The sample is the library tests' own fixture.
// flutter test test_shots/move_unsorted_renders_test.dart --update-goldens --dart-define=NAME=after  (picture in test_shots/move_unsorted/)
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
  const folder = 'move_unsorted';
  const name = String.fromEnvironment('NAME', defaultValue: 'after');

  testWidgets('the Move sheet of a filed book', (tester) async {
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
      tmp = Directory.systemTemp.createTempSync('move-shot');
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
    final files = FakeBookFiles(remove: false);
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

    for (final k in ['library-bookshelves', 'shelf-500', 'shelf-530', 'book-water', 'book-move']) {
      await tap(k);
    }
    await snap(tester, folder, name);
  });
}

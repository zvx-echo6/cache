// "Everything that points to something links to it": one test per link of the sweep. Each taps the words and expects the page
// (or the call) they name. The Library ones (6 to 14) are here; the Notebooks and Places ones are in links_sweep_notebooks_test.dart.

import 'dart:io';

import 'package:cache/background/fgs_add.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/fgs_notice_card.dart';
import 'package:cache/library/book_pages.dart' show BookPage;
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/library/shelf_source.dart' show BookFileWhere;
import 'package:cache/library/shelves_pages.dart' show ShelfPage;
import 'package:cache/screens/settings/sharing_page.dart' show SharingDevicePage;
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf/add_pdf_fixtures.dart';
import 'add_pdf/add_pdf_world.dart';
import 'browse/fakes.dart';
import 'library/fake_shelves.dart';
import 'library/library_fixtures.dart';
import 'support/sync_fake.dart';
import 'watch_folder/watch_world.dart';

void main() {
  AddPdfWorld? aw;
  WatchWorld? ww;

  Directory? tmp;
  FakeSources? sources;
  LibrariesState? libs;
  CdsShelfSource? shelves;
  BrowseState? browse;

  tearDown(() {
    if (ww != null) {
      ww!.dispose();
    } else {
      aw?.dispose();
    }
    ww = null;
    aw = null;
    shelves?.dispose();
    browse?.dispose();
    libs?.dispose();
    sources?.dispose();
    shelves = null;
    browse = null;
    libs = null;
    sources = null;
    indexSchedulerShared = null;
    try {
      tmp?.deleteSync(recursive: true);
    } catch (_) {}
    tmp = null;
  });

  void size(WidgetTester tester, [Size s = const Size(390, 1400)]) {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget home) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: home);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f.first);
    await tester.tap(f.first);
    await settle(tester);
  }

  Future<void> tapIn(WidgetTester tester, String key, Finder inside) async {
    final f = find.descendant(of: find.byKey(ValueKey(key)), matching: inside);
    expect(f, findsOneWidget);
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle(tester);
  }

  AddPdfProgressPage progress(AddPdfWorld w) => AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler);

  // ---- Add PDF and watched folders

  testWidgets('6. The notice card (a background add failed or paused) opens the Add PDF progress page; Dismiss stays', (tester) async {
    size(tester, const Size(390, 844));
    await tester.runAsync(() async => aw = await AddPdfWorld.make());
    final w = aw!;
    final bg = '${w.tmp.path}/background';
    final jobs = [sampleJob('a', status: AddPdfStatus.failed, error: 'locked', title: 'Tax form')];
    final st = FgsAddNoticeState(backgroundDir: () => bg, jobs: () => jobs);
    addTearDown(st.dispose);
    await tester.runAsync(() => writeFgsResult(bg, FgsAddResult(at: DateTime(2026, 11, 13, 20), why: 'done', total: 1, added: 0, failedIds: const ['a'], leftIds: const [])));
    st.load();
    await tester.pumpWidget(app(Scaffold(body: FgsAddNoticeCard(state: st))));
    await settle(tester);
    expect(find.byKey(const ValueKey('fgs-add-notice-dismiss')), findsOneWidget);
    await tapKey(tester, 'fgs-add-notice-open');
    expect(find.byType(AddPdfProgressPage), findsOneWidget);
  });

  testWidgets('7. "Looks like another copy of / Same file as" opens that book', (tester) async {
    size(tester, const Size(390, 844));
    await tester.runAsync(() async => aw = await AddPdfWorld.make());
    final w = aw!;
    w.done(w.spare);
    await tester.pumpWidget(app(progress(w)));
    await settle(tester);
    await tapIn(tester, 'add-pdf-note-spare', find.textContaining('Same file as'));
    expect(find.byType(BookPage), findsOneWidget);
  });

  testWidgets('8. "Filed in {division}" opens that shelf', (tester) async {
    size(tester, const Size(390, 844));
    await tester.runAsync(() async => aw = await AddPdfWorld.make());
    final w = aw!;
    w.done(w.filed);
    await tester.pumpWidget(app(progress(w)));
    await settle(tester);
    await tapIn(tester, 'add-pdf-note-filed', find.text('Filed in 530 Water treatment'));
    expect(find.byType(ShelfPage), findsOneWidget);
  });

  testWidgets('9. A watched folder summary: the book named in a per-book note opens', (tester) async {
    size(tester);
    await tester.runAsync(() async => ww = await WatchWorld.make());
    final w = ww!;
    w.foundDone();
    await tester.pumpWidget(app(progress(w.pdf)));
    await settle(tester);
    await tapIn(tester, 'watch-note-water-done', find.text('Water filter guide'));
    expect(find.byType(BookPage), findsOneWidget);
  });

  testWidgets('14. On the Library, "N being added" opens the progress page', (tester) async {
    size(tester, const Size(390, 844));
    await tester.runAsync(() async => aw = await AddPdfWorld.make());
    final w = aw!;
    w.runOne();
    await tester.pumpWidget(app(LibraryPanes(root: (_) => LibraryRootPage(deps: w.deps), prefs: PanePrefs(dirOverride: w.tmp))));
    await settle(tester);
    await tapKey(tester, 'library-being-added');
    expect(find.byType(AddPdfProgressPage), findsOneWidget);
  });

  // ---- Bookshelves

  Future<void> setUpBooks() async {
    tmp = Directory.systemTemp.createTempSync('links-sweep');
    writeBookLibrary(Directory('${tmp!.path}/libraries'), 'field', const [
      ('aid', 'Wilderness first aid', '210', null),
      ('surgery', 'Emergency war surgery', '210', null),
      ('bees', 'Keeping bees in cold climates', '350', null),
    ], pdfs: {'aid'});
    sources = FakeSources(Directory('${tmp!.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp!.path}/libraries'), sources!);
    shelves = CdsShelfSource(libs!, calls: FakeShelvesCalls(), bookshelvesDir: () async => Directory('${tmp!.path}/bookshelves'), deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await shelves!.whenRead();
    browse = BrowseState(sources: sources!, libraries: libs!, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
  }

  Widget libraryApp({FakeBookFiles? files, SharingState? sharing}) => app(LibraryPanes(
    root: (_) => LibraryRootPage(deps: testDeps(browse: browse!, shelves: shelves!, files: files, sharing: sharing)),
    prefs: PanePrefs(dirOverride: tmp!),
  ));

  Future<void> openBook(WidgetTester tester, String id) async {
    await tapKey(tester, 'library-bookshelves');
    await tapKey(tester, 'shelf-200');
    await tapKey(tester, 'shelf-210');
    await tapKey(tester, 'book-$id');
  }

  Future<void> hideSurgery(WidgetTester tester) async {
    await tester.runAsync(() => shelves!.hide(shelves!.book('surgery')!));
    await tester.pumpAndSettle();
  }

  testWidgets('10. A Hidden books row opens the book page, which has Show on Bookshelves; the lists still leave it out', (tester) async {
    size(tester);
    await tester.runAsync(setUpBooks);
    await tester.pumpWidget(libraryApp());
    await tester.pumpAndSettle();
    await tapKey(tester, 'library-bookshelves');
    await hideSurgery(tester);
    await tapKey(tester, 'shelves-hidden');
    await tapIn(tester, 'hidden-surgery', find.text('Emergency war surgery'));
    expect(find.byType(BookPage), findsOneWidget);
    expect(find.byKey(const ValueKey('book-show')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-hide')), findsNothing);
    expect(shelves!.book('surgery'), isNull, reason: 'it is still hidden from the lists');
    await tapKey(tester, 'book-show');
    await tester.runAsync(shelves!.whenRead);
    expect(shelves!.book('surgery'), isNotNull);
  });

  testWidgets('11. The "Show on Bookshelves" snackbar has Open, which opens the book', (tester) async {
    size(tester);
    await tester.runAsync(setUpBooks);
    await tester.pumpWidget(libraryApp());
    await tester.pumpAndSettle();
    await tapKey(tester, 'library-bookshelves');
    await hideSurgery(tester);
    await tapKey(tester, 'shelves-hidden');
    await tapKey(tester, 'hidden-show-surgery');
    expect(find.byKey(const ValueKey('shown-snack')), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Open'));
    await settle(tester);
    expect(find.byType(BookPage), findsOneWidget);
  });

  testWidgets('12. The Subject fact of a book opens its shelf', (tester) async {
    size(tester);
    await tester.runAsync(setUpBooks);
    await tester.pumpWidget(libraryApp());
    await tester.pumpAndSettle();
    await openBook(tester, 'surgery');
    expect(find.byType(BookPage), findsOneWidget);
    await tapKey(tester, 'book-subject');
    expect(find.byType(BookPage), findsNothing);
    expect(find.byType(ShelfPage), findsOneWidget);
  });

  testWidgets('13. "Opens from {device} when it is online" opens that linked device', (tester) async {
    size(tester);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('links-sweep-sync')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final sync = FakeSync()..peers.add({'id': 'p1', 'name': 'Kitchen tablet', 'linked': 1, 'last_seen': null, 'via': null, 'error': null});
    final s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => dir, kinds: const [], opener: (_) async => sync);
    addTearDown(s.dispose);
    await tester.runAsync(s.setUp);
    await tester.runAsync(s.refresh);
    await tester.runAsync(setUpBooks);
    await tester.pumpWidget(libraryApp(files: FakeBookFiles(where: BookFileWhere.elsewhere), sharing: s));
    await tester.pumpAndSettle();
    await openBook(tester, 'surgery');
    expect(find.text('Not on this device. Opens from Kitchen tablet when it is online.'), findsOneWidget);
    await tapKey(tester, 'book-pdf');
    expect(find.byType(SharingDevicePage), findsOneWidget);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/catalog_page.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/library/library_prefs.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart' show IndexDuty;
import 'package:cache/settings/space.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'library_fixtures.dart';

const _seed = '''
{"v":1,"at":1000,"dev":"builder-field","ev":"place","doc":"aid","div":"210","by":"auto"}
{"v":1,"at":1000,"dev":"builder-field","ev":"assign","doc":"aid","div":"210","seq":1}
{"v":1,"at":1000,"dev":"builder-field","ev":"place","doc":"surgery","div":"210","by":"auto"}
{"v":1,"at":1000,"dev":"builder-field","ev":"assign","doc":"surgery","div":"210","seq":2}
''';

class _Run implements IndexRun {
  final Completer<bool> _done = Completer<bool>();
  @override
  void setDuty(IndexDuty duty) {}
  @override
  Future<bool> get finished => _done.future;
  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    if (!_done.isCompleted) _done.complete(false);
  }
}

class _Work implements IndexWorkSource {
  final List<String> keys = [];
  @override
  Future<List<IndexTask>> pending() async => [
    for (final k in keys) IndexTask(key: k, title: 'Medical encyclopedia', start: () async => _Run()),
  ];
}

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;
  var made = false;

  Future<void> setUpAll0({bool books = true, Set<String> pdfs = const {}, Map<String, Map<String, dynamic>> extra = const {}}) async {
    if (books) {
      writeBookLibrary(Directory('${tmp.path}/libraries'), 'field', const [
        ('aid', 'Wilderness first aid', '210', '220'),
        ('surgery', 'Emergency war surgery', '210', null),
        ('bees', 'Keeping bees in cold climates', '350', '190'),
        ('engines', 'Small engine repair', '670', '690'),
        ('stone', 'Stone', null, null),
      ], log: _seed, pdfs: pdfs, extra: extra);
    } else {
      Directory('${tmp.path}/libraries').createSync(recursive: true);
    }
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
    shelves = CdsShelfSource(libs, deviceId: () async => 'phone-test', clock: () => 5000);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    made = true;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('library-ui');
    made = false;
  });
  tearDown(() {
    if (made) {
      shelves.dispose();
      browse.dispose();
      libs.dispose();
      sources.dispose();
    }
    indexSchedulerShared = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void size(WidgetTester tester, Size s) {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(LibraryDeps d) => MaterialApp(
    theme: buildTheme(CacheThemeId.light),
    home: LibraryPanes(root: (_) => LibraryRootPage(deps: d), prefs: PanePrefs(dirOverride: tmp)),
  );

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)).first);
    await tester.pumpAndSettle();
  }

  group('navigation', () {
    testWidgets('the root has four rows with their states; a phone goes Bookshelves, class, division, book, and the breadcrumb climbs back', (tester) async {
      size(tester, const Size(390, 844));
      await tester.runAsync(setUpAll0);
      final added = <String>[];
      final d = testDeps(browse: browse, shelves: shelves, added: added);
      await tester.pumpWidget(app(d));
      await tester.pumpAndSettle();
      for (final t in ['ZIM Collections', 'Bookshelves', 'Catalog', 'Cache Documentation']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('None yet'), findsOneWidget, reason: 'no ZIMs');
      expect(find.text('5 books, shelved by the CDS'), findsOneWidget);
      expect(find.text('3 unsorted'), findsOneWidget, reason: 'a fix is a plain accent line');
      expect(find.text('1 search index'), findsOneWidget);
      await tapKey(tester, 'add-to-library');
      expect(added, ['add'], reason: 'Add to Library is the one way in');

      await tapKey(tester, 'library-bookshelves');
      expect(find.text('Shelved by the Cache Decimal System'), findsOneWidget);
      expect(find.text('Unsorted · 3 books'), findsOneWidget);
      await tapKey(tester, 'shelf-200');
      expect(find.text('CDS 200'), findsWidgets, reason: 'the number above the title, and the breadcrumb');
      expect(find.text('Medicine and Health'), findsOneWidget);
      expect(find.text('empty'), findsNWidgets(8), reason: 'every division shows, the empty ones dimmed');
      await tapKey(tester, 'shelf-210');
      expect(find.text('First aid and emergency care'), findsOneWidget);
      expect(find.text('210-001'), findsOneWidget);
      expect(find.text('210-002'), findsOneWidget);
      await tapKey(tester, 'book-field/aid');
      expect(find.byKey(const ValueKey('catalogue-card')), findsOneWidget);
      expect(find.text('CDS 210-001'), findsOneWidget);
      expect(find.text('CDS 210 · First aid and emergency care'), findsOneWidget);
      expect(find.text('Filed by Cache'), findsOneWidget);
      expect(find.text('Not searchable yet'), findsOneWidget);
      expect(find.text('Not on this device'), findsOneWidget, reason: 'its PDF is not on this device');
      expect(find.byKey(const ValueKey('book-open')), findsNothing, reason: 'nothing to open here: no button that would not work');
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('book-download'))).onPressed, isNull, reason: 'Download is greyed until stream-back');
      expect(find.byKey(const ValueKey('book-author')), findsNothing, reason: 'the pack has no author: no line');
      await tapKey(tester, 'crumb-CDS 200');
      expect(find.text('Medicine and Health'), findsOneWidget);
      expect(find.byKey(const ValueKey('catalogue-card')), findsNothing);
      await tapKey(tester, 'crumb-Bookshelves');
      expect(find.text('Shelved by the Cache Decimal System'), findsOneWidget);
    });

    testWidgets('Go to a number opens the division, or the book', (tester) async {
      size(tester, const Size(390, 844));
      await tester.runAsync(setUpAll0);
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tester.enterText(find.byKey(const ValueKey('go-to-number')), '210-002');
      await tapKey(tester, 'go-to-number-go');
      expect(find.text('Emergency war surgery'), findsWidgets);
      expect(find.text('CDS 210-002'), findsOneWidget);
      // the breadcrumb leads through the class it skipped
      await tapKey(tester, 'crumb-CDS 210');
      expect(find.text('210-001'), findsOneWidget);
      await tapKey(tester, 'crumb-CDS 200');
      expect(find.text('Medicine and Health'), findsOneWidget);
    });

    testWidgets('a tablet held upright: the current list and its detail; sideways and on a desktop: the rows, the list and the detail', (tester) async {
      await tester.runAsync(setUpAll0);
      final d = testDeps(browse: browse, shelves: shelves);
      size(tester, const Size(820, 1180));
      await tester.pumpWidget(app(d));
      await tester.pumpAndSettle();
      expect(find.text('Choose an item'), findsOneWidget);
      await tapKey(tester, 'library-bookshelves');
      expect(find.byKey(const ValueKey('library-bookshelves')), findsOneWidget, reason: 'the root stays beside Bookshelves');
      expect(find.text('Shelved by the Cache Decimal System'), findsOneWidget);
      await tapKey(tester, 'shelf-200');
      expect(find.byKey(const ValueKey('library-bookshelves')), findsNothing, reason: 'two panes: Bookshelves and the class');
      expect(find.text('Shelved by the Cache Decimal System'), findsOneWidget);
      expect(find.text('Medicine and Health'), findsWidgets);

      for (final s in [const Size(1180, 820), const Size(1440, 900)]) {
        size(tester, s);
        await tester.pumpWidget(app(d));
        await tester.pumpAndSettle();
        await tapKey(tester, 'library-bookshelves');
        await tapKey(tester, 'shelf-200');
        expect(find.byKey(const ValueKey('library-bookshelves')), findsOneWidget, reason: '$s: the Library rows stay');
        expect(find.text('Shelved by the Cache Decimal System'), findsOneWidget, reason: '$s: the list');
        expect(find.byKey(const ValueKey('shelf-210')), findsOneWidget, reason: '$s: the detail');
        await tapKey(tester, 'shelf-210');
        await tapKey(tester, 'book-field/aid');
        // the division beside the book (sections, list, detail): never deeper
        expect(find.byKey(const ValueKey('library-bookshelves')), findsOneWidget);
        expect(find.byKey(const ValueKey('book-field/surgery')), findsOneWidget);
        expect(find.byKey(const ValueKey('catalogue-card')), findsOneWidget);
        expect(find.text('Shelved by the Cache Decimal System'), findsNothing, reason: 'Bookshelves is in the breadcrumb now');
        await tapKey(tester, 'library-hide-list');
        expect(find.byKey(const ValueKey('book-field/surgery')), findsNothing, reason: 'Hide list: the book takes the width');
        expect(find.byKey(const ValueKey('library-show-list')), findsOneWidget);
        await tapKey(tester, 'library-show-list');
        expect(find.byKey(const ValueKey('book-field/surgery')), findsOneWidget);
      }
    });
  });

  group('the three looks', () {
    testWidgets('List by default; Drawers and Spines from the switch; every class in each', (tester) async {
      size(tester, const Size(390, 1600));
      await tester.runAsync(setUpAll0);
      final looks = ShelfLookPrefs(dirOverride: tmp);
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves, looks: looks)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      expect(find.byKey(const ValueKey('shelf-900')), findsOneWidget, reason: 'List: the call-number list with class bands');
      await tapKey(tester, 'look-drawers');
      expect(looks.look, ShelfLook.drawers);
      expect(find.byKey(const ValueKey('shelves-drawers')), findsOneWidget);
      expect(find.text('200-299'), findsOneWidget, reason: 'the range on the drawer card');
      await tapKey(tester, 'drawer-200');
      expect(find.text('Medicine and Health'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapKey(tester, 'look-spines');
      expect(find.byKey(const ValueKey('shelves-spines')), findsOneWidget);
      expect(find.byKey(const ValueKey('spines-900')), findsOneWidget);
      await tapKey(tester, 'look-list');
      expect(find.byKey(const ValueKey('shelf-000')), findsOneWidget);
    });

    test('the look is kept on this device: a new start reads the one chosen', () async {
      final looks = ShelfLookPrefs(dirOverride: tmp);
      expect(await looks.load(), ShelfLook.list, reason: 'List is the default on every screen size');
      await looks.set(ShelfLook.spines);
      expect(await ShelfLookPrefs(dirOverride: tmp).load(), ShelfLook.spines);
      await ShelfLookPrefs(dirOverride: tmp).set(ShelfLook.drawers);
      expect(await ShelfLookPrefs(dirOverride: tmp).load(), ShelfLook.drawers);
    });
  });

  group('Unsorted', () {
    testWidgets('a best guess places the book with its new number and Undo; Place all best guesses and its Undo', (tester) async {
      size(tester, const Size(390, 844));
      await tester.runAsync(setUpAll0);
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelves-unsorted');
      expect(find.text("3 books Cache wasn't sure about. Pick a subject; it's saved and helps Cache learn."), findsOneWidget);
      expect(find.text('350 Beekeeping · Best guess'), findsOneWidget);
      expect(find.text('CDS —'), findsNWidgets(3));
      await tapKey(tester, 'chip-field/bees-350');
      expect(find.text('Placed in CDS 350 · Beekeeping as CDS 350-001.'), findsOneWidget);
      expect(shelves.book('field/bees')!.shelf, '350');
      expect(find.text('CDS —'), findsNWidgets(2));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(shelves.book('field/bees')!.unsorted, isTrue);
      expect(find.text('CDS —'), findsNWidgets(3));

      await tapKey(tester, 'place-all');
      expect(find.text('Placed 2 books. Each has its new call number.'), findsOneWidget);
      expect(shelves.unsorted.map((b) => b.title), ['Stone'], reason: 'a book with no guess stays');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(shelves.unsorted, hasLength(3), reason: 'Undo reverses the whole batch');
    });

    testWidgets('All divisions: the Place it sheet says the number before the tap, lists every division, and Leave unsorted', (tester) async {
      size(tester, const Size(390, 844));
      await tester.runAsync(setUpAll0);
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelves-unsorted');
      await tapKey(tester, 'all-divisions-field/bees');
      expect(find.text('Where does this book go?'), findsOneWidget);
      expect(find.text('The book gets its call number in the division you pick, for example CDS 350-001.'), findsOneWidget);
      await tapKey(tester, 'place-all-divisions');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('place-div-530')), 200, scrollable: find.byType(Scrollable).last);
      await tapKey(tester, 'place-div-530');
      expect(shelves.book('field/bees')!.callNumber, 'CDS 530-001');
      // it went on to the next book
      expect(find.text('Small engine repair'), findsWidgets);
      await tapKey(tester, 'place-leave');
      await tapKey(tester, 'place-leave');
      expect(find.text('Where does this book go?'), findsNothing, reason: 'nothing more to place: the sheet closes');
    });

    testWidgets('on a tablet Place it is the detail pane, never a dialog', (tester) async {
      size(tester, const Size(1180, 820));
      await tester.runAsync(setUpAll0);
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelves-unsorted');
      await tapKey(tester, 'all-divisions-field/bees');
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Where does this book go?'), findsOneWidget);
      expect(find.byKey(const ValueKey('unsorted-field/bees')), findsOneWidget, reason: 'Unsorted stays beside it');
    });
  });

  group('the book page', () {
    testWidgets('a book whose PDF is here has Open; the division marks the ones that are not', (tester) async {
      size(tester, const Size(390, 1000));
      await tester.runAsync(() => setUpAll0(pdfs: {'aid'}));
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelf-200');
      await tapKey(tester, 'shelf-210');
      expect(find.text('Not on this device'), findsOneWidget, reason: 'surgery is not here; aid is');
      await tapKey(tester, 'book-field/aid');
      expect(find.byKey(const ValueKey('book-open')), findsOneWidget);
      expect(find.text('On this device · 3 KB'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-download')), findsNothing);
      expect(shelves.book('field/aid')!.pdfPath, endsWith('bookshelf/${sampleHash('aid')}.pdf'));
    });

    testWidgets('the catalogue card shows the author, edition and original title only when the pack has them', (tester) async {
      size(tester, const Size(390, 1000));
      await tester.runAsync(() => setUpAll0(extra: {
        'aid': {'author': 'Paul S. Auerbach', 'edition': '7th edition', 'year': 2017, 'source_title': 'wilderness_med_7e.pdf'},
      }));
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelf-200');
      await tapKey(tester, 'shelf-210');
      await tapKey(tester, 'book-field/aid');
      expect(find.text('Paul S. Auerbach'), findsOneWidget);
      expect(find.text('7th edition, 2017'), findsOneWidget);
      expect(find.text('Original title: wilderness_med_7e.pdf'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapKey(tester, 'book-field/surgery');
      expect(find.byKey(const ValueKey('book-author')), findsNothing);
      expect(find.byKey(const ValueKey('book-edition')), findsNothing);
      expect(find.byKey(const ValueKey('book-original-title')), findsNothing);
    });

    test('a device copy kept as Cache for Linux keeps it (sources/<library>/<doc>.pdf) counts as here', () async {
      final root = Directory('${tmp.path}/docs/libraries')..createSync(recursive: true);
      writeBookLibrary(root, 'field', const [('aid', 'Wilderness first aid', '210', null)]);
      File('${tmp.path}/docs/sources/field/aid.pdf')
        ..createSync(recursive: true)
        ..writeAsStringSync('%PDF-1.4');
      final l = LibraryItem(dir: Directory('${root.path}/field'));
      expect(CdsShelfSource.localPdfOf(l, 'aid', sampleHash('aid')), '${tmp.path}/docs/sources/field/aid.pdf');
      expect(CdsShelfSource.localPdfOf(l, 'other', null), isNull);
    });
  });

  group('Delete book', () {
    Future<void> openBook(WidgetTester tester, BookFiles files) async {
      size(tester, const Size(390, 1000));
      await tester.runAsync(() => setUpAll0(pdfs: {'aid'}));
      await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves, files: files)));
      await tester.pumpAndSettle();
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelf-200');
      await tapKey(tester, 'shelf-210');
      await tapKey(tester, 'book-field/aid');
    }

    testWidgets('two separate choices: Remove from this device refuses when no other device has it; Delete from all devices', (tester) async {
      final files = FakeBookFiles(outcome: RemoveOutcome.noOtherCopy);
      await openBook(tester, files);
      expect(find.text('On this device · 3 KB'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-open')), findsOneWidget);
      expect(find.text('Remove PDF from this device'), findsOneWidget, reason: 'the PDF-only button never shares a name with the book choice');
      await tapKey(tester, 'book-delete');
      expect(find.byKey(const ValueKey('delete-here')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-all')), findsOneWidget);
      expect(find.textContaining('its call number CDS 210-001 on every device you have linked. This cannot be undone.'), findsOneWidget);
      await tapKey(tester, 'delete-here-button');
      expect(find.text("No other device has this book right now, so it can't be removed from just this device. Delete it instead."), findsOneWidget);
      expect(files.removed, isEmpty, reason: 'nothing is removed');
      await tapKey(tester, 'delete-all-button');
      expect(files.deleted, ['field/aid']);
      expect(find.byKey(const ValueKey('delete-all')), findsNothing, reason: 'the sheet closes');
    });

    testWidgets('Remove from this device after the live check found a copy', (tester) async {
      final files = FakeBookFiles();
      await openBook(tester, files);
      await tapKey(tester, 'book-delete');
      await tapKey(tester, 'delete-here-button');
      expect(files.removed, ['field/aid']);
      expect(find.byKey(const ValueKey('delete-here')), findsNothing);
    });

    testWidgets('on a phone without offload or delete-everywhere yet, both choices say so and do nothing', (tester) async {
      await openBook(tester, BookFilesUnavailable());
      await tapKey(tester, 'book-delete');
      expect(find.text('Not available on this device yet.'), findsNWidgets(2));
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('delete-here-button'))).onPressed, isNull);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('delete-all-button'))).onPressed, isNull);
    });
  });

  group('Catalog', () {
    testWidgets('every index grouped with its state; Pause while it runs, Resume after; the empty Catalog', (tester) async {
      size(tester, const Size(390, 1200));
      await tester.runAsync(setUpAll0);
      final z1 = File('${sources.zimsDir!.path}/medical.zim')..writeAsBytesSync([0]);
      final z2 = File('${sources.zimsDir!.path}/wiki.zim')..writeAsBytesSync([0]);
      await tester.runAsync(sources.refresh);
      sources.titles
        ..[z1.path] = 'Medical encyclopedia'
        ..[z2.path] = 'Wikipedia';
      sources.ids
        ..[z1.path] = 'm1'
        ..[z2.path] = 'w1';
      sources.ready.add(z2.path);
      final work = _Work()..keys.add('zim/m1');
      final s = IndexScheduler(sources: [work], space: () => const Space(free: 100 << 30, reserve: 1 << 30), battery: () async => const BatteryReading(percent: 90, charging: true), every: const Duration(hours: 1));
      indexSchedulerShared = s;
      s.setOpen(true);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      final d = testDeps(browse: browse, shelves: shelves);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(deps: d)));
      await tester.pump();
      expect(find.text('YOUR BOOKS'), findsOneWidget);
      expect(find.text('ZIM COLLECTIONS'), findsOneWidget);
      expect(find.text('Waiting to make it searchable'), findsOneWidget, reason: 'the books');
      expect(find.text('Ready'), findsOneWidget, reason: 'Wikipedia');
      expect(find.text('Getting the search index ready'), findsOneWidget, reason: 'the scheduler says what runs');
      await tester.tap(find.byKey(const ValueKey('catalog-action-zim/m1')));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(s.pausedAll, isTrue);
      expect(find.text('Resume'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('catalog-action-zim/m1')));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(s.pausedAll, isFalse);
      s.dispose();
      indexSchedulerShared = null;
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('nothing yet: no indexes, and Add to Library', (tester) async {
      size(tester, const Size(390, 844));
      await tester.runAsync(() => setUpAll0(books: false));
      final added = <String>[];
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(deps: testDeps(browse: browse, shelves: shelves, added: added))));
      await tester.pump();
      expect(find.text('No search indexes yet.'), findsOneWidget);
      await tester.tap(find.text('Add to Library'));
      expect(added, ['add']);
    });
  });

  testWidgets('Cache Documentation: the guide, What\'s new and Credits and licences', (tester) async {
    size(tester, const Size(390, 844));
    await tester.runAsync(() => setUpAll0(books: false));
    await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
    await tester.pumpAndSettle();
    expect(find.text('No books yet'), findsOneWidget);
    await tapKey(tester, 'library-docs');
    expect(find.text('The Cache guide'), findsOneWidget);
    expect(find.text("What's new in 1.1.0"), findsOneWidget);
    expect(find.text('Credits and licences'), findsOneWidget);
    await tapKey(tester, 'docs-credits');
    expect(find.text('Licence'), findsOneWidget);
  });
}

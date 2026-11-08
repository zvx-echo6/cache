import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/library/shelves_pages.dart' show BookshelvesPage, HiddenBooksPage;
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelves.dart';
import 'library_fixtures.dart';

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;
  late FakeShelvesCalls calls;
  var made = false;

  // two files of one book (the same text), and two other books; nothing on the shelves yet, so Cache files them all
  Future<void> setUpBooks({bool oldLibrary = false}) async {
    if (oldLibrary) {
      // a library made before libraries carried copies.jsonl, downloaded without its packs
      writeBookLibrary(Directory('${tmp.path}/libraries'), 'old', const [('stove', 'Rocket stoves', '590', null), ('soap', 'Soap making', '680', null)]);
      Directory('${tmp.path}/libraries/old/packs').deleteSync(recursive: true);
      File('${tmp.path}/libraries/old/cache-library.json').writeAsStringSync('{"format":1,"library_id":"old","title":"Homestead library","version":"1"}');
    }
    writeBookLibrary(Directory('${tmp.path}/libraries'), 'field', const [
      ('aid', 'Wilderness first aid', '210', null),
      ('aid2', 'Wilderness first aid, 2nd printing', '210', null),
      ('surgery', 'Emergency war surgery', '210', null),
      ('bees', 'Keeping bees in cold climates', '350', null),
    ], pdfs: {'aid', 'aid2'}, samebook: {
      'aid': {'minhash': [1, 2, 3]},
      'aid2': {'minhash': [1, 2, 3]},
    });
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
    calls = FakeShelvesCalls();
    shelves = CdsShelfSource(libs, calls: calls, bookshelvesDir: () async => Directory('${tmp.path}/bookshelves'), deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    made = true;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('same-book-ui');
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
    await tester.ensureVisible(find.byKey(ValueKey(key)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)).first);
    await tester.runAsync(shelves.whenRead);
    await tester.pumpAndSettle();
  }

  Future<void> openDivision(WidgetTester tester) async {
    await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
    await tester.pumpAndSettle();
    await tapKey(tester, 'library-bookshelves');
    await tapKey(tester, 'shelf-200');
    await tapKey(tester, 'shelf-210');
  }

  List<Map<String, dynamic>> mine() => [for (final e in calls.appended) if (e['dev'] == 'phone-test') e];

  testWidgets('one book with its spare copy: the division says so, the book page lists it; read it instead; Not the same book splits it', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(setUpBooks);
    await openDivision(tester);
    expect(find.text('210-001'), findsOneWidget, reason: 'Emergency war surgery, filed first by title');
    expect(find.text('210-002'), findsOneWidget, reason: 'the two files of first aid are one book with one number');
    expect(find.text('210-003'), findsNothing);
    expect(find.textContaining('1 spare copy'), findsOneWidget);

    await tapKey(tester, 'book-aid');
    expect(find.text('CDS 210-002'), findsOneWidget);
    expect(find.text('SPARE COPIES'), findsOneWidget);
    expect(find.text('Wilderness first aid, 2nd printing'), findsNWidgets(2), reason: 'the spare, and Also known as');
    expect(find.text('Also known as'), findsOneWidget);
    expect(find.text('39.1 MB · Field library'), findsOneWidget, reason: 'its size and where it is');
    for (final word in ['copy key', 'event', 'log']) {
      expect(find.textContaining(RegExp('\\b$word\\b', caseSensitive: false)), findsNothing, reason: 'no "$word" in the words');
    }

    calls.appended.clear();
    await tapKey(tester, 'spare-read-aid2');
    expect(mine().single, containsPair('ev', 'prefer'));
    expect(mine().single['copy'], 'aid2');
    expect(find.text('You will read this copy from now on.'), findsOneWidget);
    expect(shelves.book('aid')!.reading, 'aid2');
    // the spare now is the other file
    expect(find.byKey(const ValueKey('spare-aid')), findsOneWidget);

    calls.appended.clear();
    await tapKey(tester, 'spare-notsame-aid');
    expect([for (final e in mine()) (e['ev'], e['copy'], e['with'], e['by'])], [('notsame', 'aid', 'aid2', 'user')]);
    expect(find.text('Now a book of its own.'), findsOneWidget);
    expect(find.text('SPARE COPIES'), findsNothing);
    expect(shelves.bookCount, 4);
  });

  testWidgets('Same book as… searches the books and joins the two, with Undo', (tester) async {
    size(tester, const Size(390, 1000));
    await tester.runAsync(setUpBooks);
    await openDivision(tester);
    await tapKey(tester, 'book-surgery');
    await tapKey(tester, 'book-same-as');
    expect(find.byType(BottomSheet), findsOneWidget, reason: 'a sheet on a phone');
    expect(find.text('Same book as…'), findsWidgets);
    expect(find.byKey(const ValueKey('same-pick-surgery')), findsNothing, reason: 'not itself');
    expect(find.byKey(const ValueKey('same-pick-aid')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('same-search')), 'BEES');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('same-pick-aid')), findsNothing);
    expect(find.byKey(const ValueKey('same-pick-bees')), findsOneWidget);
    calls.appended.clear();
    await tapKey(tester, 'same-pick-bees');
    expect([for (final e in mine()) (e['ev'], e['copy'], e['with'], e['by'], e['how'])], [('same', 'surgery', 'bees', 'user', 'user')]);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.textContaining('Now one book'), findsOneWidget);
    expect(shelves.bookCount, 2);
    calls.appended.clear();
    await tester.tap(find.byKey(const ValueKey('same-undo')));
    await tester.runAsync(shelves.whenRead);
    await tester.pumpAndSettle();
    expect([for (final e in mine()) (e['ev'], e['copy'], e['with'])], [('notsame', 'surgery', 'bees')]);
    expect(shelves.bookCount, 3);
  });

  testWidgets('on a desktop Same book as… is the detail pane, never a dialog', (tester) async {
    size(tester, const Size(1440, 900));
    await tester.runAsync(setUpBooks);
    await openDivision(tester);
    await tapKey(tester, 'book-surgery');
    await tapKey(tester, 'book-same-as');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const ValueKey('same-search')), findsOneWidget);
    await tapKey(tester, 'same-pick-aid');
    expect(shelves.bookCount, 2);
    expect(find.byKey(const ValueKey('catalogue-card')), findsOneWidget, reason: 'back to the joined book');
  });

  testWidgets('Rename writes the new title for all devices; the original title is one tap away', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(setUpBooks);
    await openDivision(tester);
    await tapKey(tester, 'book-aid');
    await tapKey(tester, 'book-rename');
    expect(find.byType(BottomSheet), findsOneWidget, reason: 'a sheet on a phone');
    expect(find.text('Rename'), findsWidgets);
    expect(find.byKey(const ValueKey('rename-use-Wilderness first aid, 2nd printing')), findsOneWidget, reason: 'the spare\'s title to pick');
    calls.appended.clear();
    await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Wilderness First Aid, 2nd ed.');
    await tester.pumpAndSettle();
    await tapKey(tester, 'rename-save');
    expect([for (final e in mine()) (e['ev'], e['copy'], e['title'])], [('title', 'aid', 'Wilderness First Aid, 2nd ed.')]);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Renamed on all your devices.'), findsOneWidget);
    expect(find.byKey(const ValueKey('book-title')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('book-title'))).data, 'Wilderness First Aid, 2nd ed.');
  });

  testWidgets('Hide from Bookshelves hides the book on all devices, goes back to its shelf, and Undo shows it again', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(setUpBooks);
    await openDivision(tester);
    await tapKey(tester, 'book-surgery');
    expect(find.text('On all your devices. No file is deleted.'), findsOneWidget);
    calls.appended.clear();
    await tapKey(tester, 'book-hide');
    expect([for (final e in mine()) (e['ev'], e['copy'])], [('remove', 'surgery')]);
    expect(shelves.book('surgery'), isNull);
    expect(find.text('Hidden on all your devices. No file was deleted.'), findsOneWidget);
    expect(find.byKey(const ValueKey('catalogue-card')), findsNothing, reason: 'back on the shelf');
    expect(find.byKey(const ValueKey('book-aid')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-surgery')), findsNothing);
    calls.appended.clear();
    await tester.tap(find.byKey(const ValueKey('hidden-undo')));
    await tester.runAsync(shelves.whenRead);
    await tester.pumpAndSettle();
    expect([for (final e in mine()) (e['ev'], e['copy'])], [('restore', 'surgery')]);
    expect(find.byKey(const ValueKey('book-surgery')), findsOneWidget);
  });

  testWidgets('Hidden books: a row with the count at the foot of Bookshelves only while books are hidden; its list shows each one\'s '
      'number and library; Show on Bookshelves restores it where the logs now put it', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(setUpBooks);
    await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
    await tester.pumpAndSettle();
    await tapKey(tester, 'library-bookshelves');
    expect(find.byKey(const ValueKey('shelves-hidden')), findsNothing, reason: 'nothing hidden: no row');
    expect(shelves.book('surgery')!.callNumber, 'CDS 210-001');

    await tester.runAsync(() async {
      await shelves.hide(shelves.book('surgery')!);
      await shelves.hide(shelves.book('bees')!);
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelves-hidden')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('shelves-hidden')), matching: find.textContaining('2 books', findRichText: true)), findsOneWidget);
    expect(shelves.bookCount, 2, reason: 'hidden books are not on the shelves');

    await tapKey(tester, 'shelves-hidden');
    expect(find.byType(HiddenBooksPage), findsOneWidget);
    expect(find.text('Hidden books'), findsWidgets);
    expect(find.descendant(of: find.byKey(const ValueKey('hidden-surgery')), matching: find.text('210-001')), findsOneWidget, reason: 'the number it had');
    expect(find.descendant(of: find.byKey(const ValueKey('hidden-surgery')), matching: find.text('Emergency war surgery')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('hidden-bees')), matching: find.text('350-001')), findsOneWidget);
    expect(find.text('Field library'), findsNWidgets(2), reason: 'each one\'s library');
    expect(find.text('Show on Bookshelves'), findsNWidgets(2));

    // meanwhile another device's log arrives: a book of a library this phone lacks claimed 210-001 first (an earlier clock)
    File('${tmp.path}/bookshelves/log/tablet.jsonl').writeAsStringSync(
      '{"v":1,"at":4000,"dev":"tablet","ev":"place","copy":"ghost","div":"210","by":"user"}\n'
      '{"v":1,"at":4000,"dev":"tablet","ev":"assign","copy":"ghost","div":"210","seq":1}\n',
    );
    calls.appended.clear();
    await tapKey(tester, 'hidden-show-surgery');
    expect([for (final e in mine()) (e['ev'], e['copy'])], [('restore', 'surgery')]);
    expect(shelves.book('surgery')!.callNumber, 'CDS 210-001.1', reason: 'the clash rank the logs resolve');
    expect(find.text('CDS 210-001.1 · ${shelves.shelf('210')!.name}'), findsOneWidget, reason: 'where it went');
    expect(find.byKey(const ValueKey('hidden-surgery')), findsNothing);
    expect(find.text(' · 1 book'), findsOneWidget, reason: 'the count line');

    await tapKey(tester, 'hidden-show-bees');
    expect(shelves.book('bees')!.callNumber, 'CDS 350-001', reason: 'its own number back');
    expect(shelves.hidden, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BookshelvesPage), findsOneWidget, reason: 'a page of its own on a phone');
    expect(find.byKey(const ValueKey('shelves-hidden')), findsNothing, reason: 'nothing hidden any more: no row');
  });

  testWidgets('on a desktop Hidden books is the pane beside Bookshelves, never a dialog', (tester) async {
    size(tester, const Size(1440, 900));
    await tester.runAsync(setUpBooks);
    await tester.runAsync(() => shelves.hide(shelves.book('surgery')!));
    await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
    await tester.pumpAndSettle();
    await tapKey(tester, 'library-bookshelves');
    await tapKey(tester, 'shelves-hidden');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(BookshelvesPage), findsOneWidget, reason: 'the list stays beside it');
    expect(find.byType(HiddenBooksPage), findsOneWidget);
    calls.appended.clear();
    await tapKey(tester, 'hidden-show-surgery');
    expect([for (final e in mine()) (e['ev'], e['copy'])], [('restore', 'surgery')]);
    expect(shelves.book('surgery')!.callNumber, 'CDS 210-001');
    expect(find.text('CDS 210-001 · ${shelves.shelf('210')!.name}'), findsWidgets);
    expect(find.byKey(const ValueKey('shelves-hidden')), findsNothing);
  });

  testWidgets('on a desktop Rename is the detail pane, never a dialog', (tester) async {
    size(tester, const Size(1440, 900));
    await tester.runAsync(setUpBooks);
    await openDivision(tester);
    await tapKey(tester, 'book-surgery');
    await tapKey(tester, 'book-rename');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Emergency War Surgery');
    await tester.pumpAndSettle();
    await tapKey(tester, 'rename-save');
    expect(shelves.book('surgery')!.title, 'Emergency War Surgery');
    expect(find.byKey(const ValueKey('catalogue-card')), findsOneWidget, reason: 'back to the book');
  });

  testWidgets('a library that cannot be shelved here says so on Bookshelves, in plain words, instead of showing nothing', (tester) async {
    size(tester, const Size(390, 1000));
    await tester.runAsync(() => setUpBooks(oldLibrary: true));
    await tester.pumpWidget(app(testDeps(browse: browse, shelves: shelves)));
    await tester.pumpAndSettle();
    await tapKey(tester, 'library-bookshelves');
    expect(find.text("2 books in Homestead library aren't on your shelves"), findsOneWidget);
    expect(find.textContaining('They are still searchable.'), findsOneWidget);
    expect(find.byKey(const ValueKey('shelves-empty')), findsNothing);
  });
}

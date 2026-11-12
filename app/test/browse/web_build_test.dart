import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_library_page.dart';
import 'package:cache/browse/web/build_page.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/browse/web/build_text.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/drop_folder_page.dart';
import 'package:cache/theme.dart';
import 'package:cache/layout/adaptive.dart' show kDesktopDetailMaxWidth, kDesktopListWidth, kDesktopMinWidth;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'build_fakes.dart';
import 'web_fakes.dart';

Widget host(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: child);

void main() {
  late FakeBuildApi api;
  late FakeRawUploader uploader;
  late MemoryAppFs fs;
  late BuildController c;
  late List<bool> leaving;
  late List<List<FakeLocalFile>> chosen;

  setUp(() {
    api = FakeBuildApi();
    uploader = FakeRawUploader();
    fs = MemoryAppFs();
    leaving = [];
    chosen = [];
    c = BuildController(
      api: api,
      uploader: uploader,
      fs: fs,
      poll: false,
      leaveWarning: leaving.add,
      pickPdfs: () async => chosen.isEmpty ? const [] : chosen.removeAt(0),
      pickFolder: () async => chosen.isEmpty ? const [] : chosen.removeAt(0),
    );
  });
  tearDown(() => c.dispose());

  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> load(WidgetTester tester) async {
    await tester.runAsync(c.refresh);
  }

  Future<void> show(WidgetTester tester, Widget page) async {
    desktop(tester);
    await load(tester);
    await tester.pumpWidget(host(page));
    await tester.pumpAndSettle();
  }

  final bookA = book('a', 'Field Manual 21-76 Survival', pages: 412, passages: 480, file: 'fm21-76.pdf');
  final bookB = book('b', 'mushrooms_demystified_2nd_ed_OCR', pages: 560, passages: 644, file: 'mushrooms_demystified_2nd_ed_OCR.pdf');

  BuildLibrary lib({String id = 'lib1', String title = 'Hunting and field guides', int books = 2, int passages = 1124}) =>
      BuildLibrary(id: id, title: title, books: books, passages: passages, pages: 972, createdAt: DateTime(2026, 8, 14));

  group('Build from your PDFs', () {
    testWidgets('the form asks where the books go, then for the PDFs, and says what building costs', (tester) async {
      api.libs = [lib(books: 214)];
      await show(tester, BuildPage(build: c));
      expect(find.text('Build from your PDFs'), findsOneWidget);
      expect(find.text('1 · WHERE SHOULD THE BOOKS GO?'), findsOneWidget);
      expect(find.text('A new library'), findsOneWidget);
      expect(find.text('A library you built'), findsOneWidget);
      expect(find.text('Hunting and field guides · 214 books'), findsOneWidget);
      expect(find.text('2 · ADD YOUR PDFS'), findsOneWidget);
      expect(find.text('Drop PDFs or a folder here'), findsOneWidget);
      expect(find.text('Choose PDFs'), findsOneWidget);
      expect(find.text('Choose a folder'), findsOneWidget);
      expect(find.textContaining('passages of about 200 words'), findsOneWidget);
      expect(find.textContaining('It keeps going if you close this tab.'), findsOneWidget);
      expect(find.textContaining('server'), findsNothing);
      expect(find.textContaining('job'), findsNothing);
    });

    testWidgets('a name that is taken says so and nothing is sent', (tester) async {
      api.libs = [lib()];
      await show(tester, BuildPage(build: c));
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'hunting and field guides');
      await tester.pump();
      expect(find.text('You already have a library called "Hunting and field guides". Choose another name, or add to it.'), findsOneWidget);
      c.sink!([FakeLocalFile('a.pdf', 1000)]);
      await tester.pump();
      expect(uploader.started, isEmpty);
      expect(api.calls, isEmpty);
      expect(find.byKey(const ValueKey('pending-card')), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('pending-start'))).onPressed, isNull);
    });

    testWidgets('dropping PDFs on a named new library makes it and starts the upload, one request per PDF', (tester) async {
      await show(tester, BuildPage(build: c));
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'Garden notes');
      await tester.pump();
      c.sink!([FakeLocalFile('a.pdf', 3000), FakeLocalFile('b.PDF', 2000), FakeLocalFile('notes.txt', 10), FakeLocalFile('cover.jpg', 10)]);
      await tester.pump();
      await tester.pump();
      expect(api.calls, ['create Garden notes']);
      expect(uploader.urls, [
        '/api/build/upload?library_id=lib1&name=a.pdf',
        '/api/build/upload?library_id=lib1&name=b.PDF',
      ]);
      expect(leaving, [true], reason: 'leaving the tab is questioned while the upload runs');
      expect(find.text('Uploading 2 PDFs'), findsWidgets);
      expect(find.text('Going to'), findsOneWidget);
      expect(find.text('Garden notes (new library)'), findsOneWidget);
      expect(find.textContaining('Keep this tab open until the upload ends. Building starts on the first book and carries on without this tab.'), findsOneWidget);
      expect(find.text('2 other files were left out (notes.txt, cover.jpg).'), findsOneWidget);
      uploader.started[0].progress(1500);
      await tester.pump();
      expect(find.textContaining('of 5 KB'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel-batch')), findsOneWidget);
      uploader.finishAll();
      await tester.pumpAndSettle();
      expect(leaving, [true, false]);
      // the library's own page opens when the upload ends
      expect(find.byType(BuiltLibraryPage), findsOneWidget);
    });

    testWidgets('PDFs dropped before a place is chosen wait, then go to the library chosen', (tester) async {
      api.libs = [lib()];
      await show(tester, BuildPage(build: c, initialFiles: [FakeLocalFile('a.pdf', 100), FakeLocalFile('b.pdf', 100)]));
      expect(find.text('2 PDFs are ready · 200 B'), findsOneWidget);
      expect(uploader.started, isEmpty);
      await tester.tap(find.byKey(const ValueKey('where-existing')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pending-start')));
      await tester.pump();
      await tester.pump();
      expect(api.calls, isEmpty, reason: 'an existing library is not made again');
      expect(uploader.urls.first, '/api/build/upload?library_id=lib1&name=a.pdf');
    });

    testWidgets('Choose PDFs and Choose a folder open the choosers', (tester) async {
      await show(tester, BuildPage(build: c));
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'Books');
      await tester.pump();
      chosen.add([FakeLocalFile('x.pdf', 5)]);
      await tester.tap(find.byKey(const ValueKey('choose-pdfs')));
      await tester.pump();
      await tester.pump();
      expect(uploader.urls, ['/api/build/upload?library_id=lib1&name=x.pdf']);
      uploader.finishAll();
      await tester.pumpAndSettle();
    });

    testWidgets('a folder with no PDF in it sends nothing and says so', (tester) async {
      await show(tester, BuildPage(build: c));
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'Books');
      await tester.pump();
      c.sink!([FakeLocalFile('notes.txt', 5)]);
      await tester.pump();
      await tester.pump();
      expect(uploader.started, isEmpty);
      expect(find.textContaining('There are no PDFs to add.'), findsOneWidget);
    });

    testWidgets('when the disk is full the upload stops with the reason and keeps what was sent', (tester) async {
      await show(tester, BuildPage(build: c));
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'Books');
      await tester.pump();
      c.sink!([for (var i = 0; i < 5; i++) FakeLocalFile('p$i.pdf', 10)]);
      await tester.pump();
      await tester.pump();
      expect(uploader.started.length, 3, reason: 'three at a time');
      uploader.started[1].fail(const DeviceException('no_space', 'x', status: 507));
      await tester.pump();
      uploader.started[0].finish();
      uploader.started[2].finish();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('upload-stopped')), findsOneWidget);
      expect(find.textContaining('Not enough space on this device.'), findsWidgets);
      expect(uploader.started.length, 3, reason: 'no more are started once the disk is full');
      expect(leaving.last, false);
      expect(find.byKey(const ValueKey('open-built')), findsOneWidget);
    });

    testWidgets('Cancel stops what is being sent and lifts the leave warning', (tester) async {
      await show(tester, BuildPage(build: c));
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'Books');
      await tester.pump();
      c.sink!([FakeLocalFile('a.pdf', 10), FakeLocalFile('b.pdf', 10)]);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cancel-batch')));
      await tester.pump();
      expect(uploader.started.every((u) => u.cancelled), isTrue);
      expect(leaving.last, false);
      expect(c.upload, isNull);
    });

    testWidgets('PDFs can be added while the search model is still coming: the page says building waits', (tester) async {
      api.q = queueOf(const [], blocked: 'waiting for the search model');
      await show(tester, BuildPage(build: c));
      expect(find.text('Building is waiting for the search model'), findsOneWidget);
      expect(find.byKey(const ValueKey('choose-pdfs')), findsOneWidget);
    });
  });

  group('A library built from PDFs', () {
    setUp(() {
      api.libs = [lib()];
      api.bookMap['lib1'] = [bookA, bookB];
    });

    testWidgets('lists stored sizes and keeps per-book passages in details', (tester) async {
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      expect(find.text('Hunting and field guides'), findsOneWidget);
      expect(find.text('2 books · 1,124 passages · built from your PDFs'), findsOneWidget);
      expect(find.text('BOOKS · 2'), findsOneWidget);
      expect(find.text('Field Manual 21-76 Survival'), findsOneWidget);
      expect(find.text('412'), findsOneWidget);
      expect(find.text('Stored'), findsOneWidget);
      expect(find.text('1 h ago'), findsWidgets);
      expect(find.text('Add PDFs'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-facts')), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(ValueKey('book-${bookA.id}'))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('book-menu-${bookA.id}')));

      await tester.pumpAndSettle();
      await tester.tap(find.text('Book details'));
      await tester.pumpAndSettle();
      expect(find.text('480 passages'), findsOneWidget);
      expect(find.textContaining('Stored size:'), findsOneWidget);
    });

    testWidgets('an empty library says how to start', (tester) async {
      api.bookMap['lib1'] = [];
      api.libs = [lib(books: 0, passages: 0)];
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      expect(find.text('No books yet'), findsOneWidget);
      expect(find.text('No books in this library yet.'), findsOneWidget);
      expect(find.text('Add PDFs and Cache builds them one at a time.'), findsOneWidget);
      expect(find.text('It keeps going if you close this tab.'), findsOneWidget);
    });

    testWidgets('while building: the queue shows book N of M, the estimate range, the book in hand and "more waiting"', (tester) async {
      api.q = queueOf([
        qitem('i1', 'lib1', 'done', title: 'Done one'),
        qitem('i2', 'lib1', 'building', title: 'Wilderness Medicine Handbook, 7th ed', pieces: 212, total: 480),
        qitem('i3', 'lib1', 'queued', title: 'Waiting A', position: 1),
        qitem('i4', 'lib1', 'queued', title: 'Waiting B', position: 2),
      ], low: 9 * 3600, high: 13 * 3600);
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      expect(find.text('Building Hunting and field guides'), findsOneWidget);
      expect(find.text('1 of 4 books done'), findsOneWidget);
      expect(find.text('Roughly 9 to 13 hours left. This is an estimate and gets better as books finish; scanned books take longer.'), findsOneWidget);
      expect(find.text('Wilderness Medicine Handbook, 7th ed'), findsOneWidget);
      expect(find.text('Building passages · 212 of 480'), findsOneWidget);
      expect(find.text('2 more waiting'), findsOneWidget);
      expect(find.text('BOOKS · 2'), findsNothing);
      expect(find.text('FINISHED BOOKS · 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('show-waiting')));
      await tester.pump();
      expect(find.text('Waiting A'), findsOneWidget);
    });

    testWidgets('Pause becomes Resume, the bar goes amber, and the time left is not counted', (tester) async {
      api.q = queueOf([qitem('i2', 'lib1', 'building', title: 'Book', pieces: 1, total: 4)], low: 3600, high: 7200);
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      await tester.tap(find.byKey(const ValueKey('pause-queue')));
      await tester.pumpAndSettle();
      expect(api.calls, ['pause']);
      expect(find.text('Building is paused'), findsOneWidget);
      expect(find.textContaining('Finished books are kept.'), findsWidgets);
      expect(find.text('Time left is not counted while paused.'), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-eta')), findsNothing);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Building paused. Resume it any time; finished books are kept.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resume-queue')));
      await tester.pumpAndSettle();
      expect(api.calls, ['pause', 'resume']);
      expect(find.text('Pause'), findsOneWidget);
    });

    testWidgets('a book that failed shows why, with Retry and Dismiss; a duplicate is skipped with the name of the one it matches', (tester) async {
      api.q = queueOf([
        qitem('i1', 'lib1', 'building', title: 'Busy', pieces: 1, total: 9),
        qitem('f1', 'lib1', 'failed', title: 'Trapping Fur-bearers, 1952 scan.pdf', error: 'This PDF is protected with a password. Remove the password and add it again, or retry.'),
        qitem('d1', 'lib1', 'skipped_duplicate', title: 'Plant Identification Key', duplicateOf: 'Edible Wild Plants of the Intermountain West'),
        qitem('o1', 'lib1', 'ocr_needed', title: 'Scan only', error: 'No text was found and the pages could not be read as images.'),
      ]);
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      expect(find.text('This PDF is protected with a password. Remove the password and add it again, or retry.'), findsOneWidget);
      expect(find.text('Skipped. The same content is already in this library as "Edible Wild Plants of the Intermountain West".'), findsOneWidget);
      expect(find.text('No text was found and the pages could not be read as images.'), findsOneWidget);
      expect(find.textContaining('2 need attention'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retry-f1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dismiss-d1')));
      await tester.pumpAndSettle();
      expect(api.calls, ['retry f1', 'dismiss d1']);
      expect(find.textContaining('Skipped.'), findsNothing);
    });

    testWidgets('Stop asks first, says what stays, and offers to turn the drop folder off too', (tester) async {
      api.q = queueOf([
        qitem('i0', 'lib1', 'done', title: 'D1'),
        qitem('i1', 'lib1', 'building', title: 'Busy', pieces: 1, total: 9),
        qitem('w1', 'lib1', 'queued', title: 'W1', position: 1),
        qitem('w2', 'lib1', 'queued', title: 'W2', position: 2),
      ]);
      api.dropState = const DropState(settings: DropSettings(folder: '/srv/cache/ingest', enabled: true, libraryId: 'lib1'));
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      await tester.tap(find.byKey(const ValueKey('stop-queue')));
      await tester.pumpAndSettle();
      expect(find.text('Stop building Hunting and field guides?'), findsOneWidget);
      expect(find.textContaining('The 2 books still waiting are taken off the list. The 2 finished books and the one being built now stay. You can add the PDFs again later.'), findsOneWidget);
      expect(find.text('Also turn off the drop folder'), findsOneWidget);
      expect(find.text('Otherwise PDFs in it are picked up again at the next check.'), findsOneWidget);
      // Keep building leaves everything as it was
      await tester.tap(find.byKey(const ValueKey('keep-building')));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('stop-queue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('also-off')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stop-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, ['put-drop folder=null enabled=false library=null', 'stop']);
    });

    testWidgets('Stop without the box leaves the drop folder as it is', (tester) async {
      api.q = queueOf([qitem('i1', 'lib1', 'building', title: 'Busy', pieces: 1, total: 9), qitem('w1', 'lib1', 'queued', title: 'W1', position: 1)]);
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      await tester.tap(find.byKey(const ValueKey('stop-queue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stop-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, ['stop']);
    });

    testWidgets('waiting for the search model is said in the queue', (tester) async {
      api.q = queueOf([qitem('w1', 'lib1', 'queued', title: 'W1', position: 1)], blocked: 'waiting for the search model');
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      expect(find.text('Waiting for the search model'), findsOneWidget);
      expect(find.text('Waiting'), findsNothing, reason: 'waiting books sit behind "more waiting"');
    });

    testWidgets('Edit title is inline: Save changes only the title; Use file name puts the file name back', (tester) async {
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      final row = find.byKey(const ValueKey('book-a'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(row));
      await tester.pump();
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('edit-a')));
      await tester.pump();
      expect(find.text('Only this title changes. The passages are not rebuilt.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('title-field')), 'Survival Field Manual');
      await tester.tap(find.byKey(const ValueKey('save-title')));
      await tester.pumpAndSettle();
      expect(api.calls, ['rename-book a Survival Field Manual']);
      expect(find.text('Survival Field Manual'), findsOneWidget);
      expect(find.text('Title changed.'), findsOneWidget);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('edit-a')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('use-file-name')));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'fm21-76'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-title')));
      await tester.pump();
      expect(find.byKey(const ValueKey('title-field')), findsNothing);
    });

    testWidgets('a title that is the file name says the PDF had none', (tester) async {
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      final row = find.byKey(const ValueKey('book-b'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(row));
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('edit-b')));
      await tester.pump();
      expect(find.textContaining('This PDF has no title inside it, so the file name is used: mushrooms_demystified_2nd_ed_OCR.pdf.'), findsOneWidget);
    });

    testWidgets('Remove asks first, says the PDF on the computer is untouched, and takes only that book away', (tester) async {
      c.freeSpace = () => 61 << 30;
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      final row = find.byKey(const ValueKey('book-a'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(row));
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('book-menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Field Manual 21-76 Survival from Hunting and field guides?'), findsOneWidget);
      expect(find.textContaining('Your PDF on this computer is not deleted. To get it back, add the PDF again.'), findsOneWidget);
      expect(find.text('Frees'), findsOneWidget);
      expect(find.textContaining('1.0 MB · 480 passages'), findsOneWidget);
      expect(find.textContaining('61.0 GB free now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('remove-cancel')));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('book-menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, ['remove-book a']);
      expect(find.text('Book removed.'), findsOneWidget);
      expect(find.text('Field Manual 21-76 Survival'), findsNothing);
    });

    testWidgets('Replace with a newer edition takes one PDF and sends it to that book', (tester) async {
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      final row = find.byKey(const ValueKey('book-a'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(row));
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('book-menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace with a newer edition'));
      await tester.pumpAndSettle();
      expect(find.text('Replace Field Manual 21-76 Survival with a newer edition?'), findsOneWidget);
      expect(find.textContaining('Only this book is rebuilt. The current one stays searchable until the new one is ready, then it is swapped in.'), findsOneWidget);
      chosen.add([FakeLocalFile('fm21-76 (2).pdf', 50)]);
      await tester.tap(find.byKey(const ValueKey('choose-one-pdf')));
      await tester.pumpAndSettle();
      expect(uploader.urls, ['/api/build/libraries/lib1/books/a/replace?name=fm21-76%20(2).pdf']);
      expect(find.textContaining('Uploading the new copy of Field Manual 21-76 Survival'), findsWidgets);
      uploader.finishAll();
      await tester.pumpAndSettle();
      expect(leaving, [true, false]);
    });

    testWidgets('Rename library is in the library menu and says when the name is taken', (tester) async {
      api.libs = [lib(), lib(id: 'lib2', title: 'Garden')];
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      await tester.tap(find.byKey(const ValueKey('library-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename library'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'garden');
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rename-error')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'Hunting');
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      expect(api.calls, ['rename-library lib1 Hunting']);
      expect(find.text('Hunting'), findsOneWidget);
    });

    testWidgets('PDFs dropped on the page join this library', (tester) async {
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      c.sink!([FakeLocalFile('new.pdf', 10)]);
      await tester.pump();
      await tester.pump();
      expect(uploader.urls, ['/api/build/upload?library_id=lib1&name=new.pdf']);
      expect(api.calls, isEmpty);
      expect(find.text('Uploading 1 PDF. Keep this tab open.'), findsOneWidget);
      uploader.finishAll();
      await tester.pumpAndSettle();
      // the words go when the upload ends, not when the toast's own time is up
      expect(find.text('Uploading 1 PDF. Keep this tab open.'), findsNothing);
    });

    testWidgets('Delete is in the library menu, asks first, and the library goes', (tester) async {
      api.libs = [lib(books: 0, passages: 0), lib(id: 'lib2', title: 'Garden')];
      await show(tester, BuiltLibraryPage(build: c, libraryId: 'lib1'));
      await tester.tap(find.byKey(const ValueKey('library-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Delete · frees'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Hunting and field guides?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('library-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Delete · frees'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await tester.pumpAndSettle();
      expect(api.calls, ['delete-library lib1']);
      expect(c.libraries.map((l) => l.id), ['lib2']);
    });
  });

  group('The drop folder', () {
    DropFile f(String name, String folder, String state, {int? position, String? reason, bool canRetry = false, String? note, QueueProgress? progress}) =>
        DropFile(name: name, folder: folder, state: state, position: position, reason: reason, canRetry: canRetry, note: note, progress: progress);

    testWidgets('off: the folder, the key, where PDFs go, and Turn on drop folder once a library is chosen', (tester) async {
      api.libs = [lib(books: 214)];
      api.dropState = const DropState(settings: DropSettings(folder: '/srv/cache/ingest'));
      await show(tester, DropFolderPage(build: c));
      expect(find.text('Drop folder'), findsOneWidget);
      expect(find.text('FOLDER ON THIS DEVICE'), findsOneWidget);
      expect(find.text('ingest/'), findsOneWidget);
      expect(find.text('Drop files here. This is the queue.'), findsOneWidget);
      expect(find.text('Added or built. Duplicates too, they are already in the library.'), findsOneWidget);
      expect(find.text('Could not be used, with a note saying why.'), findsOneWidget);
      expect(find.text('PDFS GO INTO'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('turn-on'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('drop-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-lib1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('turn-on')));
      await tester.pumpAndSettle();
      expect(api.calls, ['put-drop folder=/srv/cache/ingest enabled=true library=lib1']);
      expect(find.text('Turn off drop folder'), findsOneWidget);
    });

    testWidgets('on: counts, the queue in order with positions and progress, failed with Retry, complete newest first', (tester) async {
      api.libs = [lib(books: 214)];
      api.dropState = DropState(
        settings: const DropSettings(folder: '/srv/cache/ingest', enabled: true, libraryId: 'lib1', libraryTitle: 'Hunting and field guides'),
        status: DropStatus(state: 'ok', lastCheck: DateTime.now().subtract(const Duration(minutes: 2)), found: 2, all: 44, queue: 4, complete: 38, failed: 2),
        files: [
          f('Edible Plants of Idaho.pdf', 'ingest', 'working', position: 1, progress: const QueueProgress(pieces: 212, piecesTotal: 480)),
          f('wikivoyage_en_all.zim', 'ingest', 'queued', position: 2),
          f('Trapping 1952 scan.pdf', 'failed', 'failed', reason: 'This PDF is protected with a password.', canRetry: true, note: 'Trapping 1952 scan.pdf.why.txt'),
          f('backup-2026-10.tar', 'failed', 'unsupported', reason: 'Not a file Cache can use'),
          f('Where There Is No Doctor.pdf', 'complete', 'done'),
          f('wilderness_med_7e.pdf', 'complete', 'duplicate', reason: 'Duplicate: the same content is already in Wilderness Medicine Handbook, 7th ed'),
        ],
      );
      await show(tester, DropFolderPage(build: c));
      expect(find.text('On'), findsOneWidget);
      expect(find.text('Last checked 2 min ago'), findsOneWidget);
      expect(find.text('/srv/cache/ingest'), findsOneWidget);
      expect(find.text('Hunting and field guides'), findsOneWidget);
      expect(find.text('All · 44'), findsOneWidget);
      expect(find.text('Queue in ingest/ · 4'), findsOneWidget);
      expect(find.text('complete/ · 38'), findsOneWidget);
      expect(find.text('failed/ · 2'), findsOneWidget);
      expect(find.text('Last check 2 min ago: 2 new files found.'), findsOneWidget);
      expect(find.text('Working · building passages 212 of 480'), findsOneWidget);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Library file'), findsWidgets);
      expect(find.textContaining('Not a file Cache can use.'), findsOneWidget, reason: 'the reason, one full stop, no note file name');
      expect(find.byKey(const ValueKey('drop-retry-backup-2026-10.tar')), findsNothing);
      expect(find.textContaining('Duplicate: the same content is already in Wilderness Medicine Handbook, 7th ed'), findsOneWidget);
      expect(find.textContaining('This PDF is protected with a password.'), findsOneWidget, reason: 'the reason as the device gave it, one full stop');
      expect(find.textContaining('why.txt'), findsNothing);
      expect(find.textContaining('Note:'), findsNothing);
      expect(find.textContaining('..'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('drop-retry-Trapping 1952 scan.pdf')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('check-now')));
      await tester.pump();
      expect(api.calls, ['retry-drop Trapping 1952 scan.pdf', 'check-drop']);
      // the chips narrow the table
      await tester.tap(find.byKey(const ValueKey('chip-failed')));
      await tester.pump();
      expect(find.text('Edible Plants of Idaho.pdf'), findsNothing);
      expect(find.text('Trapping 1952 scan.pdf'), findsOneWidget);
    });

    test('a reason is shown as one sentence with one full stop', () {
      expect(oneSentence('The file is damaged and could not be opened.'), 'The file is damaged and could not be opened.');
      expect(oneSentence('Not a file Cache can use'), 'Not a file Cache can use.');
      expect(oneSentence('Scanned. '), 'Scanned.');
      expect(oneSentence('Could not be opened..'), 'Could not be opened.');
      expect(oneSentence(''), '');
    });

    testWidgets('a missing folder is a banner, the table is the last known state, and Check now is offered', (tester) async {
      api.libs = [lib()];
      api.dropState = DropState(
        settings: const DropSettings(folder: '/mnt/usb/ingest', enabled: true, libraryId: 'lib1'),
        status: DropStatus(state: 'error', lastCheck: DateTime.now().subtract(const Duration(minutes: 4)), all: 1, queue: 1, error: const DropError('missing', 'The drop folder is missing'), stale: true),
        files: [f('a.pdf', 'ingest', 'queued', position: 1)],
      );
      await show(tester, DropFolderPage(build: c));
      expect(find.text('The drop folder is missing'), findsOneWidget);
      expect(find.textContaining('It may be on a USB disk that is not connected. Nothing is lost'), findsOneWidget);
      expect(find.text('Waiting for the folder'), findsOneWidget);
      expect(find.text('Last known state. Nothing has been checked since the folder went missing.'), findsOneWidget);
      expect(find.text('Choose another folder'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('banner-check')));
      await tester.pump();
      expect(api.calls, ['check-drop']);
    });

    testWidgets('no permission is its own banner, and no library chosen asks for one', (tester) async {
      api.libs = [lib()];
      api.dropState = const DropState(
        settings: DropSettings(folder: '/root/ingest', enabled: true, libraryId: 'lib1'),
        status: DropStatus(state: 'error', error: DropError('denied', 'Cache can not read the drop folder'), stale: true),
      );
      await show(tester, DropFolderPage(build: c));
      expect(find.text('Cache can not read the drop folder'), findsOneWidget);
      expect(find.textContaining('Cache is not allowed to open this folder.'), findsOneWidget);
      api.dropState = const DropState(
        settings: DropSettings(folder: '/srv/ingest', enabled: true),
        status: DropStatus(state: 'ok', error: DropError('no_library', 'Choose the library the PDFs go into')),
      );
      await tester.runAsync(c.refresh);
      await tester.pump();
      expect(find.text('Choose the library the PDFs go into'), findsOneWidget);
      expect(find.byKey(const ValueKey('banner-library')), findsOneWidget);
    });
  });

  group('While this tab was closed', () {
    testWidgets('says how many books were built, failed and skipped, and what is still building', (tester) async {
      api.libs = [lib()];
      fs.files['support:$kBuildSeenFile'] = '{"done":10,"failed":0,"skipped":0}';
      api.q = queueOf([
        for (var i = 0; i < 85; i++) qitem('d$i', 'lib1', 'done'),
        qitem('f1', 'lib1', 'failed', error: 'x'),
        qitem('s1', 'lib1', 'skipped_duplicate'),
        qitem('b1', 'lib1', 'building', pieces: 1, total: 9),
      ]);
      await tester.runAsync(c.start);
      expect(c.whileClosed, [
        '75 books were built.',
        'Hunting and field guides is still building.',
        "1 book couldn't be built.",
        '1 book was skipped as a duplicate.',
      ]);
      await tester.runAsync(() => c.dismissWhileClosed());
      expect(c.whileClosed, isEmpty);
      expect(fs.files['support:$kBuildSeenFile'], contains('"done":85'));
    });
  });

  group('words', () {
    test('the time left is a range, in hours or minutes', () {
      expect(etaRange(9 * 3600, 13 * 3600), '9 to 13 hours');
      expect(etaRange(20 * 60, 35 * 60), '20 to 35 minutes');
      expect(etaRange(10, 40), 'less than a minute');
      expect(etaShort(9 * 3600, 13 * 3600), '9 to 13 h');
    });

    test('the width class starts at 1280', () {
      expect(kDesktopMinWidth, 1280);
      expect(kDesktopListWidth, 380);
      expect(kDesktopDetailMaxWidth, 1400);
    });
  });
}

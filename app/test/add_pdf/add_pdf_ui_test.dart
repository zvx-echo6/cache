import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf_fixtures.dart';
import 'add_pdf_world.dart';

const _charging = BatteryReading(percent: 80, charging: true);
const _low = BatteryReading(percent: 38, charging: false);
const PickedPdf _water = (path: '/tmp/none.pdf', name: 'Water purification manual.pdf', bytes: 43 << 20);

void main() {
  late AddPdfWorld w;

  tearDown(() => w.dispose());

  void size(WidgetTester tester, [Size s = const Size(390, 844)]) {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget home) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: home);
  Widget panes() => LibraryPanes(root: (_) => LibraryRootPage(deps: w.deps), prefs: PanePrefs(dirOverride: w.tmp));
  Widget progress() => AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler);

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

  testWidgets('1. Where you start: Add a PDF under Your own in Add to Library, and Add PDF on Bookshelves', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    await tester.pumpWidget(app(AddToLibraryScreen(browse: w.browse)));
    await settle(tester);
    expect(find.text('Your own library'), findsOneWidget);
    expect(find.text('Add a PDF'), findsOneWidget);
    expect(find.text('A manual or a scanned book'), findsOneWidget);
    await tester.pumpWidget(app(panes()));
    await settle(tester);
    await tapKey(tester, 'library-bookshelves');
    expect(find.byKey(const ValueKey('shelves-add-pdf')), findsOneWidget);
    expect(find.text('Add PDF'), findsOneWidget);
  });

  testWidgets('2. The first time only My books, named once; Change opens the sheet of the libraries the person made', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make(own: false, myBooks: false));
    await tester.pumpWidget(app(AddPdfConfirmPage(state: w.state, pdf: _water, battery: _charging)));
    await settle(tester);
    expect(find.text('My books'), findsOneWidget);
    expect(find.text('New. Your own PDFs go here. It syncs like any library.'), findsOneWidget);
    await tapKey(tester, 'add-pdf-change');
    expect(find.text('Which library?'), findsOneWidget);
    expect(find.text('My books · Default'), findsOneWidget);
    expect(find.text('Field library'), findsNothing, reason: 'not one the person made');
    expect(find.text('Only libraries you made. Search covers all of them.'), findsOneWidget);
  });

  testWidgets('2. Later: the sheet lists My books and the other libraries of their own; a pick changes the Library line', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    await tester.pumpWidget(app(AddPdfConfirmPage(state: w.state, pdf: _water, battery: _charging)));
    await settle(tester);
    expect(find.text('New. Your own PDFs go here. It syncs like any library.'), findsNothing);
    await tapKey(tester, 'add-pdf-change');
    expect(find.text('My books · Default'), findsOneWidget);
    expect(find.text('Field library'), findsOneWidget);
    expect(find.text('Homestead library'), findsOneWidget);
    await tester.tap(find.text('Field library'));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('add-pdf-library'))).data, 'Field library');
  });

  testWidgets('3. Confirm: the title from the file, the size, one time estimate in the indexing rules words', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    await tester.pumpWidget(app(AddPdfConfirmPage(state: w.state, pdf: _water, battery: _charging)));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('add-pdf-title'))).controller!.text, 'Water purification manual');
    expect(find.text('43.0 MB'), findsOneWidget);
    expect(find.text('About 4 min while charging'), findsOneWidget);
    expect(find.text('On battery it waits for charging. You can use Cache meanwhile.'), findsOneWidget);
    expect(find.text('Add PDF'), findsWidgets);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.pumpWidget(app(AddPdfConfirmPage(key: const ValueKey('big'), state: w.state, pdf: (path: '/tmp/none.pdf', name: 'Field radio handbook.pdf', bytes: 212 << 20), battery: _low)));
    await settle(tester);
    expect(find.text('212 MB'), findsOneWidget);
    expect(find.text('About 21 min while charging'), findsOneWidget);
    expect(find.text('Longer if pages are scans. This phone is at 38%, so it starts when plugged in.'), findsOneWidget);
  });

  testWidgets('4. Progress: the Library card names the PDF and its phase; the page shows the phases in order', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.runOne();
    await tester.pumpWidget(app(panes()));
    await settle(tester);
    expect(find.text('Getting search ready · 0 of 3 done'), findsOneWidget);
    expect(find.text('Water purification manual · Reading scanned pages (OCR)'), findsOneWidget);
    expect(find.textContaining('1 being added'), findsOneWidget);
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('ADDING A PDF'), findsOneWidget);
    for (final t in ['Reading pages', 'Reading scanned pages (OCR)', 'Making it searchable', 'Saving', '310 pages', 'Page 41 of 82 scans', 'You can leave this screen. It keeps going.']) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    expect(find.textContaining('left while charging'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
  });

  testWidgets('4. Held: battery, charging, heat and the person, in the indexing rules words, each with its one action', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.holdAll();
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('Paused · battery low · plug in to continue'), findsOneWidget);
    expect(find.text('Resume anyway'), findsOneWidget);
    expect(find.text('Waits for charging (long job)'), findsOneWidget);
    expect(find.text('Start now'), findsOneWidget);
    expect(find.text('Slowed down · keeping the device cool'), findsOneWidget);
    expect(find.text('Paused by you · Resume'), findsOneWidget);
    expect(find.text('Making it searchable 62%'), findsOneWidget);
    await tester.tap(find.text('Start now'));
    await settle(tester);
    expect(w.state.byId('charging')!.startNow, isTrue);
  });

  testWidgets('4. Cancel asks once; Keep going keeps it, Stop adding removes it', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.runOne();
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    await tapKey(tester, 'add-pdf-cancel-job');
    expect(find.text('Stop adding this PDF?'), findsOneWidget);
    expect(find.text('Nothing has been added to your library. Your PDF is not changed.'), findsOneWidget);
    await tapKey(tester, 'add-pdf-keep-going');
    expect(w.state.jobs, hasLength(1));
    await tapKey(tester, 'add-pdf-cancel-job');
    await tapKey(tester, 'add-pdf-stop');
    expect(w.state.jobs, isEmpty);
  });

  testWidgets('5. Done, filed: where it went, Move and Undo; Undo puts it back in Unsorted and keeps the book', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.done(w.filed);
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('Added to My books · 254 pieces searchable'), findsOneWidget);
    expect(find.text('Filed in 530 Water treatment'), findsOneWidget);
    expect(find.text('CDS 530-004'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Open book'), findsOneWidget);
    final before = w.shelves.unsorted.length;
    await tapKey(tester, 'add-pdf-undo-filed');
    await tester.runAsync(() => w.shelves.whenRead());
    expect(w.shelves.book('water')!.shelf, isNull, reason: 'back in Unsorted');
    expect(w.shelves.unsorted.length, before + 1, reason: 'never deleted');
  });

  testWidgets('5. The book page shows the note once', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.done(w.filed);
    await tester.pumpWidget(app(panes()));
    await settle(tester);
    for (final k in ['library-bookshelves', 'shelf-500', 'shelf-530', 'book-water']) {
      await tapKey(tester, k);
    }
    expect(find.text('Filed in 530 Water treatment'), findsOneWidget);
    expect(w.state.byId('filed')!.noteSeen, isTrue);
  });

  testWidgets('6. Done, not confident: In Unsorted, the sorter guess, Place; Place files it there', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.done(w.unsure);
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('Added to My books · searchable'), findsOneWidget);
    expect(find.text('In Unsorted'), findsOneWidget);
    expect(find.text('Looks like 720 Amateur radio operating. Place it there?'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
    await tapKey(tester, 'add-pdf-place-unsure');
    await tester.runAsync(() => w.shelves.whenRead());
    expect(w.shelves.book('radio')!.shelf, '720');
  });

  testWidgets('7. The same book as one you have: a spare copy, the book and its number named', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.done(w.spare);
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('Added to My books'), findsOneWidget);
    expect(find.text('A spare copy of an existing book'), findsOneWidget);
    expect(find.text('Same file as Water purification manual, CDS 530-001. It shares that number.'), findsOneWidget);
    expect(find.text('Not the same book'), findsOneWidget);
  });

  testWidgets('8. Errors in plain words, each with what is safe and one next step; busy is a calm wait', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.errors(w.errorsA);
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('No readable text'), findsOneWidget);
    expect(find.text('This PDF is scans, and reading scanned pages is off.'), findsOneWidget);
    expect(find.text('Turn on scanned pages'), findsOneWidget);
    expect(find.text('Scanned pages could not be read'), findsOneWidget);
    expect(find.text('They may be too faint or blank. A clearer scan may work.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Waiting for another PDF'), findsOneWidget);
    expect(find.text('One is being saved. This one goes next.'), findsOneWidget);
    w.errors(w.errorsB);
    await settle(tester);
    expect(find.text("This file can't be read"), findsOneWidget);
    expect(find.text('It may not be a PDF, or it may be damaged. Your file was not changed.'), findsOneWidget);
    expect(find.text('This PDF has a password'), findsOneWidget);
    expect(find.text('Remove the password, then add it again.'), findsOneWidget);
    expect(find.text('Needs 380 MB free'), findsOneWidget);
    expect(find.text('Nothing was added. Your PDF was not changed.'), findsOneWidget);
    expect(find.text('Choose another file'), findsNWidgets(2));
  });

  testWidgets('8. The Library card when a PDF stopped: "Stopped: ..." in the danger color', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.stopped();
    await tester.pumpWidget(app(panes()));
    await settle(tester);
    expect(find.text('Getting search ready · 0 of 2 done'), findsOneWidget);
    final t = tester.widget<Text>(find.text('Water purification manual · Stopped: no readable text'));
    expect(t.style?.color, buildTheme(CacheThemeId.light).extension<CacheTokens>()!.emergency);
  });

  testWidgets('9. Wide: the card opens Adding a PDF beside the Library, with the book card above the phases', (tester) async {
    size(tester, const Size(1440, 900));
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.runOne();
    await tester.pumpWidget(app(panes()));
    await settle(tester);
    await tapKey(tester, 'index-overview');
    expect(find.text('Adding a PDF'), findsOneWidget);
    expect(find.text('Number comes when it is saved'), findsOneWidget);
    expect(find.text('43.0 MB · My books'), findsOneWidget);
    expect(sampleJob('x').key, 'pdf-add/x');
    expect(AddPdfStatus.values, hasLength(3));
  });

  testWidgets('Several PDFs: the count, the total size and one time; no title to edit; Add queues them all to one library', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    final choice = AddPdfChoice(const [
      (path: '/tmp/a.pdf', name: 'Water purification manual.pdf', bytes: 30 << 20),
      (path: '/tmp/b.pdf', name: 'Field radio handbook.pdf', bytes: 40 << 20),
      (path: '/tmp/c.pdf', name: 'Root cellar plans.pdf', bytes: 14 << 20),
    ]);
    await tester.pumpWidget(app(AddPdfConfirmPage(state: w.state, choice: choice, battery: _charging)));
    await settle(tester);
    expect(find.text('3 PDFs · 84.0 MB · About 8 min while charging'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-pdf-title')), findsNothing);
    expect(find.text('Add 3 PDFs'), findsOneWidget);
    expect(find.textContaining('They are added one at a time. A book you already have becomes a spare copy.'), findsOneWidget);
    await tester.tap(find.text('Add 3 PDFs'));
    await settle(tester);
    await settle(tester);
    expect([for (final j in w.state.jobs) j.title]..sort(), ['Field radio handbook', 'Root cellar plans', 'Water purification manual']);
    expect({for (final j in w.state.jobs) j.libraryTitle}, {'My books'});
    expect({for (final j in w.state.jobs) j.id}, hasLength(3), reason: 'each its own job');
  });

  testWidgets('A folder: its name, "This folder and its subfolders", the PDFs in it, and the other files left out', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    final choice = AddPdfChoice(const [
      (path: 'Water/Water purification manual.pdf', name: 'Water purification manual.pdf', bytes: 30 << 20),
      (path: 'Radio/Field radio handbook.pdf', name: 'Field radio handbook.pdf', bytes: 40 << 20),
    ], folder: 'Field manuals', folderRoot: '/tmp/field-manuals', skipped: 2);
    await tester.pumpWidget(app(AddPdfConfirmPage(state: w.state, choice: choice, battery: _charging)));
    await settle(tester);
    expect(find.text('Add a folder'), findsOneWidget);
    expect(find.text('Field manuals'), findsOneWidget);
    expect(find.text('This folder and its subfolders'), findsOneWidget);
    expect(find.text('2 PDFs · 70.0 MB · About 7 min while charging'), findsOneWidget);
    expect(find.textContaining('2 files that are not a PDF are left out.'), findsOneWidget);
    await tester.tap(find.text('Add 2 PDFs'));
    await settle(tester);
    await settle(tester);
    final jobs = w.state.jobs;
    expect(jobs, hasLength(2));
    expect({for (final j in jobs) j.folderRoot}, {'/tmp/field-manuals'});
    expect({for (final j in jobs) j.sourcePath}, {'Water/Water purification manual.pdf', 'Radio/Field radio handbook.pdf'});
  });

  testWidgets('Add to Library has Add a folder under Add a PDF', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    await tester.pumpWidget(app(AddToLibraryScreen(browse: w.browse)));
    await settle(tester);
    expect(find.text('Add a folder'), findsOneWidget);
    expect(find.text('Every PDF in it and its subfolders'), findsOneWidget);
  });

  testWidgets('Several queued: the one running shows its phases, the others wait their turn', (tester) async {
    size(tester, const Size(390, 1400));
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.queueSeveral();
    await tester.pumpWidget(app(progress()));
    await settle(tester);
    expect(find.text('Reading scanned pages (OCR)'), findsWidgets);
    expect(find.text('Waiting to add a PDF'), findsNWidgets(2));
  });
}

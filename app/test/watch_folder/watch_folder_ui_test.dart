// Watch a folder's screens (the owner's mockups, watch-folder-mockups.html): where you start it in Add to Library, the confirm
// screen (Android and iPhone), the Watched folders list (Check now, Stop watching asks once, a PDF that couldn't be added, the
// folder that can't be reached and Choose again), and what a check added (the folder's tag, the Library card, one summary).

import 'dart:io';

import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'watch_world.dart';

const _charging = BatteryReading(percent: 80, charging: true);

AddPdfChoice _twelve(String root) => AddPdfChoice([
  for (var i = 1; i <= 12; i++) (path: 'Manual $i.pdf', name: 'Manual $i.pdf', bytes: 70 << 20),
], folder: 'Manuals', folderRoot: root);

void main() {
  late WatchWorld w;

  tearDown(() {
    w.dispose();
    addPdfFolderPicker = pickPdfFolder;
    watchChecksInBackground = () => Platform.isAndroid;
  });

  void size(WidgetTester tester, [Size s = const Size(390, 844)]) {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget home) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: home);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f.first);
    await tester.tap(f.first);
    await settle(tester);
  }

  testWidgets('1. Where you start: Watch a folder under Add a folder; once watched, the row is Watched folders with the count', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    await tester.pumpWidget(app(AddToLibraryScreen(browse: w.pdf.browse)));
    await settle(tester);
    expect(find.text('Add a folder'), findsOneWidget);
    expect(find.text('Watch a folder'), findsOneWidget);
    expect(find.text('New PDFs in it are added on their own'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Watch a folder')).dy, greaterThan(tester.getTopLeft(find.text('Add a folder')).dy));
    w.two();
    await settle(tester);
    expect(find.text('Watched folders'), findsOneWidget);
    expect(find.text('2 folders · checked 2 hours ago'), findsOneWidget);
    // a folder that can't be reached shows on the row
    w.unreachable();
    await settle(tester);
    expect(find.text('2 folders'), findsOneWidget);
    expect(find.text("1 can't be reached"), findsOneWidget);
    // the row opens the list
    await tapKey(tester, 'watch-folder');
    expect(find.byType(WatchedFoldersPage), findsOneWidget);
  });

  testWidgets('1b. The first time, the row starts the folder picker, then the confirm screen', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    addPdfFolderPicker = () async => _twelve('/tmp/manuals');
    await tester.pumpWidget(app(AddToLibraryScreen(browse: w.pdf.browse)));
    await settle(tester);
    await tapKey(tester, 'watch-folder');
    expect(find.byType(WatchFolderConfirmPage), findsOneWidget);
    expect(find.text('Manuals'), findsOneWidget);
  });

  testWidgets('2. Confirm on Android: in it now, the library, when it checks, the two ways to start, the removed-file line', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    await tester.pumpWidget(app(WatchFolderConfirmPage(watch: w.watch, state: w.pdf.state, choice: _twelve('/tmp/manuals'), battery: _charging, background: true)));
    await settle(tester);
    expect(find.text('Watch a folder'), findsOneWidget);
    expect(find.text('This folder and its subfolders'), findsOneWidget);
    expect(find.text('In it now'), findsOneWidget);
    expect(find.text('12 PDFs · 840 MB · About 84 min while charging'), findsOneWidget);
    expect(find.text('Longer if pages are scans. A book you already have becomes a spare copy.'), findsOneWidget);
    expect(find.text('My books'), findsOneWidget);
    expect(find.text('When you open Cache, and in the background'), findsOneWidget);
    expect(find.text('The background check follows the indexing rules: charging, battery and temperature.'), findsOneWidget);
    expect(find.text('Watch and add 12 PDFs'), findsOneWidget);
    expect(find.text('Watch new PDFs only'), findsOneWidget);
    expect(find.text('A PDF you remove from this folder stays in Cache.'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('2b. Confirm on iPhone: on open only, said plainly', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    await tester.pumpWidget(app(WatchFolderConfirmPage(watch: w.watch, state: w.pdf.state, choice: _twelve('/tmp/manuals'), battery: _charging, background: false)));
    await settle(tester);
    expect(find.text('Each time you open Cache'), findsOneWidget);
    expect(find.text('Apple does not allow a folder to be watched in the background.'), findsOneWidget);
  });

  testWidgets('2c. Watch new PDFs only: the folder is watched, nothing is added, and the list shows it', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    final dir = Directory('${w.pdf.tmp.path}/Manuals')..createSync();
    File('${dir.path}/a.pdf').writeAsStringSync('one');
    final choice = AddPdfChoice(const [(path: 'a.pdf', name: 'a.pdf', bytes: 3)], folder: 'Manuals', folderRoot: dir.path);
    await tester.pumpWidget(app(WatchFolderConfirmPage(watch: w.watch, state: w.pdf.state, choice: choice, battery: _charging, background: true)));
    await settle(tester);
    expect(find.text('Watch and add 1 PDF'), findsOneWidget);
    await tapKey(tester, 'watch-new-only');
    await settle(tester);
    expect(find.byType(WatchedFoldersPage), findsOneWidget);
    expect(w.watch.folders.single.name, 'Manuals');
    expect(w.pdf.state.jobs, isEmpty);
    expect(find.text('Goes to My books'), findsOneWidget);
    expect(find.text('0 PDFs added so far'), findsOneWidget);
  });

  testWidgets('2d. Watch and add: the PDFs in the folder are queued through Add PDF, tagged with the folder', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    final dir = Directory('${w.pdf.tmp.path}/Manuals')..createSync();
    File('${dir.path}/a.pdf').writeAsStringSync('one');
    File('${dir.path}/b.pdf').writeAsStringSync('two');
    final choice = AddPdfChoice(const [(path: 'a.pdf', name: 'a.pdf', bytes: 3), (path: 'b.pdf', name: 'b.pdf', bytes: 3)], folder: 'Manuals', folderRoot: dir.path);
    await tester.pumpWidget(app(WatchFolderConfirmPage(watch: w.watch, state: w.pdf.state, choice: choice, battery: _charging, background: true)));
    await settle(tester);
    await tapKey(tester, 'watch-add');
    // the first check reads the folder: real file reads, given real time
    for (var i = 0; i < 60 && w.pdf.state.jobs.length < 2; i++) {
      await settle(tester);
    }
    expect(w.pdf.state.jobs, hasLength(2));
    expect(w.pdf.state.jobs.every((j) => j.watchName == 'Manuals'), isTrue);
  });

  testWidgets('3. The list: last check, count, library, Check now, Watch a folder; the line on top differs by phone', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    w.two();
    await tester.pumpWidget(app(WatchedFoldersPage(watch: w.watch, background: true)));
    await settle(tester);
    expect(find.text('Checked when you open Cache, and in the background while charging.'), findsOneWidget);
    expect(find.text('Manuals'), findsOneWidget);
    expect(find.text('Download/Manuals · and subfolders'), findsOneWidget);
    expect(find.text('Checked 2 hours ago'), findsOneWidget);
    expect(find.text('7 PDFs added so far'), findsOneWidget);
    expect(find.text('Checked yesterday'), findsOneWidget);
    expect(find.text('3 PDFs added so far'), findsOneWidget);
    expect(find.text('Goes to My books'), findsNWidgets(2));
    expect(find.text('Check now'), findsNWidgets(2));
    expect(find.text('Stop watching'), findsNWidgets(2));
    expect(find.text('Watch a folder'), findsOneWidget);
    expect(find.text('A PDF removed from a folder stays in Cache.'), findsOneWidget);
    w.checking();
    await tester.pumpWidget(app(WatchedFoldersPage(watch: w.watch, background: false)));
    await settle(tester);
    expect(find.text('Checked each time you open Cache. Apple does not allow background checks.'), findsOneWidget);
    expect(find.text('Checking now'), findsOneWidget);
    expect(find.text('Checking'), findsOneWidget);
    expect(find.text('Check now'), findsOneWidget);
  });

  testWidgets('3b. Stop watching asks once and says what stays', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    w.two();
    await tester.pumpWidget(app(WatchedFoldersPage(watch: w.watch, background: true)));
    await settle(tester);
    await tapKey(tester, 'watch-stop-manuals');
    expect(find.text('Stop watching Manuals?'), findsOneWidget);
    expect(find.text('The 7 PDFs already added stay in your library. New PDFs in the folder are no longer added.'), findsOneWidget);
    await tapKey(tester, 'watch-keep');
    expect(w.watch.folders, hasLength(2));
    await tapKey(tester, 'watch-stop-manuals');
    await tapKey(tester, 'watch-stop-yes');
    expect(w.watch.folders.single.name, 'Field guides');
    expect(find.text('Manuals'), findsNothing);
  });

  testWidgets("3c. A PDF that couldn't be added: counted on the folder's card, with Try again", (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    w.skipped();
    await tester.pumpWidget(app(WatchedFoldersPage(watch: w.watch, background: true)));
    await settle(tester);
    expect(find.text("1 couldn't be added"), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-try-again-manuals')), findsOneWidget);
  });

  testWidgets("5. A folder that can't be reached: the red card, Choose again; the others keep their Check now", (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    w.unreachable();
    await tester.pumpWidget(app(WatchedFoldersPage(watch: w.watch, background: true)));
    await settle(tester);
    expect(find.text("Can't reach this folder"), findsOneWidget);
    expect(find.text('Last checked 3 days ago · 7 PDFs added so far'), findsOneWidget);
    expect(find.text('It may have been moved or renamed, or access was turned off. Checks for it are paused. PDFs already added are not affected.'), findsOneWidget);
    expect(find.text('Check now'), findsOneWidget);
    await tapKey(tester, 'watch-choose-again-manuals');
    expect(find.widgetWithText(AppBar, 'Choose again'), findsOneWidget);
    expect(find.text('Pick Manuals again'), findsOneWidget);
    expect(find.text('Choose the same folder, or a different one.'), findsOneWidget);
    expect(find.text('Not chosen'), findsOneWidget);
    expect(find.text('Unchanged'), findsOneWidget);
    expect(find.text('PDFs already added stay. Anything already added from this folder is skipped as a spare copy, not added twice.'), findsOneWidget);
    expect(find.text('Watch this folder'), findsOneWidget);
    addPdfFolderPicker = () async => const AddPdfChoice([], folder: 'Manuals', folderRoot: '/tmp/watch-manuals-2');
    await tapKey(tester, 'watch-again-choose');
    expect(find.text('Not chosen'), findsNothing);
    expect(find.text('Manuals'), findsOneWidget);
  });

  testWidgets('4. What a check found: the folder tag on the progress cards, the Library card names the folder, one summary when done', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await WatchWorld.make());
    w.found();
    await tester.pumpWidget(app(AddPdfProgressPage(state: w.pdf.state, deps: w.pdf.deps, scheduler: w.pdf.scheduler)));
    await settle(tester);
    expect(find.text('From Manuals'), findsNWidgets(2));
    expect(find.text('Water filter guide'), findsOneWidget);
    expect(find.text('Waiting to add a PDF'), findsOneWidget);
    await tester.pumpWidget(app(LibraryPanes(root: (_) => LibraryRootPage(deps: w.pdf.deps), prefs: PanePrefs(dirOverride: w.pdf.tmp))));
    await settle(tester);
    expect(find.text('Manuals: 2 new PDFs · Water filter guide · Reading pages'), findsOneWidget);
    w.foundDone();
    await tester.pumpWidget(app(AddPdfProgressPage(state: w.pdf.state, deps: w.pdf.deps, scheduler: w.pdf.scheduler)));
    await settle(tester);
    expect(find.text('2 new PDFs from Manuals'), findsOneWidget);
    expect(find.text('Added to My books · checked just now'), findsOneWidget);
    expect(find.textContaining('Filed in 530'), findsOneWidget);
    expect(find.textContaining('In Unsorted. Looks like 620'), findsOneWidget);
    expect(find.text('Place'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
    expect(find.text('Open Bookshelves'), findsOneWidget);
    // one summary: not a result card each
    expect(find.text('Open book'), findsNothing);
  });

  testWidgets('6. A wide window: Watched folders opens beside Add to Library', (tester) async {
    size(tester, const Size(1440, 900));
    await tester.runAsync(() async => w = await WatchWorld.make());
    w.two();
    await tester.pumpWidget(app(AddToLibraryScreen(browse: w.pdf.browse)));
    await settle(tester);
    await tapKey(tester, 'watch-folder');
    expect(find.byKey(const ValueKey('add-watched')), findsOneWidget);
    expect(find.text('Checked 2 hours ago'), findsOneWidget);
    expect(find.text('Add a folder'), findsOneWidget);
  });
}

// The finished card and the book row say the words of a new book are being added to the keyword index until they are: the card reads
// "Added to {library} · Adding to search index" and then, by itself when the index status says so, "... · {n} pieces searchable";
// the book's row reads "Adding to search index" and then nothing. "pieces searchable" is never shown before the keyword index has the
// book, nor while the index status is still being read again after the add.

import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/shelves_pages.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf_world.dart';

const _pending = 'Added to My books · Adding to search index';
const _done = 'Added to My books · 254 pieces searchable';

void main() {
  late AddPdfWorld w;
  tearDown(() => w.dispose());

  Widget app() => MaterialApp(theme: buildTheme(CacheThemeId.light), home: AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // what the libraries' index status says: whether the words of the newest points are not in the keyword index yet
  bool? pending;
  void statusChanged() {
    // ignore: invalid_use_of_protected_member
    w.sources.notifyListeners();
  }

  setUp(() => pending = null);

  testWidgets('pending, then done: the card switches by itself when the index status says the words are in', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    pending = true;
    w.state.wordsPending = (_) => pending;
    w.done(w.filed);
    await tester.pumpWidget(app());
    await settle(tester);
    expect(find.text(_pending), findsOneWidget);
    expect(find.text(_done), findsNothing, reason: 'never "pieces searchable" before the words are in');

    pending = false;
    statusChanged();
    await tester.pump();
    expect(find.text(_done), findsOneWidget, reason: 'by itself, with no further tap or poll');
    expect(find.text(_pending), findsNothing);
  });

  testWidgets('already done when the card is first drawn: the done line at once', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    pending = false;
    w.state.wordsPending = (_) => pending;
    w.done(w.filed);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text(_done), findsOneWidget);
    expect(find.text(_pending), findsNothing);
  });

  testWidgets('"pieces searchable" is not shown while pending, nor before the status was read again after the add', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    pending = true;
    w.state.wordsPending = (_) => pending;
    final job = w.filed..wordsChecked = false;
    w.done(job);
    await tester.pumpWidget(app());
    await settle(tester);
    expect(find.textContaining('searchable'), findsNothing, reason: 'the status has not been read again yet');
    expect(find.text('Added to My books'), findsOneWidget);

    job.wordsChecked = true;
    w.state.debugSet([job]);
    await tester.pump();
    expect(find.text(_pending), findsOneWidget);
    expect(find.textContaining('pieces searchable'), findsNothing);
    // pending stays pending across redraws and index changes
    for (var i = 0; i < 3; i++) {
      statusChanged();
      await tester.pump();
      expect(find.textContaining('pieces searchable'), findsNothing);
    }
  });

  testWidgets('a library with no keyword index to be behind (status unknown) reads as it does today', (tester) async {
    size(tester);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    w.done(w.filed);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text(_done), findsOneWidget);
  });

  testWidgets("the book's row says Adding to search index while its words are pending, then nothing", (tester) async {
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    final book = w.shelves.book('water')!;
    pending = true;
    w.state.wordsPending = (_) => pending;
    expect(bookMark(w.deps, book), isNot('Adding to search index'), reason: 'a book made before is not marked');
    w.state.debugAwaitWords('water', '/libs/my-books');
    expect(bookMark(w.deps, book), 'Adding to search index');
    pending = false;
    expect(bookMark(w.deps, book), isNull, reason: 'done: nothing');
    pending = true;
    expect(bookMark(w.deps, book), isNull, reason: 'it let go once the words were in');
  });
}

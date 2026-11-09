import 'dart:async';

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/pdf/pdf_reader_screen.dart';
import 'package:cache/pdf/pdf_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import '../support/pdf_test_kit.dart';
import '../support/pdfium_for_tests.dart';
import '../support/sample_pdf.dart';

/// Lets the reader work: real time for PDFium and the files, test time for the screen's own timers.
Future<void> settleUntil(WidgetTester tester, bool Function() done, {int max = 150}) async {
  for (var i = 0; i < max && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

bool _has(Finder f) => f.evaluate().isNotEmpty;

/// Six pages: five of the sample handbook, then one more with "boil" twice (17 times in all).
List<SamplePage> _findPages() => [
      for (var n = 1; n <= 5; n++) sampleTextPage(n),
      const SamplePage(heading: 'Water and Shelter Handbook, page 6', lines: ['Boil the pot again in the morning, and', 'boil the cloth too.']),
    ];

void main() {
  late Directory dir;
  late String six;
  late String scanned;
  late String junk;
  setUpAll(() async {
    await pdfiumForTests();
    dir = Directory.systemTemp.createTempSync('pdf-reader');
    six = (File('${dir.path}/handbook.pdf')..writeAsBytesSync(samplePdf(_findPages()))).path;
    scanned = (File('${dir.path}/scan.pdf')..writeAsBytesSync(sampleHandbook(count: 3, scanned: {1, 2, 3}))).path;
    junk = (File('${dir.path}/junk.pdf')..writeAsStringSync('%PDF-1.4 this is not a PDF at all')).path;
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester, Widget reader) async {
    tester.view.physicalSize = const Size(430, 932) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: buildTheme(CacheThemeId.light), home: reader));
  }

  PdfReaderScreen reader(String path, {int? page, String? quote}) =>
      PdfReaderScreen(source: PdfFileSource(path, title: 'Water and Shelter Handbook'), initialPage: page, quote: quote);

  readerTest('closing during metadata reading keeps the native document alive until the read ends', (tester) async {
    final reading = Completer<PdfDocument>();
    final title = Completer<String?>();
    await show(tester, PdfReaderScreen(
      source: PdfFileSource(six, title: 'x'),
      debugReadTitle: (document) {
        reading.complete(document);
        return title.future;
      },
    ));
    await settleUntil(tester, () => reading.isCompleted);
    expect(reading.isCompleted, isTrue);
    final document = await reading.future;
    var disposed = false;
    final events = document.events.listen((_) {}, onDone: () => disposed = true);
    addTearDown(events.cancel);
    await tester.pumpWidget(const SizedBox());
    expect(disposed, isFalse, reason: 'the pending metadata read still owns its handle');
    title.complete('Handbook');
    await settleUntil(tester, () => disposed);
    expect(disposed, isTrue, reason: 'a closed reader releases its document after metadata completes');
  });

  group('in a browser (opened from bytes, no temporary file)', () {
    readerTest('a ZIM PDF opens at the cited page from the entry\'s bytes; the temporary folder is never asked for', (tester) async {
      final bytes = File(six).readAsBytesSync();
      var tempAsked = false;
      await show(
        tester,
        PdfReaderScreen(
          openFromBytes: true,
          initialPage: 3,
          source: PdfZimSource(
            address: 'zim:x/handbook.pdf#page=3',
            title: 'Water and Shelter Handbook',
            read: (a) async => bytes,
            tempDir: () async {
              tempAsked = true;
              throw StateError('a browser has no temporary folder');
            },
          ),
        ),
      );
      await settleUntil(tester, () => _has(find.text('3 of 6')));
      expect(find.text('3 of 6'), findsOneWidget);
      expect(tempAsked, isFalse);
    });

    readerTest('a book PDF fetched from the server opens at its first page', (tester) async {
      final bytes = File(six).readAsBytesSync();
      await show(
        tester,
        PdfReaderScreen(
          openFromBytes: true,
          initialPage: 1,
          source: PdfServerSource(id: 'field/aid', title: 'Water and Shelter Handbook', fetch: () async => bytes),
        ),
      );
      await settleUntil(tester, () => _has(find.text('1 of 6')));
      expect(find.text('1 of 6'), findsOneWidget);
    });

    readerTest('a PDF the server no longer has shows the gone page', (tester) async {
      await show(
        tester,
        PdfReaderScreen(openFromBytes: true, source: PdfServerSource(id: 'f/x', title: 'x', fetch: () async => throw const PdfGone())),
      );
      await settleUntil(tester, () => _has(find.text('This file is no longer on this device.')));
      expect(find.text('This file is no longer on this device.'), findsOneWidget);
    });
  });

  readerTest('opens at the asked page; the count opens Go to page, which refuses a page that is not there', (tester) async {
    await show(tester, reader(six, page: 3));
    await settleUntil(tester, () => _has(find.text('3 of 6')));
    expect(find.text('3 of 6'), findsOneWidget);
    expect(find.text('Water and Shelter Handbook'), findsOneWidget);
    expect(find.byTooltip('Previous page'), findsOneWidget);
    expect(find.byTooltip('Next page'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-page-count')));
    await settleUntil(tester, () => _has(find.text('Go to page')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('of 6'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pdf-goto-field')), '9');
    await tester.pump();
    expect(find.byKey(const ValueKey('pdf-goto-range')), findsOneWidget);
    expect(find.text('Pages 1 to 6'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pdf-goto-go'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('pdf-goto-field')), '5');
    await tester.pump();
    expect(find.text('Pages 1 to 6'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pdf-goto-go')));
    await settleUntil(tester, () => _has(find.text('5 of 6')));
    expect(find.text('5 of 6'), findsOneWidget);
  });

  readerTest('a page opens with its top at the top of the view; Go to page and next page do the same', (tester) async {
    final key = GlobalKey<PdfReaderScreenState>();
    await show(tester, PdfReaderScreen(key: key, source: PdfFileSource(six, title: 'x'), initialPage: 3));
    await settleUntil(tester, () => key.currentState?.debugVisibleRect != null);
    await settleUntil(tester, () => false, max: 15);
    void atTop(int page) {
      final v = key.currentState!.debugVisibleRect!;
      final r = key.currentState!.debugPageRect(page)!;
      expect((r.top - v.top).abs(), lessThan(2), reason: 'page $page top ${r.top} view top ${v.top}');
    }

    atTop(3);
    await tester.tap(find.byKey(const ValueKey('pdf-next')));
    await settleUntil(tester, () => false, max: 20);
    atTop(4);
    await tester.tap(find.byKey(const ValueKey('pdf-page-count')));
    await settleUntil(tester, () => _has(find.text('Go to page')));
    await tester.pump(const Duration(milliseconds: 500));
    // (The last page cannot reach the top: the view stops at the end of the PDF.)
    await tester.enterText(find.byKey(const ValueKey('pdf-goto-field')), '2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pdf-goto-go')));
    await settleUntil(tester, () => false, max: 20);
    atTop(2);
  });

  readerTest('a cited passage opens near the top of the view, a small gap above it', (tester) async {
    final key = GlobalKey<PdfReaderScreenState>();
    const quote = 'Store treated water in clean, closed containers away from sunlight and mark each one with the date.';
    await show(tester, PdfReaderScreen(key: key, source: PdfFileSource(six, title: 'x'), initialPage: 4, quote: quote));
    await settleUntil(tester, () => _has(find.text('Cited passage')) && key.currentState?.debugCitedTop != null);
    await settleUntil(tester, () => false, max: 15);
    final st = key.currentState!;
    final v = st.debugVisibleRect!;
    final gap = st.debugCitedTop! - v.top;
    // Below the top edge, and within the top tenth of the view (the page above is out of sight).
    expect(gap, greaterThan(0));
    expect(gap, lessThan(v.height * 0.1));
    expect(st.debugPageRect(4)!.top, lessThan(v.top));
  });

  readerTest('find: the count, next and previous, and closing', (tester) async {
    await show(tester, reader(six));
    await settleUntil(tester, () => _has(find.text('1 of 6')));
    await tester.tap(find.byKey(const ValueKey('pdf-find')));
    await tester.pump();
    expect(find.text('Find in this PDF'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pdf-find-field')), 'boil');
    await settleUntil(tester, () => _has(find.text('1 of 17')));
    expect(find.text('1 of 17'), findsOneWidget);
    expect(find.bySemanticsLabel('Match 1 of 17'), findsOneWidget);
    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.text('2 of 17'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous match'));
    await tester.tap(find.byTooltip('Previous match'));
    await tester.pump();
    expect(find.text('17 of 17'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pdf-find-field')), 'helicopter');
    await settleUntil(tester, () => _has(find.text('No matches')));
    expect(find.text('No matches'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-find-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pdf-find-row')), findsNothing);
  });

  readerTest('a citation: the passage is found and marked; the strip closes', (tester) async {
    const quote = 'If you cannot boil water, filter it through a clean cloth, then add household bleach without scent';
    await show(tester, reader(six, page: 2, quote: quote));
    await settleUntil(tester, () => _has(find.text('Cited passage')));
    expect(find.text('2 of 6'), findsOneWidget);
    expect(find.text('Cited passage'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-strip-close')));
    await tester.pump();
    expect(find.text('Cited passage'), findsNothing);
  });

  readerTest('a citation whose passage is not on the page offers to find it on other pages', (tester) async {
    await show(tester, reader(six, page: 2, quote: 'Nothing like this is printed anywhere in the handbook at all'));
    await settleUntil(tester, () => _has(find.text('Page 2. The exact passage was not found on this page.')));
    expect(find.text('Find on other pages'), findsOneWidget);
    await tester.tap(find.text('Find on other pages'));
    await settleUntil(tester, () => _has(find.text('No matches')));
    expect(find.byKey(const ValueKey('pdf-find-row')), findsOneWidget);
  });

  readerTest('a cited page the file does not have opens page 1 and says so', (tester) async {
    await show(tester, reader(six, page: 400));
    await settleUntil(tester, () => _has(find.text('This PDF has 6 pages. Cited page 400 is not here.')));
    expect(find.text('1 of 6'), findsOneWidget);
  });

  readerTest('a scanned PDF: the note, and find has nothing to search', (tester) async {
    await show(tester, reader(scanned));
    await settleUntil(tester, () => _has(find.text("This PDF is scanned pictures. Search can't read it.")));
    await tester.tap(find.byKey(const ValueKey('pdf-find')));
    await tester.pump();
    expect(find.text('No searchable text in this PDF.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('pdf-find-field'))).enabled, isFalse);
  });

  readerTest('a damaged file and a missing file', (tester) async {
    await show(tester, reader(junk));
    // pdfrx_engine 0.4.7 treats every Windows open error as a password error.
    // Mobile and Darwin must still distinguish a damaged PDF from an encrypted one.
    final damaged = Platform.isWindows ? 'This PDF is locked. Enter its password.' : "This PDF can't be opened. The file may be damaged.";
    await settleUntil(tester, () => _has(find.text(damaged)));
    expect(find.text(damaged), findsOneWidget);
    if (!Platform.isWindows) expect(find.text('Try again'), findsOneWidget);
    await show(tester, reader('${dir.path}/missing.pdf'));
    await settleUntil(tester, () => _has(find.text('This file is no longer on this device.')));
    expect(find.text('This file is no longer on this device.'), findsOneWidget);
  });

  readerTest('a PDF inside a ZIM is got ready first', (tester) async {
    final bytes = File(six).readAsBytesSync();
    final src = PdfZimSource(address: 'zim:x/I/handbook.pdf', title: 'handbook', read: (a) async => bytes, tempDir: () async => dir);
    await show(tester, PdfReaderScreen(source: src, initialPage: 2));
    await settleUntil(tester, () => _has(find.text('2 of 6')));
    expect(find.text('2 of 6'), findsOneWidget);
  });

  readerTest('the states before the pages, as worded', (tester) async {
    final cases = {
      PdfDebugPhase.opening: 'Opening...',
      PdfDebugPhase.slow: 'Still opening. This file is 312 MB.',
      PdfDebugPhase.copying: 'Getting the PDF ready...',
      PdfDebugPhase.noSpace: 'Not enough space to open this PDF on this device. It needs 340 MB.',
      PdfDebugPhase.locked: 'This PDF is locked. Enter its password.',
      PdfDebugPhase.wrongPassword: 'That password is not right.',
      PdfDebugPhase.damaged: "This PDF can't be opened. The file may be damaged.",
      PdfDebugPhase.gone: 'This file is no longer on this device.',
    };
    for (final e in cases.entries) {
      await show(
        tester,
        PdfReaderScreen(source: PdfFileSource(six, title: 'x'), debugPhase: e.key, debugFileBytes: e.key == PdfDebugPhase.noSpace ? 340 << 20 : 312 << 20),
      );
      await tester.pump();
      expect(find.text(e.value), findsOneWidget, reason: '${e.key}');
    }
  });

  test('Dark pages is kept with the settings and reaches the reader', () async {
    final d = Directory.systemTemp.createTempSync('dark-pages');
    final app = AppState(settingsDirOverride: d, modelsDirOverride: Directory('${d.path}/m'));
    await app.init();
    expect(app.darkPdfPages, isFalse);
    await app.setDarkPdfPages(true);
    expect(pdfDarkPages.value, isTrue);
    final again = AppState(settingsDirOverride: d, modelsDirOverride: Directory('${d.path}/m'));
    await again.init();
    expect(again.darkPdfPages, isTrue);
    await again.setDarkPdfPages(false);
    expect(pdfDarkPages.value, isFalse);
    d.deleteSync(recursive: true);
  });
}

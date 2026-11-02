import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/pdf/pdf_reader_screen.dart';
import 'package:cache/pdf/pdf_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  readerTest('opens at the asked page; the count opens Go to page, which refuses a page that is not there', (tester) async {
    await show(tester, reader(six, page: 3));
    await settleUntil(tester, () => _has(find.text('3 of 6')));
    expect(find.text('3 of 6'), findsOneWidget);
    expect(find.text('Water and Shelter Handbook'), findsOneWidget);
    expect(find.byTooltip('Previous page'), findsOneWidget);
    expect(find.byTooltip('Next page'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-page-count')));
    await settleUntil(tester, () => _has(find.text('Go to page')));
    expect(find.text('of 6'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pdf-goto-field')), '9');
    await tester.pump();
    expect(find.text('Pages 1 to 6'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pdf-goto-go'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('pdf-goto-field')), '5');
    await tester.pump();
    expect(find.text('Pages 1 to 6'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pdf-goto-go')));
    await settleUntil(tester, () => _has(find.text('5 of 6')));
    expect(find.text('5 of 6'), findsOneWidget);
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
    await settleUntil(tester, () => _has(find.text("This PDF can't be opened. The file may be damaged.")));
    expect(find.text('Try again'), findsOneWidget);
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

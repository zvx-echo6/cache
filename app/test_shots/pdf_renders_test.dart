// The 1.0.30 PDF reader (UX-pdf-30) for the owner to review, drawn by the app's own widgets on a PDF made here (the project's own
// words about water and shelter, no personal data). Every picture in the light and the dark theme.
// flutter test test_shots/pdf_renders_test.dart --update-goldens  (pictures in test_shots/pdf/)

import 'dart:io';

import 'package:cache/pdf/pdf_reader_screen.dart';
import 'package:cache/pdf/pdf_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';

import '../test/support/pdf_test_kit.dart';
import '../test/support/pdfium_for_tests.dart';
import '../test/support/sample_pdf.dart';
import 'shot_kit.dart';

const _out = 'pdf';
const Size kPhone = Size(430, 932);
const _title = 'Water and Shelter Handbook';

late Directory _dir;
late String _book; // 340 pages
late String _six; // 6 pages, "boil" 17 times
late String _scan; // 3 scanned pages
late String _mixed; // 6 pages, 2 and 3 scanned

Future<void> _settle(WidgetTester tester, {int n = 30}) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _until(WidgetTester tester, Finder f, {int max = 200}) async {
  for (var i = 0; i < max && f.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// [reader] opened over a blank page (so its top-left arrow shows), in [theme], at [size].
Future<void> _open(
  WidgetTester tester,
  Widget reader, {
  CacheThemeId theme = CacheThemeId.light,
  Size size = kPhone,
  double textScale = 1,
}) async {
  phone(tester, size: size, ratio: size == kPhone ? 3 : 2);
  final nav = GlobalKey<NavigatorState>();
  final app = MaterialApp(
    key: UniqueKey(),
    navigatorKey: nav,
    debugShowCheckedModeBanner: false,
    theme: shotTheme(theme),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        padding: size == kPhone ? const EdgeInsets.only(top: 54, bottom: 34) : const EdgeInsets.only(top: 24, bottom: 20),
        viewPadding: size == kPhone ? const EdgeInsets.only(top: 54, bottom: 34) : const EdgeInsets.only(top: 24, bottom: 20),
        textScaler: TextScaler.linear(textScale),
      ),
      child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
    ),
    home: const Scaffold(),
  );
  await tester.pumpWidget(app);
  nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => reader));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

PdfReaderScreen _reader(String path, {int? page, String? quote, PdfDebugPhase? phase, int? bytes, bool zoomLimited = false, int? stall, bool placeholders = false, bool browser = false}) =>
    PdfReaderScreen(
      source: PdfFileSource(path, title: _title),
      initialPage: page,
      quote: quote,
      debugPhase: phase,
      debugFileBytes: bytes,
      debugZoomLimited: zoomLimited,
      debugFindStallAfter: stall,
      debugPlaceholders: placeholders,
      debugBrowser: browser,
    );

String _t(CacheThemeId t) => t == CacheThemeId.light ? 'light' : 'dark';

Future<void> _snap(WidgetTester tester, String name, CacheThemeId theme) => snap(tester, _out, '$name-${_t(theme)}');

/// The find row's count reading [text].
Finder _count(String text) => find.byWidgetPredicate((w) => w is Text && w.key == const ValueKey('pdf-find-count') && w.data == text);

Future<void> _ready(WidgetTester tester, String count) async {
  await _until(tester, find.text(count));
  await _settle(tester);
}

Future<void> _find(WidgetTester tester, String q, {Finder? until, int max = 200}) async {
  await tester.tap(find.byKey(const ValueKey('pdf-find')));
  await tester.pump();
  if (q.isNotEmpty) {
    await tester.enterText(find.byKey(const ValueKey('pdf-find-field')), q);
    await tester.pump(const Duration(milliseconds: 350));
  }
  if (until != null) await _until(tester, until, max: max);
  await _settle(tester, n: 12);
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await pdfiumForTests();
    _dir = Directory.systemTemp.createTempSync('pdf-shots');
    _book = (File('${_dir.path}/book.pdf')..writeAsBytesSync(sampleHandbook())).path;
    _six = (File('${_dir.path}/six.pdf')
          ..writeAsBytesSync(samplePdf([
            for (var n = 1; n <= 5; n++) sampleTextPage(n),
            const SamplePage(heading: 'Water and Shelter Handbook, page 6', lines: ['Boil the pot again in the morning, and', 'boil the cloth too.']),
          ])))
        .path;
    _scan = (File('${_dir.path}/scan.pdf')..writeAsBytesSync(sampleHandbook(count: 3, scanned: {1, 2, 3}))).path;
    _mixed = (File('${_dir.path}/mixed.pdf')..writeAsBytesSync(sampleHandbook(count: 6, scanned: {2, 3}))).path;
  });

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    readerTest('1: page 12, bars shown; bars hidden with the page pill (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_book, page: 12), theme: theme);
      await _ready(tester, '12 of 340');
      await _snap(tester, '1a-viewer-page-12', theme);
      await tester.tapAt(const Offset(215, 520));
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester, n: 10);
      await _snap(tester, '1b-bars-hidden-pill', theme);
    });

    readerTest('2: Go to page; a page that is not there (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_book, page: 12), theme: theme);
      await _ready(tester, '12 of 340');
      await tester.tap(find.byKey(const ValueKey('pdf-page-count')));
      await _until(tester, find.text('Go to page'));
      await _settle(tester, n: 12);
      await _snap(tester, '2a-go-to-page', theme);
      await tester.enterText(find.byKey(const ValueKey('pdf-goto-field')), '400');
      await tester.pump();
      await _settle(tester, n: 4);
      await _snap(tester, '2b-go-to-page-out-of-range', theme);
    });

    readerTest('3: fit width, fit page with its label, zoom limited (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_book, page: 12), theme: theme);
      await _ready(tester, '12 of 340');
      await _snap(tester, '3a-fit-width', theme);
      await tester.tap(find.byKey(const ValueKey('pdf-fit')));
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester, n: 10);
      await _snap(tester, '3b-fit-page-label', theme);
      await _open(tester, _reader(_book, page: 12, zoomLimited: true), theme: theme);
      await _ready(tester, '12 of 340');
      await _snap(tester, '3c-zoom-limited', theme);
    });

    readerTest('4: find: empty, searching, 3 of 17, no matches, a long file (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_six), theme: theme);
      await _ready(tester, '1 of 6');
      await _find(tester, '');
      await _snap(tester, '4a-find-empty', theme);
      await tester.enterText(find.byKey(const ValueKey('pdf-find-field')), 'boil');
      await _until(tester, find.text('1 of 17'));
      await tester.tap(find.byTooltip('Next match'));
      await tester.tap(find.byTooltip('Next match'));
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester, n: 14);
      await _snap(tester, '4c-find-3-of-17', theme);
      await tester.enterText(find.byKey(const ValueKey('pdf-find-field')), 'helicopter');
      await _until(tester, find.text('No matches'));
      await _settle(tester, n: 4);
      await _snap(tester, '4d-find-no-matches', theme);

      await _open(tester, _reader(_book, stall: 0), theme: theme);
      await _ready(tester, '1 of 340');
      await _find(tester, 'boil', until: find.text('Searching...'));
      await _snap(tester, '4b-find-searching', theme);
      await _open(tester, _reader(_book, stall: 4), theme: theme);
      await _ready(tester, '1 of 340');
      await _find(tester, 'boil', until: find.text('12 found so far'));
      await _snap(tester, '4e-find-long-file', theme);
    });

    readerTest('5: a citation: the passage marked; not on the page; a page the file does not have (${_t(theme)})', (tester) async {
      const quote = 'If you cannot boil water, filter it through a clean cloth, then add household bleach without scent: '
          'two drops to each litre, stir, and wait thirty minutes.';
      await _open(tester, _reader(_book, page: 47, quote: quote), theme: theme);
      await _until(tester, find.text('Cited passage'));
      await _settle(tester);
      await _snap(tester, '5a-cited-passage', theme);
      await _open(tester, _reader(_book, page: 47, quote: 'Signal fires are built in threes, a long way apart, on open high ground.'), theme: theme);
      await _until(tester, find.text('Find on other pages'));
      await _settle(tester);
      await _snap(tester, '5b-passage-not-found', theme);
      await _open(tester, _reader(_book, page: 400), theme: theme);
      await _until(tester, find.text('This PDF has 340 pages. Cited page 400 is not here.'));
      await _settle(tester);
      await _snap(tester, '5c-page-not-in-file', theme);
    });

    readerTest('6: scanned: the note, find off; a mixed PDF (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_scan), theme: theme);
      await _until(tester, find.text("This PDF is scanned pictures. Search can't read it."));
      await _settle(tester);
      await _snap(tester, '6a-scanned-note', theme);
      await tester.tap(find.byKey(const ValueKey('pdf-find')));
      await tester.pump();
      await _settle(tester, n: 6);
      await _snap(tester, '6b-scanned-find-off', theme);
      await _open(tester, _reader(_mixed), theme: theme);
      await _ready(tester, '1 of 6');
      await _find(tester, 'boil', until: find.text('Scanned pages skipped'));
      await _snap(tester, '6c-mixed-pages-skipped', theme);
      await _open(tester, _reader(_scan, page: 2, quote: 'Water that looks clear can still carry germs.'), theme: theme);
      await _until(tester, find.text('Page 2. Scanned page, nothing to highlight.'));
      await _settle(tester);
      await _snap(tester, '6d-citation-scanned-page', theme);
    });

    readerTest('7: opening, slow, copying, no space, locked, wrong password, damaged, gone, a web link (${_t(theme)})', (tester) async {
      final states = {
        '7a-opening': PdfDebugPhase.opening,
        '7b-slow': PdfDebugPhase.slow,
        '7c-copying-from-library': PdfDebugPhase.copying,
        '7d-no-space': PdfDebugPhase.noSpace,
        '7e-locked': PdfDebugPhase.locked,
        '7f-wrong-password': PdfDebugPhase.wrongPassword,
        '7g-damaged': PdfDebugPhase.damaged,
        '7h-gone': PdfDebugPhase.gone,
      };
      for (final e in states.entries) {
        await _open(tester, _reader(_book, phase: e.value, bytes: e.value == PdfDebugPhase.noSpace ? 340 << 20 : 312 << 20), theme: theme);
        await tester.pump(const Duration(milliseconds: 100));
        await _snap(tester, e.key, theme);
      }
      await _open(tester, _reader(_book, page: 12), theme: theme);
      await _ready(tester, '12 of 340');
      askToOpenPdfLink(tester.element(find.byType(PdfReaderScreen)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _snap(tester, '7i-web-link', theme);
    });

    readerTest('8: pages not yet drawn while scrolling a large file (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_book, page: 200, placeholders: true), theme: theme);
      await _ready(tester, '200 of 340');
      await tester.drag(find.byType(PdfReaderScreen), const Offset(0, -380));
      await tester.pump(const Duration(milliseconds: 50));
      await _settle(tester, n: 4);
      await _snap(tester, '8-placeholders', theme);
    });

    readerTest('9: tablet and desktop: the whole window; browser slow note (${_t(theme)})', (tester) async {
      for (final (name, size) in [
        ('9a-tablet-portrait-820', const Size(820, 1180)),
        ('9b-tablet-landscape-1180', const Size(1180, 820)),
      ]) {
        await _open(tester, _reader(_book, page: 12), theme: theme, size: size);
        await _ready(tester, '12 of 340');
        await _snap(tester, name, theme);
      }
      for (final (name, size) in [
        ('9c-desktop-1280-find', const Size(1280, 800)),
        ('9d-desktop-1600-find', const Size(1600, 1000)),
      ]) {
        await _open(tester, _reader(_book, page: 12), theme: theme, size: size);
        await _ready(tester, '12 of 340');
        await _find(tester, 'ridge line', until: _count('1 of 340'), max: 900);
        await _snap(tester, name, theme);
      }
      await _open(tester, _reader(_book, phase: PdfDebugPhase.slow, browser: true), theme: theme, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 100));
      await _snap(tester, '9e-browser-slow', theme);
    });

    readerTest('10: large text (200%) top bar; what a screen reader reads (${_t(theme)})', (tester) async {
      await _open(tester, _reader(_book, page: 12), theme: theme, textScale: 2);
      await _ready(tester, '12 of 340');
      await _snap(tester, '10a-large-text-200', theme);
      final handle = tester.ensureSemantics();
      await _open(tester, _reader(_book, page: 12), theme: theme);
      await _ready(tester, '12 of 340');
      // What a screen reader reads, in order: the reader's own semantics, listed.
      final read = <String>[];
      void visit(SemanticsNode n) {
        final d = n.getSemanticsData();
        var line = [d.label, d.value].where((x) => x.trim().isNotEmpty).join(': ').replaceAll('\n', ' ');
        if (line.length > 110) line = '${line.substring(0, 107)}...';
        if (line.isNotEmpty) read.add(line);
        n.visitChildren((c) {
          visit(c);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(PdfReaderScreen)));
      await tester.pumpWidget(shotApp(
        Scaffold(
          appBar: AppBar(title: const Text('What a screen reader reads, in order')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < read.length; i++)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('${i + 1}. ${read[i]}', style: const TextStyle(fontSize: 15))),
            ],
          ),
        ),
        theme: theme,
      ));
      await tester.pump();
      await _snap(tester, '10b-screen-reader-order', theme);
      handle.dispose();
    });
  }
}

// Add PDF's screens for review, drawn by the app itself with sample data (the owner's mockups, frame by frame): where you start
// (Add to Library, Bookshelves), the library question, the confirm screen, progress (the Library's card, the phases, the holds,
// Cancel), done and filed (the result, the book page's note), done and not confident (the result, Unsorted), a spare copy, the
// errors, and the main flow on a tablet. On a phone (390 x 844) and a desktop window (1440 x 900), light and dark.
// flutter test test_shots/add_pdf_renders_test.dart --update-goldens  (pictures in test_shots/add_pdf/)

import 'dart:io';

import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_world.dart';
import 'shot_kit.dart';

const _out = 'add_pdf';

const Map<String, Size> kSizes = {'390': Size(390, 844), '1440': Size(1440, 900)};

Future<void> _loadLibraryFonts() async {
  for (final (family, asset) in [('Roboto Mono', 'assets/fonts/RobotoMono-Bold.ttf'), ('Libre Baskerville', 'assets/fonts/LibreBaskerville-Variable.ttf')]) {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.view(File(asset).readAsBytesSync().buffer)));
    await loader.load();
  }
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

const _charging = BatteryReading(percent: 80, charging: true);
const _low = BatteryReading(percent: 38, charging: false);

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });

  late AddPdfWorld w;

  Future<void> shoot(WidgetTester tester, String size, String name, CacheThemeId theme, Widget Function() page, {List<String> taps = const [], double scroll = 0}) async {
    phone(tester, size: kSizes[size]!, ratio: size == '390' ? 2 : 1);
    await tester.pumpWidget(shotApp(page(), theme: theme, insets: size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero));
    await _settle(tester);
    for (final k in taps) {
      final f = find.byKey(ValueKey(k));
      final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
      if (f.evaluate().isEmpty && list.evaluate().isNotEmpty) await tester.scrollUntilVisible(f, 300, scrollable: list.last);
      await tester.ensureVisible(f.first);
      await _settle(tester, 2);
      await tester.tap(f.first);
      await _settle(tester);
    }
    if (scroll > 0) {
      await tester.drag(find.byType(Scrollable).last, Offset(0, -scroll));
      await _settle(tester);
    }
    await snap(tester, _out, '$size-$name-${theme == CacheThemeId.dark ? 'dark' : 'light'}');
  }

  Widget panes() => LibraryPanes(root: (_) => LibraryRootPage(deps: w.deps), prefs: PanePrefs(dirOverride: w.tmp));
  Widget progress() => AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler);

  for (final size in kSizes.keys) {
    testWidgets('Add PDF screens at $size', (tester) async {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        // 1, 3, 4-9: My books exists, with the Field and Homestead libraries of the person's own
        await tester.runAsync(() async => w = await AddPdfWorld.make());
        // 1. Where you start
        w.done(w.filed);
        await shoot(tester, size, '1-add-to-library', theme, () => AddToLibraryScreen(browse: w.browse));
        await shoot(tester, size, '1-bookshelves', theme, panes, taps: const ['library-bookshelves']);
        // 2b. Change: the sheet with the libraries of their own
        await shoot(tester, size, '2-library-sheet', theme, () => AddPdfConfirmPage(state: w.state, pdf: (path: '/tmp/none.pdf', name: 'Water purification manual.pdf', bytes: 43 << 20), battery: _charging),
            taps: const ['add-pdf-change']);
        // 3. After picking a file: charging now; a big file on battery
        await shoot(tester, size, '3-confirm-charging', theme, () => AddPdfConfirmPage(state: w.state, pdf: (path: '/tmp/none.pdf', name: 'Water purification manual.pdf', bytes: 43 << 20), battery: _charging));
        await shoot(tester, size, '3-confirm-battery', theme, () => AddPdfConfirmPage(state: w.state, pdf: (path: '/tmp/none.pdf', name: 'Field radio handbook.pdf', bytes: 212 << 20), battery: _low));
        // 4. Progress
        w.runOne();
        await shoot(tester, size, '4-library-card', theme, panes);
        await shoot(tester, size, '4-progress', theme, progress);
        w.holdAll();
        await shoot(tester, size, '4-held', theme, progress);
        w.runOne();
        await shoot(tester, size, '4-cancel', theme, progress, taps: const ['add-pdf-cancel-job']);
        // 5. Done, filed: the result; the book page's note (once)
        w.done(w.filed);
        await shoot(tester, size, '5-filed', theme, progress);
        await shoot(tester, size, '5-book-note', theme, panes, taps: const ['library-bookshelves', 'shelf-500', 'shelf-530', 'book-water']);
        // 6. Done, not confident: the result; Unsorted
        w.done(w.unsure);
        await shoot(tester, size, '6-unsure', theme, progress);
        await shoot(tester, size, '6-unsorted', theme, panes, taps: const ['library-bookshelves', 'shelves-unsorted']);
        // 7. A spare copy: the result; the book page's Spare copies
        w.done(w.spare);
        await shoot(tester, size, '7-spare', theme, progress);
        await shoot(tester, size, '7-book-spares', theme, panes, taps: const ['library-bookshelves', 'shelf-500', 'shelf-530', 'book-water1'], scroll: size == '390' ? 300 : 0);
        // 8. Errors; the Library's card when a job stopped
        w.errors(w.errorsA);
        await shoot(tester, size, '8-errors-a', theme, progress);
        w.errors(w.errorsB);
        await shoot(tester, size, '8-errors-b', theme, progress);
        w.stopped();
        await shoot(tester, size, '8-library-stopped', theme, panes);
        // 9. The main flow beside the Library (a tablet or a desktop window): the card opens Adding a PDF
        w.runOne();
        if (size == '1440') await shoot(tester, size, '9-tablet', theme, panes, taps: const ['index-overview']);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => w.dispose());
        // 2a. The first time: only My books, made on first use
        await tester.runAsync(() async => w = await AddPdfWorld.make(own: false, myBooks: false));
        await shoot(tester, size, '2-first-time', theme, () => AddPdfConfirmPage(state: w.state, pdf: (path: '/tmp/none.pdf', name: 'Water purification manual.pdf', bytes: 43 << 20), battery: _charging));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => w.dispose());
      }
    });
  }
}

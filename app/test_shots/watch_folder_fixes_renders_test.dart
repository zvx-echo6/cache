// The two UI changes from the Watch a folder Pixel proof, for review: the Library card for a PDF the person paused (nothing else
// running), and "It finished first" (Stop adding, when the PDF finished while the question was open). On a phone (390 x 844),
// light and tactical.
// flutter test test_shots/watch_folder_fixes_renders_test.dart --update-goldens  (pictures in test_shots/watch_folder/)

import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/watch_folder/watch_world.dart';
import 'shot_kit.dart';

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.tactical]) {
    testWidgets('Watch a folder fixes, ${theme.name}', (tester) async {
      late WatchWorld w;
      await tester.runAsync(() async => w = await WatchWorld.make());
      phone(tester, size: const Size(390, 844), ratio: 2);
      const insets = EdgeInsets.only(top: 44, bottom: 30);
      // the Library card for a paused PDF
      w.pausedOne();
      await tester.pumpWidget(shotApp(LibraryPanes(root: (_) => LibraryRootPage(deps: w.pdf.deps), prefs: PanePrefs(dirOverride: w.pdf.tmp)), theme: theme, insets: insets));
      await _settle(tester);
      await snap(tester, 'watch_folder', '390-7-paused-card-${theme.name}');
      // It finished first
      w.pdf.runOne();
      await tester.pumpWidget(shotApp(AddPdfProgressPage(state: w.pdf.state, deps: w.pdf.deps, scheduler: w.pdf.scheduler), theme: theme, insets: insets));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('add-pdf-cancel-job')));
      await _settle(tester);
      w.pdf.state.jobs.single
        ..status = AddPdfStatus.done
        ..state = 'done';
      await tester.tap(find.byKey(const ValueKey('add-pdf-stop')));
      await _settle(tester);
      await snap(tester, 'watch_folder', '390-8-finished-first-${theme.name}');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async => w.dispose());
    });
  }
}

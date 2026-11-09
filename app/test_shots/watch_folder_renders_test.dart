// Watch a folder's screens for review, drawn by the app itself with sample data (the owner's mockups, watch-folder-mockups.html,
// frame by frame): 1 where you start it (first time, and once folders are watched), 2 the confirm screen (Android, iPhone), 3 the
// Watched folders list (Android; iPhone with Check now running; Stop watching; a PDF that couldn't be added), 4 a check that found
// new PDFs (the Library card, the progress page, the summary), 5 a folder that can't be reached (the row, the card, Choose again),
// 6 the wide window. On a phone (390 x 844) and a desktop window (1440 x 900), light and dark.
// flutter test test_shots/watch_folder_renders_test.dart --update-goldens  (pictures in test_shots/watch_folder/)

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

import '../test/watch_folder/watch_world.dart';
import 'shot_kit.dart';

const _out = 'watch_folder';

const Map<String, Size> kSizes = {'390': Size(390, 844), '1440': Size(1440, 900)};

const _charging = BatteryReading(percent: 80, charging: true);

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

AddPdfChoice _manuals() => AddPdfChoice([
  for (var i = 1; i <= 12; i++) (path: 'Manual $i.pdf', name: 'Manual $i.pdf', bytes: 70 << 20),
], folder: 'Manuals', folderRoot: '/tmp/watch-manuals');

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });

  late WatchWorld w;

  Future<void> shoot(WidgetTester tester, String size, String name, CacheThemeId theme, Widget Function() page, {List<String> taps = const []}) async {
    phone(tester, size: kSizes[size]!, ratio: size == '390' ? 2 : 1);
    await tester.pumpWidget(shotApp(page(), theme: theme, insets: size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero));
    await _settle(tester);
    for (final k in taps) {
      final f = find.byKey(ValueKey(k));
      await tester.ensureVisible(f.first);
      await _settle(tester, 2);
      await tester.tap(f.first);
      await _settle(tester);
    }
    await snap(tester, _out, '$size-$name-${theme == CacheThemeId.dark ? 'dark' : 'light'}');
  }

  Widget add() => AddToLibraryScreen(browse: w.pdf.browse);
  Widget panes() => LibraryPanes(root: (_) => LibraryRootPage(deps: w.pdf.deps), prefs: PanePrefs(dirOverride: w.pdf.tmp));
  Widget progress() => AddPdfProgressPage(state: w.pdf.state, deps: w.pdf.deps, scheduler: w.pdf.scheduler);
  Widget list({required bool android}) => WatchedFoldersPage(watch: w.watch, background: android);

  for (final size in kSizes.keys) {
    testWidgets('Watch a folder screens at $size', (tester) async {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await tester.runAsync(() async => w = await WatchWorld.make());
        // 1. Where you start it: the first time; once folders are watched
        w.watch.debugSet(const []);
        await shoot(tester, size, '1-add-first', theme, add);
        w.two();
        await shoot(tester, size, '1-add-watched', theme, add);
        // 2. Confirm: Android (background plus on open), iPhone (on open only)
        await shoot(tester, size, '2-confirm-android', theme, () => WatchFolderConfirmPage(watch: w.watch, state: w.pdf.state, choice: _manuals(), battery: _charging, background: true));
        await shoot(tester, size, '2-confirm-iphone', theme, () => WatchFolderConfirmPage(watch: w.watch, state: w.pdf.state, choice: _manuals(), battery: _charging, background: false));
        // 3. The list: Android; iPhone with Check now running; Stop watching asks once; a PDF that couldn't be added
        w.two();
        await shoot(tester, size, '3-list-android', theme, () => list(android: true));
        w.checking();
        await shoot(tester, size, '3-list-iphone-checking', theme, () => list(android: false));
        w.watch.debugSet([w.manuals]);
        await shoot(tester, size, '3-stop', theme, () => list(android: true), taps: const ['watch-stop-manuals']);
        w.skipped();
        await shoot(tester, size, '3-skipped', theme, () => list(android: true));
        // 4. A check that found new PDFs: the Library card, the progress page, the summary
        w.two();
        w.found();
        await shoot(tester, size, '4-library-card', theme, panes);
        await shoot(tester, size, '4-progress', theme, progress);
        w.foundDone();
        await shoot(tester, size, '4-summary', theme, progress);
        // 5. A folder that can't be reached: the row, the card, Choose again
        w.unreachable();
        await shoot(tester, size, '5-add-row', theme, add);
        await shoot(tester, size, '5-list', theme, () => list(android: true));
        await shoot(tester, size, '5-choose-again', theme, () => WatchChooseAgainPage(watch: w.watch, folder: w.watch.folders.first));
        // 6. The wide window: Add to Library on the left, Watched folders on the right
        if (size == '1440') {
          w.two();
          await shoot(tester, size, '6-wide', theme, add, taps: const ['watch-folder']);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => w.dispose());
      }
    });
  }
}

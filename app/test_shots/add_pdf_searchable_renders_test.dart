// Add PDF, "searchable" wording, the owner's approved two-stage version, drawn by the app's own screens: the finished card while the
// book's words are being added to the keyword index ("Added to {library} · Adding to search index"), the book's row in the same state
// ("Adding to search index"), and the finished card once they are in ("Added to {library} · {n} pieces searchable"). 390 wide, light,
// dark and Tactical.
// flutter test test_shots/add_pdf_searchable_renders_test.dart --update-goldens  (pictures in test_shots/add_pdf_searchable/)

import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_pages.dart' as real;
import 'package:cache/library/shelves_pages.dart' show bookMark;
import 'package:cache/library/cds.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/screens/settings/widgets.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_world.dart';
import 'shot_kit.dart';

const _out = 'add_pdf_searchable';

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

/// A book row as the shelf lists it (shelves_pages.dart): the call number, the title, the size line, and the small state mark.
Widget _row(BuildContext context, String? mark) => SettingsGroup(
  rows: [
    SettingsRow(
      leading: SizedBox(width: 74, child: Text('530', style: TextStyle(fontFamily: kCdsMono, fontSize: 13, fontWeight: FontWeight.w700, color: context.t.secondary))),
      title: 'Water purification manual',
      titleLines: 2,
      statusWidget: libraryLines(context, '43.0 MB', mark),
      statusLines: 2,
      chevron: false,
    ),
  ],
);

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });

  for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
    final t = theme.name;
    testWidgets('add pdf searchable $t', (tester) async {
      late AddPdfWorld w;
      await tester.runAsync(() async => w = await AddPdfWorld.make());
      phone(tester, size: const Size(390, 844), ratio: 2);
      Future<void> show(Widget page, String name) async {
        await tester.pumpWidget(shotApp(page, theme: theme, insets: const EdgeInsets.only(top: 44, bottom: 30)));
        await _settle(tester);
        await snap(tester, _out, '$name-$t');
      }

      // The card while the words are being added to the keyword index, then the book's row, then the card once they are in.
      var pending = true;
      w.state.wordsPending = (_) => pending;
      w.done(w.filed);
      await show(real.AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler), '1-card-adding-to-search-index');
      // ignore: invalid_use_of_visible_for_testing_member
      w.state.debugAwaitWords('water', 'unused');
      final book = w.shelves.book('water')!;
      await show(Builder(builder: (c) => Scaffold(appBar: AppBar(title: const Text('Shelf 530')), body: ListView(padding: const EdgeInsets.all(16), children: [_row(c, bookMark(w.deps, book))]))), '2-row-adding-to-search-index');
      pending = false;
      await show(real.AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler), '3-card-done');
      await show(Builder(builder: (c) => Scaffold(appBar: AppBar(title: const Text('Shelf 530')), body: ListView(padding: const EdgeInsets.all(16), children: [_row(c, bookMark(w.deps, book))]))), '4-row-done');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async => w.dispose());
    });
  }
}

// Add PDF, "searchable" wording (design only): option 1 tells the truth in two stages (the finished card says it is found by meaning
// now and its words follow; the book row says "Adding its words to search" while that is pending, then nothing); option 2 holds the
// card on the existing progress step until both are done, then the existing finished card. 390 wide, light, dark and Tactical.
// Option 1's card is drawn by a render-only copy of add_pdf_pages.dart; the rest is the app's own screens.
// flutter test test_shots/add_pdf_searchable_renders_test.dart --update-goldens  (pictures in test_shots/add_pdf_searchable/)

import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_pages.dart' as real;
import 'package:cache/library/cds.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/screens/settings/widgets.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_fixtures.dart';
import '../test/add_pdf/add_pdf_world.dart';
import 'add_pdf_wording/add_pdf_pages_option.dart' as opt;
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

      // Option 1: two stages.
      opt.optionCardLine = 'Added to {library} · found by meaning now; its words become searchable shortly';
      w.done(w.filed);
      await show(opt.AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler), '1a-card-two-stages');
      opt.optionCardLine = null;
      await show(Builder(builder: (c) => Scaffold(appBar: AppBar(title: const Text('Shelf 530')), body: ListView(padding: const EdgeInsets.all(16), children: [_row(c, 'Adding its words to search')]))), '1b-row-adding-words');
      await show(Builder(builder: (c) => Scaffold(appBar: AppBar(title: const Text('Shelf 530')), body: ListView(padding: const EdgeInsets.all(16), children: [_row(c, null)]))), '1c-row-done');

      // Option 2: the card waits on the existing step, then the existing finished card.
      w.state.debugSet([sampleJob('wait', state: 'embedding', pages: 310, pagesDone: 310, pieces: 254, piecesDone: 254, libraryTitle: 'My books')]);
      await show(real.AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler), '2a-card-waiting');
      w.done(w.filed);
      await show(real.AddPdfProgressPage(state: w.state, deps: w.deps, scheduler: w.scheduler), '2b-card-done');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async => w.dispose());
    });
  }
}

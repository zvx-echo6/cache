// The Library's overview card when a PDF has just been added while another PDF the person paused waits in the queue: it says the book
// was added (with whether its words are searchable yet) for a short while, then the paused line is back. 390 wide, in the four themes.
// flutter test test_shots/library_card_added_renders_test.dart --update-goldens  (pictures in test_shots/library_card_added/)

import 'package:cache/library/add_pdf/add_pdf_state.dart' show AddPdfStatus;
import 'package:cache/search/index_overview.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_fixtures.dart';
import '../test/add_pdf/add_pdf_world.dart';
import 'shot_kit.dart';

const _out = 'library_card_added';

void main() {
  setUpAll(loadShotFonts);

  for (final theme in CacheThemeId.values) {
    final t = theme.name;
    testWidgets('library card, a PDF added beside a paused one: $t', (tester) async {
      late AddPdfWorld w;
      await tester.runAsync(() async => w = await AddPdfWorld.make());
      phone(tester, size: const Size(390, 844), ratio: 2);
      var now = DateTime(2026, 11, 11, 13, 0);
      var pending = true;
      w.state.wordsPending = (_) => pending;
      final paused = sampleJob('paused', title: 'FEMA-IS513', paused: true);
      final added = sampleJob('added', libraryPath: w.libs.defaultOwnLibrary!.path, status: AddPdfStatus.done, state: 'done', result: {'pieces': 254, 'shelf': {'div': '530'}})..finishedAt = now;
      Widget page() => Scaffold(
        appBar: AppBar(title: const Text('Library')),
        body: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: Column(children: [IndexOverviewLine(scheduler: w.scheduler, clock: () => now)])),
      );
      Future<void> show(String name) async {
        await tester.pumpWidget(shotApp(page(), theme: theme, insets: const EdgeInsets.only(top: 44, bottom: 30)));
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 60));
        }
        await snap(tester, _out, '$name-$t');
      }

      // ignore: invalid_use_of_visible_for_testing_member
      w.state.debugSet([paused, added]);
      await show('1-added-adding-to-search-index');
      pending = false;
      // ignore: invalid_use_of_visible_for_testing_member
      w.state.debugSet([paused, added]);
      await show('2-added-pieces-searchable');
      now = now.add(const Duration(seconds: 60));
      // ignore: invalid_use_of_visible_for_testing_member
      w.state.debugSet([paused, added]);
      await show('3-paused-waiting');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async => w.dispose());
    });
  }
}

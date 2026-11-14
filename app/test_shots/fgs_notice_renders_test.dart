// The in-app notice for a background add that failed or ended (the real card, FgsAddNoticeBody), as the Library shows it at the
// top when Cache is next opened: one PDF failed; some added and some failed; ended early for a low battery; Android's time limit.
// 390 wide, light and dark. The words are drafts (marked in lib/background/fgs_add.dart). Sample data: file names are made up.
// flutter test test_shots/fgs_notice_renders_test.dart --update-goldens  (pictures in test_shots/fgs_notice/)

import 'package:cache/background/fgs_add.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/fgs_notice_card.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_fixtures.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  FgsAddResult r({String why = 'done', int total = 5, int added = 5, List<String> failed = const [], List<String> left = const [], int? battery}) =>
      FgsAddResult(at: DateTime(2026, 11, 13, 20), why: why, total: total, added: added, failedIds: failed, leftIds: left, batteryPercent: battery);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('the background add notice, 390, ${theme.name}', (tester) async {
      phone(tester, size: const Size(390, 900), ratio: 2);
      final failedOne = sampleJob('a', title: 'Radio field manual', status: AddPdfStatus.failed, error: 'embed');
      final failedTwo = sampleJob('b', title: 'Garden notes', status: AddPdfStatus.failed);
      final left = [for (final i in ['c', 'd', 'e']) sampleJob(i)];
      final notices = [
        FgsAddNotice.of(r(total: 1, added: 0, failed: ['a']), [failedOne])!,
        FgsAddNotice.of(r(total: 5, added: 3, failed: ['a', 'b']), [failedOne, failedTwo])!,
        FgsAddNotice.of(r(why: 'battery', battery: 12, left: ['c', 'd', 'e']), left)!,
        FgsAddNotice.of(r(why: 'timeout', left: ['c', 'd', 'e']), left)!,
        FgsAddNotice.of(r(why: 'battery', battery: 9, total: 3, added: 0, failed: ['a'], left: ['c', 'd']), [failedOne, ...left.take(2)])!,
      ];
      await tester.pumpWidget(shotApp(
        Scaffold(
          appBar: AppBar(title: const Text('Library')),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
            for (final n in notices) ...[FgsAddNoticeBody(notice: n, onDismiss: () {}), const SizedBox(height: 12)],
          ]),
        ),
        theme: theme,
        insets: const EdgeInsets.only(top: 44, bottom: 30),
      ));
      await tester.pumpAndSettle();
      await snap(tester, 'fgs_notice', 'notice-390-${theme.name}');
    });
  }
}

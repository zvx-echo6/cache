// A Share button in a browser with no share sheet: the Copy and Download sheet, for review.
// flutter test test_shots/web_share_renders_test.dart --update-goldens  (pictures in test_shots/web_share/)

import 'dart:io';

import 'package:cache/chat/answer_reports.dart';
import 'package:cache/platform/share_or_copy.dart' show systemShareAvailable;
import 'package:cache/screens/answer_reports_ui.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const Map<String, (Size, double, CacheThemeId)> _sizes = {
  'desktop-1440-dark': (Size(1440, 900), 1, CacheThemeId.dark),
  'phone-390-light': (Size(390, 844), 3, CacheThemeId.light),
};

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: name, value: (s, ratio, theme)) in _sizes.entries) {
    testWidgets('share sheet, $name', (tester) async {
      final before = systemShareAvailable;
      systemShareAvailable = () => false;
      addTearDown(() => systemShareAvailable = before);
      final dir = Directory.systemTemp.createTempSync('web-share-shot-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = AnswerReports(dirOverride: dir);
      await tester.runAsync(() => a.add(AnswerReport(
            at: DateTime.utc(2026, 10, 27),
            question: 'How do I treat a burn?',
            answer: 'Cool it under running water for twenty minutes [1].',
            model: 'Gemma 4 E2B',
            reason: ReportReason.harmful,
          )));
      phone(tester, size: s, ratio: ratio);
      await tester.pumpWidget(shotApp(ReportedAnswersPage(reports: a, share: (t, md) async {}),
          theme: theme, insets: name.startsWith('phone') ? null : const EdgeInsets.only(top: 24, bottom: 20)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Share'));
      await tester.pumpAndSettle();
      await snap(tester, 'web_share', name);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

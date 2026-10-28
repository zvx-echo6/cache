import 'dart:io';

import 'package:cache/chat/answer_reports.dart';
import 'package:cache/screens/answer_reports_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AnswerReport _report(String q, {DateTime? at, ReportReason reason = ReportReason.harmful}) => AnswerReport(
  at: at ?? DateTime.utc(2026, 10, 28, 9),
  question: q,
  answer: 'An answer [1].',
  model: 'Gemma 4 E2B',
  reason: reason,
  note: 'it made this up',
  sources: const ['WikiMed: Burns'],
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('answer-reports'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('the store', () {
    test('reports are kept on the phone, newest first, and survive a restart', () async {
      final a = AnswerReports(dirOverride: dir);
      expect(await a.count(), 0);
      await a.add(_report('older', at: DateTime.utc(2026, 10, 27)));
      await a.add(_report('newer', at: DateTime.utc(2026, 10, 28)));
      final again = AnswerReports(dirOverride: dir);
      final items = await again.list();
      expect(items.map((r) => r.question), ['newer', 'older']);
      expect(items.first.reason, ReportReason.harmful);
      expect(items.first.sources, ['WikiMed: Burns']);
    });

    test('remove and clear', () async {
      final a = AnswerReports(dirOverride: dir);
      await a.add(_report('one'));
      await a.add(_report('two', at: DateTime.utc(2026, 10, 29)));
      await a.remove((await a.list()).first);
      expect((await a.list()).map((r) => r.question), ['one']);
      await a.clear();
      expect(await AnswerReports(dirOverride: dir).count(), 0);
    });

    test('a damaged file reads as no reports instead of failing', () async {
      File('${dir.path}${Platform.pathSeparator}reported_answers.json').writeAsStringSync('{not json');
      expect(await AnswerReports(dirOverride: dir).count(), 0);
    });

    test('the shared Markdown has the question, the answer, the model, the reason and the sources', () {
      final md = _report('Is this safe?').toMarkdown();
      for (final s in ['Offensive or harmful', 'Gemma 4 E2B', 'Is this safe?', 'An answer [1].', 'it made this up', '1. WikiMed: Burns']) {
        expect(md, contains(s));
      }
    });
  });

  group('the screens', () {
    testWidgets('the report sheet needs a reason before it saves, and returns the note', (tester) async {
      ReportChoice? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(onPressed: () async => got = await showReportSheet(ctx), child: const Text('open')),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('report-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull, reason: 'no reason chosen yet');
      await tester.tap(find.byKey(const ValueKey('report-reason-wrong')));
      await tester.enterText(find.byKey(const ValueKey('report-note')), '  the dates are wrong  ');
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(got?.reason, ReportReason.wrong);
      expect(got?.note, 'the dates are wrong');
    });

    testWidgets('Reported answers lists, shares and removes reports', (tester) async {
      final a = AnswerReports(dirOverride: dir);
      String? shared;
      await tester.runAsync(() => a.add(_report('How do I treat a burn?')));
      await tester.pumpWidget(MaterialApp(home: ReportedAnswersPage(reports: a, share: (t, md) async => shared = md)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('How do I treat a burn?'), findsOneWidget);
      await tester.tap(find.byTooltip('Share'));
      expect(shared, contains('How do I treat a burn?'));
      await tester.runAsync(() async {
        await a.remove((await a.list()).first);
      });
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.textContaining('No reports'), findsOneWidget);
    });
  });
}

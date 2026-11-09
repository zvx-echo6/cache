import 'package:cache/theme.dart';
import 'package:cache/chat/answer_markdown.dart';
import 'package:cache/chat/answer_progress.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'one response keeps the streamed preamble through lookup, reading and delivery',
    (tester) async {
      Future<void> show(
        TurnPhase phase, {
        String? tool,
        List<String> notes = const [],
        String text = '',
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(CacheThemeId.dark),
            home: Scaffold(
              body: AnswerProgress(
                phase: phase,
                activeTool: tool,
                notes: notes,
                text: text,
              ),
            ),
          ),
        );
        await tester.pump();
      }

      const note = 'I will look that up.';
      await show(TurnPhase.answering, text: note);
      final progress = tester.element(
        find.byKey(const ValueKey('answer-progress')),
      );
      final initialPosition = tester.getTopLeft(find.byType(AnswerMarkdown));
      await show(TurnPhase.searching, tool: 'search', notes: [note]);
      expect(find.text('Looking this up…'), findsOneWidget);
      expect(
        tester.widget<AnswerMarkdown>(find.byType(AnswerMarkdown)).text,
        note,
      );
      expect(tester.getTopLeft(find.byType(AnswerMarkdown)), initialPosition);
      expect(
        identical(
          progress,
          tester.element(find.byKey(const ValueKey('answer-progress'))),
        ),
        isTrue,
      );
      await show(TurnPhase.searching, tool: 'read', notes: [note]);
      expect(find.text('Reading from source…'), findsOneWidget);
      expect(
        tester.widget<AnswerMarkdown>(find.byType(AnswerMarkdown)).text,
        note,
      );
      await show(TurnPhase.answering, notes: [note], text: 'The answer starts');
      expect(
        tester.widget<AnswerMarkdown>(find.byType(AnswerMarkdown)).text,
        '$note\n\nThe answer starts',
      );
      await show(
        TurnPhase.done,
        notes: [note],
        text: 'The answer starts here [1].',
      );
      expect(find.text('Answer delivered'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<AnswerMarkdown>(find.byType(AnswerMarkdown)).text,
        '$note\n\nThe answer starts here [1].',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('errors and empty outcomes do not claim answer delivery', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Scaffold(
          body: AnswerProgress(phase: TurnPhase.done, failed: true),
        ),
      ),
    );
    expect(find.text('Answer delivered'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

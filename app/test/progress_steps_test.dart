import 'package:cache/chat/answer_progress.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/progress_steps.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

ToolStep s(String tool, [Map<String, dynamic> args = const {}, String? title]) => ToolStep(tool, args, title);

Widget host(AnswerProgress w) => MaterialApp(theme: buildTheme(CacheThemeId.tactical), home: Scaffold(body: w));

class FourRounds implements ModelBackend {
  int calls = 0;
  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    PartialMessage call(String id, String name, String args) =>
        PartialMessage(isFinal: true, toolCalls: [ToolCall(id: id, name: name, arguments: args)]);
    switch (calls++) {
      case 0:
        yield call('a', 'search', '{"query":"water storage"}');
      case 1:
        yield call('b', 'read', '{"n":1}');
      case 2:
        yield call('c', 'calculate', '{"expression":"1 * 3"}');
      default:
        yield const PartialMessage(content: 'One gallon');
        yield const PartialMessage(isFinal: true, content: 'One gallon [1].');
    }
  }

  @override
  void stop() {}
}

void main() {
  group('templates', () {
    test('each tool, present and past, with its arguments', () {
      final cases = <(ToolStep, String, String)>[
        (s('search', {'query': 'water storage'}), 'Searching your library for "water storage"…', 'Searched your library for "water storage"'),
        (s('read', {'n': 1}, 'FEMA Are You Ready'), 'Reading FEMA Are You Ready…', 'Read FEMA Are You Ready'),
        (s('calculate', {'expression': '1+1'}), 'Calculating…', 'Calculated'),
        (s('nearby', {'category': 'pharmacies'}), 'Searching nearby for: pharmacies…', 'Searched nearby for: pharmacies'),
        (s('nearby', {'query': 'clinics'}), 'Searching nearby for: clinics…', 'Searched nearby for: clinics'),
        (s('navigate', {'to': 'Burley, Idaho'}), 'Planning a route to Burley, Idaho…', 'Planned a route to Burley, Idaho'),
        (s('navigate', {'to_type': 'emergency_room'}), 'Planning a route to emergency room…', 'Planned a route to emergency room'),
        (s('nearby', {'category': 'emergency_room'}), 'Searching nearby for: emergency room…', 'Searched nearby for: emergency room'),
        (s('locate'), 'Finding where you are…', 'Found where you are'),
        (s('act', {'action': 'notes.add'}, 'Add a note'), 'Running Add a note…', 'Ran Add a note'),
        (s('act', {'action': 'notes.add'}), 'Running notes.add…', 'Ran notes.add'),
      ];
      for (final (step, now, past) in cases) {
        expect(stepPresent(step), now);
        expect(stepPast(step), past);
      }
    });

    test('each tool without arguments', () {
      final cases = <(String, String, String)>[
        ('search', 'Searching your library…', 'Searched your library'),
        ('read', 'Reading a source…', 'Read a source'),
        ('calculate', 'Calculating…', 'Calculated'),
        ('nearby', 'Looking for places near you…', 'Looked for places near you'),
        ('navigate', 'Planning a route…', 'Planned a route'),
        ('locate', 'Finding where you are…', 'Found where you are'),
        ('act', 'Running an action…', 'Ran an action'),
      ];
      for (final (tool, now, past) in cases) {
        expect(stepPresent(s(tool)), now);
        expect(stepPast(s(tool)), past);
      }
    });

    test('an unknown tool is Working…', () {
      expect(stepPresent(s('web_fetch', {'url': 'x'})), 'Working…');
    });

    test('values are trimmed, collapsed and unquoted', () {
      final long = 'a' * 100;
      final v = stepValue(long)!;
      expect(v.length, 61);
      expect(v.endsWith('…'), isTrue);
      expect(stepValue('  water \n\t  storage  '), 'water storage');
      expect(stepValue('the "best" water'), 'the best water');
      expect(stepValue('“smart” quotes'), 'smart quotes');
      expect(stepValue('""'), isNull);
      expect(stepValue(5), isNull);
      expect(stepPresent(s('search', {'query': '"$long"'})), 'Searching your library for "${'a' * 60}…"…');
      expect(stepPresent(s('search', {'query': '   '})), 'Searching your library…');
    });
  });

  group('trail through a 4-round answer', () {
    test('grows one tick per tool and the read names its source', () async {
      final chat = ChatController(
        actCore: const ActCoreStandIn(),
        tools: [BatchSearch([[hit('FEMA Are You Ready', 'Store a gallon.')]])],
      )..setBackend(FourRounds());
      final seen = <List<String>>[];
      final active = <String?>[];
      chat.addListener(() {
        if (chat.messages.isEmpty || chat.messages.last.isUser) return;
        final m = chat.messages.last;
        final now = [for (final x in m.steps) stepPast(x)];
        if (seen.isEmpty || seen.last.length != now.length) seen.add(now);
        if (m.activeStep != null) active.add(stepPresent(m.activeStep!));
      });
      await chat.send('water?');
      expect([for (final x in seen) x.length], [0, 1, 2, 3]);
      expect(seen.last, [
        'Searched your library for "water storage"',
        'Read FEMA Are You Ready',
        'Calculated',
      ]);
      expect(active, contains('Reading FEMA Are You Ready…'));
      expect(active, contains('Calculating…'));
      final m = chat.messages.last;
      expect(m.steps.length, 3);
      expect(m.activeStep, isNull);
      expect(m.text, 'One gallon [1].');
    });
  });

  group('widget', () {
    final trail = [
      s('search', {'query': 'water storage'}),
      s('read', {'n': 1}, 'FEMA Are You Ready'),
      s('calculate'),
    ];

    testWidgets('while a tool runs: trail ticks above the current line, spinner stays', (tester) async {
      await tester.pumpWidget(host(AnswerProgress(
        phase: TurnPhase.searching,
        activeTool: 'calculate',
        activeStep: s('calculate'),
        steps: trail.sublist(0, 2),
      )));
      expect(find.text('Searched your library for "water storage"'), findsOneWidget);
      expect(find.text('Read FEMA Are You Ready'), findsOneWidget);
      expect(find.text('Calculating…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNWidgets(2));
      expect(find.byKey(const ValueKey('answer-trail-toggle')), findsNothing);
      expect(tester.widget<Text>(find.text('Calculating…')).style!.fontSize, 15);
      expect(tester.widget<Text>(find.text('Read FEMA Are You Ready')).style!.fontSize, 13);
    });

    testWidgets('between tools it says Preparing answer… and adds no step', (tester) async {
      await tester.pumpWidget(host(AnswerProgress(phase: TurnPhase.thinking, steps: trail.sublist(0, 1))));
      expect(find.text('Preparing answer…'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('collapses when text starts, expands and collapses on tap', (tester) async {
      final handle = tester.ensureSemantics();
      Future<void> show(TurnPhase p, String text) => tester.pumpWidget(host(AnswerProgress(phase: p, steps: trail, text: text)));
      await show(TurnPhase.searching, '');
      expect(find.text('Calculated'), findsOneWidget);
      await show(TurnPhase.answering, 'Store one gallon');
      expect(find.byKey(const ValueKey('answer-progress')), findsNothing);
      expect(find.text('Preparing answer…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('3 steps'), findsOneWidget);
      expect(find.text('Calculated'), findsNothing);
      expect(find.bySemanticsLabel('3 steps, show steps'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('answer-trail-toggle'))).height, greaterThanOrEqualTo(44));

      await tester.tap(find.byKey(const ValueKey('answer-trail-toggle')));
      await tester.pump();
      expect(find.text('Calculated'), findsOneWidget);
      expect(find.text('Read FEMA Are You Ready'), findsOneWidget);
      expect(find.bySemanticsLabel('3 steps, hide steps'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('answer-trail-toggle')));
      await tester.pump();
      expect(find.text('Calculated'), findsNothing);
      expect(find.text('3 steps'), findsOneWidget);

      // Stays collapsed when done, beside the delivered state.
      await show(TurnPhase.done, 'Store one gallon [1].');
      expect(find.text('3 steps'), findsOneWidget);
      expect(find.text('Answer delivered'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('one step reads 1 step, and stays collapsed when a note empties the text', (tester) async {
      await tester.pumpWidget(host(AnswerProgress(phase: TurnPhase.answering, steps: trail.sublist(0, 1), text: 'Preamble')));
      expect(find.text('1 step'), findsOneWidget);
      await tester.pumpWidget(host(AnswerProgress(
        phase: TurnPhase.searching,
        activeStep: trail[1],
        steps: trail.sublist(0, 1),
        notes: const ['Preamble'],
      )));
      expect(find.text('1 step'), findsOneWidget);
    });

    testWidgets('queue text is unchanged and shows no trail', (tester) async {
      await tester.pumpWidget(host(const AnswerProgress(phase: TurnPhase.thinking, queuePosition: 3)));
      expect(find.text('Waiting for 3 answers ahead to finish'), findsOneWidget);
      await tester.pumpWidget(host(const AnswerProgress(phase: TurnPhase.thinking, queuePosition: 1)));
      expect(find.text('Waiting for another answer to finish'), findsOneWidget);
      expect(find.byKey(const ValueKey('answer-trail')), findsNothing);
    });
  });
}

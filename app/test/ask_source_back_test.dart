// B49: Back from a cited source returns to Ask at the same answer (the source opens over the shell, not in the Library's stack), and
// an answer with no sources shows no citation marks.
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/reader_screen.dart';
import 'package:cache/chat/answer_markdown.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/act_core_stand_in.dart';
import 'support/settings_rig.dart';

const _u = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
const _answer = 'Water boils at 100 degrees at sea level.';

void main() {
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('Back from a cited source', () {
    testWidgets('lands on Ask at the same answer', (tester) async {
      tester.view.physicalSize = const Size(390, 844) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      r = await SettingsRig.create(tester);
      final dir = Directory('${r.dir.path}/layout')..createSync();
      PanePrefs.testDir = dir;
      addTearDown(() => PanePrefs.testDir = null);
      layout = LayoutState(settingsDirOverride: dir);
      await tester.runAsync(layout.init);
      nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
      final zim = ZimFile(path: '${r.sources.zimsDir!.path}/wikipedia_en_all_2026-08.zim', size: 1 << 30);
      r.sources.zims = [zim];
      r.sources.ids[zim.path] = _u;
      await tester.runAsync(() async {
        File('${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf').writeAsBytesSync(List.filled(16, 0));
        await r.app.refreshModels();
      });
      r.chat.messages.add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = _answer
        ..sources = const [NumberedResult(1, SourceResult(title: 'Water', snippet: '', address: 'zim:$_u/A/Water'))]);
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: buildTheme(CacheThemeId.light),
        home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: Directory('${r.dir.path}/layout'))),
      ));
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ask')));
      await settle(tester);
      expect(find.textContaining('Water boils'), findsOneWidget);

      await tester.tap(find.text('1 source'));
      await settle(tester);
      await tester.tap(find.text('Open the article'));
      await settle(tester);
      expect(find.byType(ZimReaderScreen), findsOneWidget, reason: 'the reader is open');
      // (The test has no web view, so the reader's page builds with an error; the route is what is under test.)
      while (tester.takeException() != null) {}

      Navigator.of(tester.element(find.byType(ZimReaderScreen))).pop(); // Back
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      while (tester.takeException() != null) {}
      expect(find.byType(ZimReaderScreen), findsNothing);
      expect(find.byType(AskScreen), findsOneWidget, reason: 'Back is Ask, not the Library');
      expect(find.textContaining('Water boils'), findsOneWidget, reason: 'at the same answer');

      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      layout.dispose();
      await r.dispose(tester);
    });
  });

  group('an answer with no sources shows no citation marks', () {
    Future<void> show(WidgetTester tester, String text, {List<NumberedResult> sources = const []}) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('cite-marks-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
      chat.messages.add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = text
        ..sources = sources);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
      await tester.pump();
      addTearDown(() {
        chat.dispose();
        app.dispose();
      });
    }

    String shown(WidgetTester tester) => tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data;

    testWidgets('[1, 2] is not shown', (tester) async {
      await show(tester, 'Ray Charles is known for playing the tenor saxophone [1, 2].');
      expect(find.textContaining('Not from your sources'), findsOneWidget);
      expect(find.textContaining('[1'), findsNothing);
      expect(find.textContaining('Ray Charles is known for playing the tenor saxophone.'), findsOneWidget);
    });

    testWidgets('[3] is not shown', (tester) async {
      await show(tester, 'It boils at 100 degrees [3].');
      expect(find.textContaining('[3'), findsNothing);
      expect(find.textContaining('It boils at 100 degrees.'), findsOneWidget);
    });

    testWidgets('with sources the marks are unchanged', (tester) async {
      await show(tester, 'It boils [1, 2] and [1].', sources: const [NumberedResult(1, SourceResult(title: 'Water', snippet: '', address: 'zim:$_u/A/Water'))]);
      expect(shown(tester), contains('[1, 2]'));
      expect(shown(tester), contains(r'\[1\]'), reason: 'a citation, as the answer shows it');
    });

    testWidgets('bracketed text that is not a citation stays', (tester) async {
      await show(tester, 'Boil it [see below] and note [a] and [1a] and `x[1, 2]`.');
      expect(find.textContaining('[see below]'), findsOneWidget);
      expect(find.textContaining('[a]'), findsOneWidget);
      expect(find.textContaining('[1a]'), findsOneWidget);
    });

    test('the forms dropped, with the space before each', () {
      expect(dropCitationMarks('a [1] b [1, 2] c [1,2,3] d [4-6] e [2 - 3].'), 'a b c d e.');
    });

    test('a bracket with a 0 is never a citation: it stays', () {
      expect(dropCitationMarks('the value lies in [0, 1] and [0] and x[0] but not [1, 2] or [3] or [10].'), 'the value lies in [0, 1] and [0] and x[0] but not or or.');
    });

    testWidgets('[0, 1], [0] and x[0] stay in an answer with no sources, and [1, 2] and [3] still go', (tester) async {
      await show(tester, r'Use list[0] when [0] is empty; the value lies in [0, 1] [1, 2] [3].');
      expect(find.textContaining('list[0]'), findsOneWidget);
      expect(find.textContaining('[0, 1]'), findsOneWidget);
      expect(find.textContaining('[1, 2]'), findsNothing);
      expect(find.textContaining('[3]'), findsNothing);
    });

    testWidgets('the stored text is unchanged', (tester) async {
      const text = 'Ray Charles played tenor saxophone [1, 2].';
      await show(tester, text);
      final chat = tester.widget<AskScreen>(find.byType(AskScreen)).chat;
      expect(chat.messages.single.text, text);
    });
  });
}

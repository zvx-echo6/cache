// Cache on Linux, Ask: Enter sends and Shift+Enter makes a new line (desktop only; a phone keeps its keyboard's Enter).
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

void main() {
  late AppState app;
  late ChatController chat;
  late ScriptedBackend backend;

  /// Enter presses the composer left alone (the field then adds its own new line, as a phone's does).
  var passedOn = 0;

  Finder box() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Ask anything');

  Future<void> show(WidgetTester tester, Size size, {bool linux = true, int sources = 0}) async {
    debugLinuxUi = linux;
    addTearDown(() => debugLinuxUi = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    passedOn = 0;
    final dir = Directory.systemTemp.createTempSync('ask-keys-');
    addTearDown(() => dir.deleteSync(recursive: true));
    app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..active = ModelEntry(path: '${dir.path}/m.gguf', size: 1);
    backend = ScriptedBackend([(_) => say('Boil it.')]);
    chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..setBackend(backend);
    if (sources > 0) {
      chat.messages
        ..add(ChatMessage.user('How do I purify water?'))
        ..add(ChatMessage.assistant()
          ..phase = TurnPhase.done
          ..text = [for (var i = 0; i < 24; i++) 'Boiling is the most reliable way to treat drinking water [1].'].join('\n\n')
          ..sources = [for (var i = 1; i <= sources; i++) NumberedResult(i, SourceResult(title: 'Source number $i', snippet: 'A passage from source $i.', address: 'zim:x/A/S$i'))]);
    }
    addTearDown(() {
      chat.dispose();
      app.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Focus(
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter) passedOn++;
        return KeyEventResult.ignored;
      },
      child: AskScreen(app: app, chat: chat),
    )));
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester, {bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  Future<void> typeIn(WidgetTester tester, String text) async {
    await tester.tap(box());
    await tester.pump();
    tester.testTextInput.enterText(text);
    await tester.pump();
  }

  String field(WidgetTester tester) => tester.widget<TextField>(box()).controller!.text;

  group('Enter in the Ask composer', () {
    testWidgets('on the desktop, Enter sends the question', (tester) async {
      await show(tester, const Size(1440, 900));
      await typeIn(tester, 'How long do I boil water?');
      await enter(tester);
      expect(field(tester), isEmpty, reason: 'the question was sent, the box cleared');
      expect(chat.messages.first.text, 'How long do I boil water?');
      expect(passedOn, 0, reason: 'the composer took the Enter');
      for (var i = 0; i < 20 && !chat.messages.last.isDone; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(backend.requests, hasLength(1));
    });

    testWidgets('on the desktop, Shift+Enter makes a new line and sends nothing', (tester) async {
      await show(tester, const Size(1440, 900));
      await typeIn(tester, 'first');
      await enter(tester, shift: true);
      expect(field(tester), 'first', reason: 'nothing was sent');
      expect(passedOn, 1, reason: 'the Enter went on to the field, which adds the line');
      expect(chat.messages, isEmpty);
    });

    testWidgets('on the desktop, Enter in an empty box sends nothing and adds no line', (tester) async {
      await show(tester, const Size(1440, 900));
      await tester.tap(box());
      await tester.pump();
      await enter(tester);
      expect(chat.messages, isEmpty);
      expect(field(tester), isEmpty);
      expect(passedOn, 0);
    });

    testWidgets('a phone-size window is unchanged: Enter makes a new line and sends nothing', (tester) async {
      await show(tester, const Size(390, 844));
      await typeIn(tester, 'first');
      await enter(tester);
      expect(field(tester), 'first', reason: 'nothing was sent');
      expect(passedOn, 1, reason: 'the Enter went on to the field, which adds the line');
      expect(chat.messages, isEmpty);
    });

    testWidgets('a wide window that is not Cache on Linux is unchanged', (tester) async {
      await show(tester, const Size(1440, 900), linux: false);
      await typeIn(tester, 'first');
      await enter(tester);
      expect(field(tester), 'first', reason: 'nothing was sent');
      expect(passedOn, 1, reason: 'the Enter went on to the field, which adds the line');
      expect(chat.messages, isEmpty);
    });
  });
}

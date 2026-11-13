// Cache on Linux, Ask: the sources of an answer are all within reach once opened.
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

void main() {
  late AppState app;
  late ChatController chat;
  late ScriptedBackend backend;

  Finder box() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Ask anything');

  Future<void> show(WidgetTester tester, Size size, {int sources = 0}) async {
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
    await tester.pump();
  }

  group('the sources of an answer', () {
    testWidgets('with 5 sources, every one is reachable above the composer on the desktop', (tester) async {
      await show(tester, const Size(1440, 900), sources: 5);
      await tester.tap(find.text('5 sources'));
      await tester.pump();
      await tester.pump();
      final composerTop = tester.getTopLeft(box()).dy;
      for (var i = 1; i <= 5; i++) {
        final f = find.text('[$i] Source number $i');
        expect(f, findsOneWidget);
        final r = tester.getRect(f);
        expect(r.bottom, lessThanOrEqualTo(composerTop), reason: 'source $i is clear of the composer');
        expect(r.top, greaterThanOrEqualTo(0), reason: 'source $i is on screen');
      }
    });

    testWidgets('on a phone every source is still reachable by scrolling', (tester) async {
      await show(tester, const Size(390, 844), sources: 5);
      await tester.tap(find.text('5 sources'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('[5] Source number 5'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('[5] Source number 5'), findsOneWidget);
    });
  });
}

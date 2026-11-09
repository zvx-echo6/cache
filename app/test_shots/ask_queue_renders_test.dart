// The Ask screen while an answer waits on the server for others to finish (the browser build's queue), for review.
// flutter test test_shots/ask_queue_renders_test.dart --update-goldens  (pictures in test_shots/ask_queue/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

const Map<String, (Size, double)> _sizes = {
  'phone-390': (Size(390, 844), 3),
  'desktop-1440': (Size(1440, 900), 1),
};

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: size, value: (s, ratio)) in _sizes.entries) {
    for (final ahead in [1, 2]) {
      testWidgets('waiting, $ahead ahead, $size', (tester) async {
        final dir = Directory.systemTemp.createTempSync('ask-queue-shot-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
        final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
        chat.messages
          ..add(ChatMessage.user('How long should I boil water to make it safe to drink?'))
          ..add(ChatMessage.assistant()..queuePosition = ahead);
        phone(tester, size: s, ratio: ratio);
        await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat),
            insets: size.startsWith('phone') ? null : const EdgeInsets.only(top: 24, bottom: 20)));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        await snap(tester, 'ask_queue', '$size-$ahead-ahead');
        await tester.pumpWidget(const SizedBox.shrink());
        chat.dispose();
        app.dispose();
      });
    }
  }
}

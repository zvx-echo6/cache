// The Ask screen when the chat is full, for review: a question that does not fit (message and New chat), and an answer cut off
// by the context (note and New chat), at 390 points wide in Light, Dark and Tactical.
// flutter test test_shots/chat_full_renders_test.dart --update-goldens  (pictures in test_shots/chat_full/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

const Map<String, CacheThemeId> _themes = {'light': CacheThemeId.light, 'dark': CacheThemeId.dark, 'tactical': CacheThemeId.tactical};

ChatMessage _answer(String text) => ChatMessage.assistant()
  ..text = text
  ..phase = TurnPhase.done;

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: name, value: theme) in _themes.entries) {
    for (final state in ['full', 'cut']) {
      testWidgets('$state, phone-390, $name', (tester) async {
        final dir = Directory.systemTemp.createTempSync('chat-full-shot-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
        final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
        if (state == 'full') {
          chat.messages
            ..add(ChatMessage.user('How long should I boil water to make it safe to drink?'))
            ..add(_answer('Boil it at a rolling boil for one minute. Above 6,500 feet (2,000 meters), boil it for three minutes.'))
            ..add(ChatMessage.user('What if I have no fuel to boil it?'))
            ..add(_answer('Filter it, then treat it with chlorine dioxide tablets or unscented household bleach, and let it stand for at least 30 minutes.'))
            ..add(ChatMessage.user('How much bleach per gallon?'))
            ..add(ChatMessage.assistant()
              ..chatFull = true
              ..phase = TurnPhase.done);
        } else {
          chat.messages
            ..add(ChatMessage.user('Give me a full plan for a week without power in winter.'))
            ..add(_answer('Start with heat, water and food, in that order.\n\n'
                '1. Heat. Pick one room, close the doors and hang blankets over the windows. Wear layers, a hat and dry socks, and keep moving.\n\n'
                '2. Water. Store at least one gallon per person per day, and fill the bathtub before the pipes can freeze.\n\n'
                '3. Food. Eat the fridge first, then the freezer, then dry goods. Keep the doors shut so the cold stays in. After that, the pantry, which you should rotate so that the oldest cans are used up before')
              ..cutShort = true);
        }
        phone(tester, size: const Size(390, 844), ratio: 3);
        await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat), theme: theme));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        await snap(tester, 'chat_full', 'phone-390-$state-$name');
        await tester.pumpWidget(const SizedBox.shrink());
        chat.dispose();
        app.dispose();
      });
    }
  }
}

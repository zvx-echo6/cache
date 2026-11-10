// The Ask screen's progress line and its trail of finished steps, for review: mid-answer, writing (trail collapsed) and the trail
// expanded, in the light, dark and Tactical themes.
// flutter test test_shots/ask_progress_renders_test.dart --update-goldens  (pictures in test_shots/ask_progress/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/progress_steps.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

const Map<String, (Size, double)> _sizes = {
  'phone-390': (Size(390, 844), 3),
  'desktop-1440': (Size(1440, 900), 1),
};

const Map<String, CacheThemeId> _themes = {
  'light': CacheThemeId.light,
  'dark': CacheThemeId.dark,
  'tactical': CacheThemeId.tactical,
};

const _question = 'How much water should I store per person for an emergency kit?';

final _search = const ToolStep('search', {'query': 'emergency water storage per person'});
final _read = const ToolStep('read', {'n': 1}, 'FEMA: Are You Ready?');
final _calc = const ToolStep('calculate', {'expression': '1 gallon/day * 3 days'});

const _answer = 'Store at least one gallon of water per person per day, for drinking and basic hygiene [1].\n\n'
    'Keep a minimum of a three-day supply for each person. Plan on two weeks if you can, and add more for children, '
    'nursing mothers, sick people and hot climates.\n\n'
    'For a household of four that is 12 gallons for three days [1].';

void main() {
  setUpAll(loadShotFonts);

  for (final MapEntry(key: size, value: (s, ratio)) in _sizes.entries) {
    for (final MapEntry(key: themeName, value: theme) in _themes.entries) {
      testWidgets('progress, $size, $themeName', (tester) async {
        final dir = Directory.systemTemp.createTempSync('ask-progress-shot-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
        final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
        final reply = ChatMessage.assistant()
          ..phase = TurnPhase.searching
          ..activeTool = 'calculate'
          ..activeStep = _calc
          ..steps = [_search, _read];
        chat.messages
          ..add(ChatMessage.user(_question))
          ..add(reply);
        phone(tester, size: s, ratio: ratio);
        Future<void> shoot(String name) async {
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          await snap(tester, 'ask_progress', '$size-$themeName-$name');
        }

        Future<void> show() => tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat),
            theme: theme, insets: size.startsWith('phone') ? null : const EdgeInsets.only(top: 24, bottom: 20)));
        await show();
        await shoot('a-working');

        reply
          ..phase = TurnPhase.answering
          ..activeTool = null
          ..activeStep = null
          ..steps = [_search, _read, _calc]
          ..text = _answer;
        await show();
        await shoot('b-writing');

        await tester.tap(find.byKey(const ValueKey('answer-trail-toggle')));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await shoot('c-expanded');

        await tester.pumpWidget(const SizedBox.shrink());
        chat.dispose();
        app.dispose();
      });
    }
  }
}

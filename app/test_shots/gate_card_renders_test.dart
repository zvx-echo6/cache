// The Ask "not loaded" card when the memory gate holds the model back: three styles in the four themes, for the owner to choose from.
// flutter test test_shots/gate_card_renders_test.dart --update-goldens  (pictures in test_shots/gate_card/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  tearDown(() => gateCardStyle = GateCardStyle.today);

  for (final theme in CacheThemeId.values) {
    for (final style in GateCardStyle.values) {
      testWidgets('gate card, ${style.name}, ${theme.name}', (tester) async {
        final dir = Directory.systemTemp.createTempSync('gate-card-shot-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/Gemma 4 E2B.gguf')..writeAsBytesSync(List.filled(16, 0));
        final app = AppState(
          settingsDirOverride: dir,
          modelsDirOverride: dir,
          memory: () async => const MemoryReading(avail: 900 << 20, total: 8 << 30, threshold: 200 << 20),
        );
        app.models = [ModelEntry(path: file.path, size: 16)];
        app.started = true;
        app.resting = app.models.first;
        await app.wake(); // the gate holds it back: heldForMemory
        expect(app.heldForMemory, isTrue);
        gateCardStyle = style;
        final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
        phone(tester, size: const Size(390, 844), ratio: 3);
        await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat), theme: theme));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        await snap(tester, 'gate_card', 'phone-390-${theme.name}-${style.name}');
        await tester.pumpWidget(const SizedBox.shrink());
        chat.dispose();
        app.dispose();
      });
    }
  }
}

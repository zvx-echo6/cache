// Ask's slim load bar (resting, waiting for free memory, loading) and a question held in the chat until the model has loaded, 390 x 844,
// light and dark.
// flutter test test_shots/ask_load_bar_renders_test.dart --update-goldens  (pictures in test_shots/ask_load_bar/)

import 'dart:convert';
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

enum _State { resting, gate, loading }

void main() {
  setUpAll(loadShotFonts);

  Future<void> render(WidgetTester tester, CacheThemeId theme, _State state, {String? held, required String name}) async {
    final dir = Directory.systemTemp.createTempSync('ask-load-bar-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState(
      settingsDirOverride: dir,
      modelsDirOverride: dir,
      memory: () async => const MemoryReading(avail: 900 << 20, total: 8 << 30, threshold: 200 << 20),
    );
    final named = File('${dir.path}/Gemma-4-E2B-it-Q4_K_M.gguf')..writeAsBytesSync(List.filled(16, 0));
    final key = '${named.uri.pathSegments.last}|16';
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({
      'lastModel': named.uri.pathSegments.last,
      'names': {key: 'Gemma 4 E2B · Q4_K_M'},
      'plainNames': {key: 'Gemma 4 E2B'},
    }));
    app.models = [ModelEntry(path: named.path, size: 16)];
    app.started = true;
    await tester.runAsync(app.init);
    expect(app.heldForMemory, isTrue);
    if (state != _State.gate) app.heldForMemory = false;
    if (state == _State.loading) {
      app.loading = app.resting;
      app.resting = null;
    }
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
    final heldText = ValueNotifier<String?>(held);
    phone(tester, size: const Size(390, 844), ratio: 3);
    await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat, held: heldText, onHold: (_) {}), theme: theme));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, 'ask_load_bar', name);
    await tester.pumpWidget(const SizedBox.shrink());
    chat.dispose();
    app.dispose();
    heldText.dispose();
  }

  const question = 'What should I do if my water filter clogs on a long trip?';
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    final t = theme.name;
    testWidgets('resting, empty chat, $t', (tester) => render(tester, theme, _State.resting, name: 'a-resting-$t'));
    testWidgets('waiting for memory, $t', (tester) => render(tester, theme, _State.gate, name: 'b-waiting-memory-$t'));
    testWidgets('held question, resting, $t', (tester) => render(tester, theme, _State.resting, held: question, name: 'c1-held-resting-$t'));
    testWidgets('held question, loading, $t', (tester) => render(tester, theme, _State.loading, held: question, name: 'c2-held-loading-$t'));
    testWidgets('held question, waiting for memory, $t', (tester) => render(tester, theme, _State.gate, held: question, name: 'c3-held-waiting-memory-$t'));
  }
}

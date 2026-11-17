// Ask's model menu: an Unload the server could not do says so (the same words as the Models screen).
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

class _FailingUnload implements LlamaSession {
  @override
  Future<void> unload() async => throw StateError('The server could not unload the model (HTTP 500)');

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  testWidgets('Unload from the Ask menu with a failing server shows "Could not unload the model: <reason>"', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('ask-unload-fail-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir, session: _FailingUnload())..active = ModelEntry(path: '${dir.path}/m.gguf', size: 1);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..setBackend(ScriptedBackend([(_) => say('ok')]));
    addTearDown(() {
      chat.dispose();
      app.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('model-name')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-menu-unload')));
    await tester.pumpAndSettle();
    expect(find.text('Could not unload the model: The server could not unload the model (HTTP 500)'), findsOneWidget);
    expect(app.active, isNotNull);
  });
}

// Ask > Switch model with the two recommended Q4 files and a model that is not recommended, drawn by the app itself with sample
// data (no personal data), for the owner to review.
// flutter test test_shots/model_twin_names_renders_test.dart --update-goldens  (picture in test_shots/model_twin_names/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import '../test/support/gguf_bytes.dart';
import 'shot_kit.dart';

class _Session implements LlamaSession {
  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async =>
      const ModelInfo(description: 'llama 256M Q4_0', nCtx: 8192, chatFormat: 'x', supportsTools: true);
  @override
  Future<void> unload() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('Switch model, ${theme.name}', (tester) async {
      final dir = Directory.systemTemp.createTempSync('twin-shot');
      addTearDown(() => dir.deleteSync(recursive: true));
      final models = Directory('${dir.path}/models')..createSync();
      final app = AppState(
        settingsDirOverride: dir,
        modelsDirOverride: models,
        memory: () async => const MemoryReading(avail: 8 << 30, total: 16 << 30, threshold: 200 << 20),
        session: _Session(),
      );
      addTearDown(app.dispose);
      final list = RecommendedModels(
        builtIn: () async => File('assets/models/recommended.json').readAsStringSync(),
        fetch: () async => throw const SocketException('offline'),
      );
      await tester.runAsync(list.load);
      app.modelsDir = models;
      app.isRecommended = (e) => list.isRecommendedFile(e.fileName);
      app.recommendedName = (e) => list.nameOfFile(e.fileName);
      ModelEntry at(String f, int size) => ModelEntry(path: '${models.path}/$f', size: size);
      final q6 = at('e2b-stock-cache-1.0-Q6_K.gguf', 3845346304);
      final stock = at('e2b-stock-cache-1.0-Q4_K_M.gguf', 3427879936);
      final trevor = at('e2b-trevorjs-cache-1.0-Q4_K_M.gguf', 3427873312);
      final smol = at('SmolLM2-135M-Instruct-Q4_0.gguf', 120 << 20);
      File(smol.path).writeAsBytesSync(ggufBytes([kvString('general.name', 'SmolLM2 135M Instruct')]));
      await tester.runAsync(() => app.activate(smol));
      app.models = [stock, trevor, smol];
      app.active = q6;

      phone(tester);
      await tester.pumpWidget(shotApp(AskScreen(app: app, chat: ChatController(actCore: const ActCoreStandIn(), tools: const [])), theme: theme));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('model-name')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-menu-switch')));
      await tester.pumpAndSettle();
      await snap(tester, 'model_twin_names', 'switch-model-${theme.name}');
    });
  }
}

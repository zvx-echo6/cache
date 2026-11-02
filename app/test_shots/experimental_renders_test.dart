// Models, Experimental (1.0.30): the heading line and the "Uncensored" tag on the uncensored entries only, drawn by the app with
// the built-in list. flutter test test_shots/experimental_renders_test.dart --update-goldens  (pictures in test_shots/experimental/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const _out = 'experimental';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('Models scrolled to Experimental, light and dark', (tester) async {
    final dir = Directory.systemTemp.createTempSync('experimental-shots');
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
    app.modelsDir = Directory('${dir.path}/models')..createSync();
    ModelDownloads.shared = ModelDownloads(app: app);
    addTearDown(() => ModelDownloads.shared = null);
    final docs = File('../docs/models-recommended.json').readAsStringSync();
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final recs = RecommendedModels(builtIn: () async => docs, fetch: () async => throw const SocketException('offline'));
      phone(tester);
      await tester.pumpWidget(shotApp(ModelsScreen(app: app, recommended: recs, memory: 8 << 30), theme: theme));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.scrollUntilVisible(find.byKey(const ValueKey('experimental-note')), 300, scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 120));
      await tester.pumpAndSettle();
      await snap(tester, _out, 'models-experimental${theme == CacheThemeId.dark ? '-dark' : ''}');
    }
  });
}

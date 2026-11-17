// Settings > Cache model and web search with the chosen model resting (not loaded after a cold start).
// flutter test test_shots/model_resting_renders_test.dart --update-goldens  (pictures in test_shots/model_resting/)

import 'package:cache/app_state.dart' show ModelEntry;
import 'package:cache/screens/settings/assistant_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);

  testWidgets('model page resting 390', (tester) async {
    final r = await SettingsRig.create(tester);
    r.app.resting = ModelEntry(path: '/models/Gemma-4-E2B-it-Q4_K_M.gguf', size: 3 * 1024 * 1024 * 1024);
    phone(tester, size: const Size(390, 844), ratio: 2);
    await tester.pumpWidget(shotApp(AssistantPage(deps: r.deps)));
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(find.byType(AssistantPage), matchesGoldenFile('model_resting/after.png'));
    await r.dispose(tester);
  });
}

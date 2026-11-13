// Ask on Linux with the sources opened: every one of the 4 is in reach above the composer (1440 x 900, light and dark).
// flutter test test_shots/ask_sources_renders_test.dart --update-goldens  (pictures in test_shots/ask-sources/)
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/linux_ui.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('ask sources ${theme.name}', (tester) async {
      debugLinuxUi = true;
      addTearDown(() => debugLinuxUi = null);
      phone(tester, size: const Size(1440, 900), ratio: 1);
      final dir = Directory.systemTemp.createTempSync('ask-src-shot-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..active = ModelEntry(path: '${dir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 1);
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
      addTearDown(() {
        chat.dispose();
        app.dispose();
      });
      const titles = ['Purifying Drinking Water, p. 2', 'Field Water Treatment, p. 14', 'Camp Sanitation, p. 31', 'Boiling and Chlorine, p. 8'];
      chat.messages
        ..add(ChatMessage.user('How do I purify water?'))
        ..add(ChatMessage.assistant()
          ..phase = TurnPhase.done
          ..text = [
            'The library gives two main methods for purifying water:',
            '**Boiling** is the most reliable way to treat drinking water [1]. Boiling alone kills bacteria, viruses and protozoa after one minute [4].',
            '**Chlorine** is another option. Chlorine bleach drops and filtration purify water for drinking in the field [4].',
            '**Rainwater:** Water collected in clean containers is usually safe to drink [5].',
            '**Be careful with wildlife.** Dig your camp latrine at least 200 feet from the water source to prevent contamination [3].',
            'The sources do not say which method works best in the field. I cannot say from the library.',
          ].join('\n\n')
          ..sources = [for (var i = 0; i < titles.length; i++) NumberedResult(i + 1, SourceResult(title: titles[i], snippet: 'A passage from the book.', address: 'zim:x/A/S$i'))]);
      await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat), theme: theme, insets: EdgeInsets.zero, desktop: true));
      await tester.pump();
      await tester.tap(find.text('4 sources'));
      await tester.pump();
      await tester.pump();
      await snap(tester, 'ask-sources', 'sources-open-${theme.name}');
    });
  }
}

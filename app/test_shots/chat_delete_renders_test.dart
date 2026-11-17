// "Delete this chat?" (owner's design, build 53): Cancel / Delete, from a chat's long-press menu in the history list.
// 390 wide light (phone), 1440 wide dark (web). Chats never sync, so there is no synced line.
// flutter test test_shots/chat_delete_renders_test.dart --update-goldens  (pictures in test_shots/chat_delete/)
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/screens/history_drawer.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  const folder = 'chat_delete';

  Future<void> shot(WidgetTester tester, {required Size size, required double ratio, required CacheThemeId theme, required bool desktop, required String name}) async {
    phone(tester, size: size, ratio: ratio);
    final store = ConversationStore.memory(now: () => DateTime(2026, 11, 17, 9));
    addTearDown(store.close);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..attachStore(store);
    final c = store.create(title: 'Snake bite');
    store.addMessage(c.id, role: 'user', content: 'bite?', message: {'role': 'user', 'content': 'bite?'});
    store.create(title: 'Water from a stream');
    await tester.pumpWidget(shotApp(
      Scaffold(body: HistoryDrawer(chat: chat, now: () => DateTime(2026, 11, 17, 12), docked: true)),
      theme: theme,
      desktop: desktop,
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Snake bite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await snap(tester, folder, name);
  }

  testWidgets('dialog, phone-390 light', (tester) => shot(tester, size: const Size(390, 844), ratio: 2, theme: CacheThemeId.light, desktop: false, name: 'phone-390-light'));
  testWidgets('dialog, web-1440 dark', (tester) => shot(tester, size: const Size(1440, 900), ratio: 1, theme: CacheThemeId.dark, desktop: true, name: 'web-1440-dark'));
}

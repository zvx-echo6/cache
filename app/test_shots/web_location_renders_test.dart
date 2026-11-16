// Cache on Linux (browser), Ask with the location blocked in the browser: a question is sent with location on, and the allow-location
// dialog the map shows is on screen (1440 x 900, dark). SHOT_NAME names the picture (before / after).
// SHOT_NAME=after flutter test test_shots/web_location_renders_test.dart --update-goldens  (picture in test_shots/web_location/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/chat_fakes.dart';
import '../test/location_service_test.dart' show FakeSource;
import '../test/support/act_core_stand_in.dart';
import 'shot_kit.dart';

void main() {
  testWidgets('Ask, location blocked in the browser', (tester) async {
    await loadShotFonts();
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    phone(tester, size: const Size(1440, 900), ratio: 1);
    final dir = Directory.systemTemp.createTempSync('web-loc-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final location = LocationService(source: FakeSource()..state = LocationPermissionState.deniedForever, settingsDirOverride: dir);
    await tester.runAsync(location.init);
    addTearDown(location.dispose);
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..active = ModelEntry(path: '${dir.path}/m.gguf', size: 1);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..setBackend(ScriptedBackend([(_) => say('I have nothing downloaded for your current location.')]));
    addTearDown(() {
      chat.dispose();
      app.dispose();
    });
    await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat, location: location), theme: CacheThemeId.dark, insets: EdgeInsets.zero, desktop: true));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Ask anything'), 'what is near me');
    await tester.tap(find.byTooltip('Send'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, 'web_location', Platform.environment['SHOT_NAME'] ?? 'after');
  });

  testWidgets('Ask + sheet, location blocked in the browser', (tester) async {
    await loadShotFonts();
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    phone(tester, size: const Size(1440, 900), ratio: 1);
    final dir = Directory.systemTemp.createTempSync('web-loc-shot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final location = LocationService(source: FakeSource()..state = LocationPermissionState.deniedForever, settingsDirOverride: dir);
    await tester.runAsync(location.init);
    addTearDown(location.dispose);
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..active = ModelEntry(path: '${dir.path}/m.gguf', size: 1);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
    addTearDown(() {
      chat.dispose();
      app.dispose();
    });
    await tester.pumpWidget(shotApp(AskScreen(app: app, chat: chat, location: location), theme: CacheThemeId.dark, insets: EdgeInsets.zero, desktop: true));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-plus')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await snap(tester, 'web_location', 'sheet-${Platform.environment['SHOT_NAME'] ?? 'after'}');
  });
}

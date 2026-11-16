// Cache on Linux (browser), Ask: when the browser blocks the location, Ask shows the same "Allow location in your browser" dialog
// the map shows. A phone is untouched.
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

import 'chat_fakes.dart';
import 'location_service_test.dart' show FakeSource;
import 'support/act_core_stand_in.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dialog = find.byKey(const ValueKey('how-to-allow'));
  final box = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Ask anything');

  Future<(LocationService, ChatController)> show(WidgetTester tester, {required bool web, LocationPermissionState state = LocationPermissionState.deniedForever}) async {
    debugLinuxUi = web;
    addTearDown(() => debugLinuxUi = null);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('ask-web-loc-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = FakeSource()..state = state;
    final location = LocationService(source: source, settingsDirOverride: dir);
    await tester.runAsync(location.init);
    addTearDown(location.dispose);
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..active = ModelEntry(path: '${dir.path}/m.gguf', size: 1);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..setBackend(ScriptedBackend([(_) => say('Ok.')]));
    addTearDown(() {
      chat.dispose();
      app.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: AskScreen(app: app, chat: chat, location: location)));
    await tester.pump();
    return (location, chat);
  }

  testWidgets('web, blocked: turning on "Use my location" in the + sheet shows the allow-location dialog', (tester) async {
    await show(tester, web: true);
    await tester.tap(find.byKey(const ValueKey('ask-plus')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('use-my-location')));
    expect(sw.onChanged, isNotNull, reason: 'the switch can be turned on so the way out is shown');
    sw.onChanged!(true);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(find.text('Allow location in your browser'), findsOneWidget);
  });

  testWidgets('web, blocked: sending a question with location on shows the allow-location dialog, and the question still goes', (tester) async {
    final (location, chat) = await show(tester, web: true);
    expect(location.enabled, isTrue);
    await tester.enterText(box, 'what is near me');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(chat.messages.where((m) => m.isUser), isNotEmpty);
  });

  testWidgets('web, allowed: no dialog on send', (tester) async {
    await show(tester, web: true, state: LocationPermissionState.granted);
    await tester.enterText(box, 'what is near me');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  });

  testWidgets('phone, blocked: no browser dialog on send, and the switch stays off and disabled', (tester) async {
    await show(tester, web: false);
    await tester.enterText(box, 'what is near me');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    await tester.tap(find.byKey(const ValueKey('ask-plus')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('use-my-location'))).onChanged, isNull);
  });
}

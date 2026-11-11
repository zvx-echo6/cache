import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';

void main() {
  late Directory dir;
  late AppState app;
  late ChatController chat;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gate-card-test');
    File('${dir.path}/Gemma 4 E2B.gguf').writeAsBytesSync(List.filled(16, 0));
    app = AppState(
      settingsDirOverride: dir,
      modelsDirOverride: dir,
      memory: () async => const MemoryReading(avail: 900 << 20, total: 8 << 30, threshold: 200 << 20),
    );
    app.models = [ModelEntry(path: '${dir.path}/Gemma 4 E2B.gguf', size: 16)];
    app.started = true;
    chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
  });
  tearDown(() {
    chat.dispose();
    app.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: chat)));
    await tester.pump();
  }

  Color lineColor(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('ask-fix-line'))).style!.color!;
  Color emergency(WidgetTester tester) => tester.element(find.byKey(const ValueKey('ask-fix'))).t.emergency;

  testWidgets('held for memory: the calm card, with its texts and no emergency color', (tester) async {
    app.resting = app.models.first;
    await app.wake();
    expect(app.heldForMemory, isTrue);
    await show(tester);
    expect(find.text('Gemma 4 E2B is waiting for free memory.'), findsOneWidget);
    expect(find.text('Other apps are using it right now. Loading anyway may close some of them.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Load anyway'), findsOneWidget);
    expect(find.text('No model is loaded.'), findsNothing);
    final em = emergency(tester);
    expect(lineColor(tester), isNot(em));
    final box = tester.widget<Container>(find.byKey(const ValueKey('ask-fix'))).decoration as BoxDecoration;
    expect((box.border as Border).top.color, isNot(em.withValues(alpha: 0.6)));
  });

  testWidgets('not held and nothing chosen: the card is as it was (red line, Load <name>)', (tester) async {
    await show(tester);
    expect(find.text('No model is loaded.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Load Gemma 4 E2B'), findsOneWidget);
    expect(lineColor(tester), emergency(tester));
  });

  testWidgets('resting but not held (let go in the background): the card is as it was', (tester) async {
    app.resting = app.models.first;
    await show(tester);
    expect(find.text('No model is loaded.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Load Gemma 4 E2B'), findsOneWidget);
    expect(lineColor(tester), emergency(tester));
  });

  for (final (f, line, button) in [
    (LoadFailure.tooBig, 'Gemma 4 E2B did not load. It is too big for this device.', 'Choose a smaller model'),
    (LoadFailure.damaged, 'Gemma 4 E2B did not load. The file may be damaged.', 'Delete and download again'),
    (LoadFailure.other, 'Gemma 4 E2B did not load.', 'Choose a model'),
  ]) {
    testWidgets('failed load ${f.name}: unchanged, even if the gate had held it', (tester) async {
      app.resting = app.models.first;
      await app.wake();
      app.resting = null;
      app.failed = app.models.first;
      app.failure = f;
      await show(tester);
      expect(find.text(line), findsOneWidget);
      expect(find.widgetWithText(FilledButton, button), findsOneWidget);
      expect(lineColor(tester), emergency(tester));
    });
  }
}

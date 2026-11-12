import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';

class _NoDownloads extends ModelDownloads {
  _NoDownloads({required super.app});
}

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

  /// A model with a label in its display name, as a load leaves it in the settings: the start gate then holds it back.
  Future<void> startWithNamedModel(WidgetTester tester) async {
    final f = File('${dir.path}/Gemma-4-E2B-it-Q4_K_M.gguf')..writeAsBytesSync(List.filled(16, 0));
    final key = '${f.uri.pathSegments.last}|16';
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({
      'lastModel': f.uri.pathSegments.last,
      'names': {key: 'Gemma 4 E2B · Q4_K_M'},
      'plainNames': {key: 'Gemma 4 E2B'},
    }));
    await tester.runAsync(app.init);
  }

  testWidgets('held for memory: the calm card, with its texts and no emergency color', (tester) async {
    await startWithNamedModel(tester);
    expect(app.heldForMemory, isTrue);
    expect(app.displayName(app.resting!), 'Gemma 4 E2B · Q4_K_M');
    await show(tester);
    expect(find.text('Gemma 4 E2B is waiting for free memory.'), findsOneWidget, reason: 'the name without the label');
    expect(find.textContaining('Q4_K_M'), findsNothing);
    expect(find.text('Other apps are using it right now. Loading anyway may close some of them.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Load anyway'), findsOneWidget);
    expect(find.text('No model is loaded.'), findsNothing);
    final em = emergency(tester);
    expect(lineColor(tester), isNot(em));
    final box = tester.widget<Container>(find.byKey(const ValueKey('ask-fix'))).decoration as BoxDecoration;
    expect((box.border as Border).top.color, isNot(em.withValues(alpha: 0.6)));
  });

  testWidgets('the model chooser still shows the label', (tester) async {
    await startWithNamedModel(tester);
    ModelDownloads.shared = _NoDownloads(app: app);
    addTearDown(() => ModelDownloads.shared = null);
    final recs = RecommendedModels(builtIn: () async => jsonEncode({'format': 1, 'models': []}), fetch: () async => throw const SocketException('offline'));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: ModelsScreen(app: app, recommended: recs, memory: 8 << 30)));
    await tester.pumpAndSettle();
    expect(find.text('Gemma 4 E2B · Q4_K_M'), findsWidgets);
  });

  testWidgets('with no plain name known, the card uses the display name as before', (tester) async {
    app.resting = app.models.first;
    await app.wake();
    await show(tester);
    expect(find.text('Gemma 4 E2B is waiting for free memory.'), findsOneWidget, reason: 'the file-derived name has no label either');
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

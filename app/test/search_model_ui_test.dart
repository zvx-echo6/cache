import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/search_model.dart';
import 'package:cache/screens/model_search_screen.dart';
import 'package:cache/screens/search_model_line.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The screens of the search model. Kept apart from search_model_test.dart, whose downloads need a real HTTP client (a widget
// test answers every request with 400).
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('search-model-ui'));
  tearDown(() => dir.deleteSync(recursive: true));

  Widget wrap(Widget w) => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: Scaffold(body: w));

  const searchFile = HfFile(repo: 'acme/bge-GGUF', path: 'bge-m3-Q8_0.gguf', size: 10, revision: 'abc123');
  const chatFile = HfFile(repo: 'acme/chat-GGUF', path: 'chat-Q4.gguf', size: 10);

  testWidgets('the bar shows the search model waiting under the chat model, and a stopped one with Try again', (tester) async {
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final d = ModelDownloads(app: app, searchModel: searchFile);
    d.queue.add(searchFile);
    d.current = chatFile;
    d.total = 100;
    await tester.pumpWidget(wrap(ModelDownloadBar(downloads: d)));
    expect(find.textContaining('Downloading chat-Q4.gguf'), findsOneWidget);
    expect(find.text('Next: Search model, 635 MB'), findsOneWidget);
    d.current = null;
    d.searchModelError = 'the connection dropped';
    d.cancel(); // tells the bar
    await tester.pump();
    expect(find.text('Next: Search model, 635 MB'), findsNothing);
    expect(find.text('Search model: download stopped (the connection dropped)'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-model-retry')), findsOneWidget);
  });

  testWidgets('the line says meaning search needs the search model, with Get it', (tester) async {
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final sm = SearchModel(app: app, modelsDir: () async => dir);
    addTearDown(sm.dispose);
    await tester.pumpWidget(wrap(SearchModelLine(searchModel: sm)));
    expect(find.text('Meaning search needs the search model.'), findsOneWidget);
    expect(find.text('Get it'), findsOneWidget);
  });

  testWidgets('the line names another model a library needs, with no button', (tester) async {
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final sm = SearchModel(app: app, modelsDir: () async => dir);
    addTearDown(sm.dispose);
    await tester.pumpWidget(wrap(SearchModelLine(searchModel: sm, model: 'other.gguf')));
    expect(find.text('Meaning search needs the model other.gguf.'), findsOneWidget);
    expect(find.text('Get it'), findsNothing);
  });

  testWidgets('the one-time question shows once', (tester) async {
    // Not started from disk, so nothing is written: the flag is what is checked.
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)
      ..started = true
      ..models = [ModelEntry(path: '${dir.path}/chat-Q4.gguf', size: 2)];
    final sm = SearchModel(app: app, modelsDir: () async => dir);
    addTearDown(sm.dispose);
    await tester.pumpWidget(wrap(const SizedBox()));
    final ctx = tester.element(find.byType(SizedBox));
    final shown = offerSearchModelOnce(ctx, sm);
    await tester.pumpAndSettle();
    expect(find.text('Get the search model?'), findsOneWidget);
    expect(find.text('Meaning search in your libraries, places and the assistant needs it. 635 MB.'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await shown, isTrue);
    expect(app.searchModelOffered, isTrue);
    expect(await offerSearchModelOnce(ctx, sm), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Get the search model?'), findsNothing);
  });
}

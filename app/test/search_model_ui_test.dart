import 'dart:async';
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
    expect(find.text('Next: Search model, 605 MB'), findsOneWidget);
    d.current = null;
    d.searchModelError = 'the connection dropped';
    d.cancel(); // tells the bar
    await tester.pump();
    expect(find.text('Next: Search model, 605 MB'), findsNothing);
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

  testWidgets('the first chat model brings the search model along: one more line in the same download pop-up', (tester) async {
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir)..modelsDir = dir;
    final d = ModelDownloads(app: app, searchModel: kSearchModel.file);
    addTearDown(d.dispose);
    await tester.pumpWidget(wrap(const SizedBox()));
    final ctx = tester.element(find.byType(SizedBox));
    unawaited(downloadModel(ctx, d, const HfFile(repo: 'acme/Chat-GGUF', path: 'chat-Q4_K_M.gguf', size: 3 << 30)));
    await tester.pumpAndSettle();
    expect(find.text('Download chat-Q4_K_M.gguf?'), findsOneWidget);
    expect(find.text('Search model (once, for searching by meaning)'), findsOneWidget);
    expect(find.text('605 MB'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Once it is on the phone, a chat model comes alone.
    app.searchModel = ModelEntry(path: '${dir.path}/bge-m3-Q8_0.gguf', size: 2);
    unawaited(downloadModel(ctx, d, const HfFile(repo: 'acme/Chat-GGUF', path: 'chat-Q4_K_M.gguf', size: 3 << 30)));
    await tester.pumpAndSettle();
    expect(find.text('Search model (once, for searching by meaning)'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}

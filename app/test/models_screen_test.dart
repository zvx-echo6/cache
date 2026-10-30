import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/keyboard.dart';
import 'package:cache/models/device_memory.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what would be downloaded instead of downloading it.
class _RecordingDownloads extends ModelDownloads {
  _RecordingDownloads({required super.app});

  final started = <HfFile>[];

  @override
  Future<void> start(HfFile f, {bool anyway = false}) async => started.add(f);
}

const _gb = 1 << 30;

String _list(List<Map<String, Object?>> models, {int format = 1}) => jsonEncode({'format': format, 'models': models});

Map<String, Object?> _entry(String name, String file, int size, {String kind = 'works_not_tuned', String? sha}) => {
  'name': name,
  'repo': 'acme/$name-GGUF',
  'file': file,
  'size': size,
  'sha256': sha,
  'kind': kind,
  'note': 'A note about $name.',
};

void main() {
  late Directory dir;
  late AppState app;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('models-screen');
    app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
    app.modelsDir = Directory('${dir.path}/models')..createSync();
  });
  tearDown(() {
    ModelDownloads.shared = null;
    dir.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1290, 2796);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: home));
    await tester.pump();
  }

  group('recommendations file', () {
    test('the built-in copy is docs/models-recommended.json, and lists the three tool-capable models', () {
      final docs = File('../docs/models-recommended.json').readAsStringSync();
      expect(File('assets/models/recommended.json').readAsStringSync(), docs,
          reason: 'copy docs/models-recommended.json to app/assets/models/recommended.json when it changes');
      final r = parseRecommendations(docs)!;
      expect(r.map((m) => '${m.repo}/${m.file}'), [
        'unsloth/gemma-4-E2B-it-GGUF/gemma-4-E2B-it-Q4_K_M.gguf',
        'unsloth/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q4_K_M.gguf',
        'unsloth/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf',
      ]);
      for (final m in r) {
        expect(m.kind, RecommendationKind.worksNotTuned);
        expect(m.sha256, hasLength(64));
        expect(m.size, greaterThan(_gb));
        expect(m.note, isNotEmpty);
      }
    });

    test('another format is not used; entries this app cannot use are left out', () {
      expect(parseRecommendations(_list([_entry('a', 'a.gguf', 10)], format: 2)), isNull);
      expect(parseRecommendations('not json'), isNull);
      final r = parseRecommendations(_list([
        _entry('ok', 'ok.gguf', 10, sha: 'f' * 64),
        _entry('kind', 'k.gguf', 10, kind: 'cache_pick'),
        _entry('nosize', 'n.gguf', 0),
        _entry('notgguf', 'n.bin', 10),
        _entry('badsha', 'b.gguf', 10, sha: 'xyz'),
      ]))!;
      expect(r.map((m) => m.name), ['ok', 'badsha']);
      expect(r.first.sha256, 'f' * 64);
      expect(r.last.sha256, isNull);
      expect(r.first.hfFile.fileName, 'ok.gguf');
    });

    test('the built-in list shows first and the published one replaces it; a failed fetch keeps the built-in one', () async {
      final ok = RecommendedModels(
        builtIn: () async => _list([_entry('built', 'b.gguf', 10)]),
        fetch: () async => _list([_entry('net', 'n.gguf', 10, kind: 'tuned_for_cache')]),
      );
      await ok.load();
      expect(ok.models.map((m) => m.name), ['net']);
      expect(ok.fromNetwork, isTrue);
      expect(ok.noneTuned, isFalse);
      final offline = RecommendedModels(
        builtIn: () async => _list([_entry('built', 'b.gguf', 10)]),
        fetch: () async => throw const SocketException('offline'),
      );
      await offline.load();
      expect(offline.models.map((m) => m.name), ['built']);
      expect(offline.fromNetwork, isFalse);
      expect(offline.noneTuned, isTrue);
      final bad = RecommendedModels(builtIn: () async => _list([_entry('built', 'b.gguf', 10)]), fetch: () async => '{"format": 9}');
      await bad.load();
      expect(bad.models.map((m) => m.name), ['built']);
    });
  });

  testWidgets('Models leads with Recommended: size, fit, label, then Search Hugging Face and Choose a file; a tap downloads',
      (tester) async {
    final d = _RecordingDownloads(app: app);
    ModelDownloads.shared = d;
    final recs = RecommendedModels(
      builtIn: () async => _list([_entry('Small', 'small-Q4_K_M.gguf', 3 * _gb), _entry('Big', 'big-Q4_K_M.gguf', 5 * _gb)]),
      fetch: () async => throw const SocketException('offline'),
    );
    await show(tester, ModelsScreen(app: app, recommended: recs, memory: 8 * _gb));
    await tester.pumpAndSettle();
    expect(find.text('RECOMMENDED'), findsOneWidget);
    expect(find.text('The model is the AI that answers your questions. It runs on this phone, so it works with no signal.'), findsOneWidget);
    expect(find.text('Small'), findsOneWidget);
    expect(find.text('A note about Small.'), findsOneWidget);
    expect(find.text('3.0 GB · Fits this phone', findRichText: true), findsOneWidget);
    expect(find.text('5.0 GB · May be tight on this phone', findRichText: true), findsOneWidget);
    expect(find.text('Works with Cache, not tuned'), findsNWidgets(2));
    expect(find.text('Search Hugging Face'), findsOneWidget);
    expect(find.text('Choose a file'), findsOneWidget);
    expect(tester.getTopLeft(find.text('RECOMMENDED')).dy, lessThan(tester.getTopLeft(find.text('Search Hugging Face')).dy));

    // A tap opens the download pop-up; Download starts it.
    await tester.tap(find.text('Small'));
    await tester.pumpAndSettle();
    expect(find.text('Download small-Q4_K_M.gguf?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await tester.pumpAndSettle();
    expect(d.started.map((f) => '${f.repo}/${f.path}'), ['acme/Small-GGUF/small-Q4_K_M.gguf']);
    await tester.tap(find.byKey(const ValueKey('download-recommended-big-Q4_K_M.gguf')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-download')));
    await tester.pumpAndSettle();
    expect(d.started.last.fileName, 'big-Q4_K_M.gguf');
    expect(app.active, isNull, reason: 'no model is ever chosen for the user');
  });

  testWidgets('a model tuned for Cache says so', (tester) async {
    ModelDownloads.shared = _RecordingDownloads(app: app);
    final recs = RecommendedModels(
      builtIn: () async => _list([_entry('Tuned', 't.gguf', _gb, kind: 'tuned_for_cache')]),
      fetch: () async => throw const SocketException('offline'),
    );
    await show(tester, ModelsScreen(app: app, recommended: recs, memory: 8 * _gb));
    await tester.pumpAndSettle();
    expect(find.text('Tuned for Cache'), findsOneWidget);
  });

  testWidgets('the active model can be unloaded; Ask then shows the no-model state with "Choose a model"', (tester) async {
    File('${app.modelsDir!.path}/gemma-4-E2B-it-Q4_K_M.gguf').writeAsBytesSync(List.filled(2048, 1));
    await tester.runAsync(app.init);
    app.active = app.models.single;
    final generation = app.modelGeneration;
    await show(tester, ModelsScreen(app: app, memory: 8 * _gb));
    expect(find.text('ON THIS PHONE'), findsOneWidget);
    expect(find.textContaining('Active'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('unload-model')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(app.active, isNull);
    expect(app.modelGeneration, generation + 1);
    expect(find.byKey(const ValueKey('unload-model')), findsNothing);
    expect(find.textContaining('Tap to use'), findsOneWidget);
    final saved = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map;
    expect(saved['lastModel'], isNull, reason: 'the next start does not load it again');

    await show(tester, AskScreen(app: app, chat: ChatController(tools: const [])));
    expect(find.text('No model'), findsWidgets);
    expect(find.text('Choose a model at the top to start.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Choose a model'), findsOneWidget);
  });

  testWidgets('Ask: the model name has its arrow and opens the model, the memory it takes, Unload and Manage models', (tester) async {
    File('${app.modelsDir!.path}/gemma-4-E2B-it-Q4_K_M.gguf').writeAsBytesSync(List.filled(2048, 1));
    await tester.runAsync(app.init);
    app.active = app.models.single;
    await show(tester, AskScreen(app: app, chat: ChatController(tools: const [])));
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-name')));
    await tester.pumpAndSettle();
    expect(find.textContaining('loaded · about 2 KB of memory'), findsOneWidget);
    expect(find.text('Unload: free the memory'), findsOneWidget);
    expect(find.text('Manage models'), findsOneWidget);
    await tester.tap(find.text('Manage models'));
    await tester.pumpAndSettle();
    expect(find.text('Models'), findsOneWidget);
  });

  testWidgets('empty Ask: "Get a model" when none is downloaded, and it opens Models', (tester) async {
    await show(tester, AskScreen(app: app, chat: ChatController(tools: const [])));
    expect(find.widgetWithText(FilledButton, 'Get a model'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('ask-open-models')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Choose a file'), findsOneWidget);
  });

  testWidgets('a tap outside a text field, or a scroll, closes the keyboard; Done on a single-line field does too', (tester) async {
    final focus = FocusNode();
    final other = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(MaterialApp(
      actions: keyboardActions,
      scrollBehavior: const CacheScrollBehavior(),
      home: Scaffold(
        body: Column(
          children: [
            TextField(key: const ValueKey('field'), focusNode: focus, maxLines: 4, minLines: 1),
            TextField(key: const ValueKey('single'), focusNode: other),
            Expanded(child: ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('row $i'))])),
          ],
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.tap(find.text('row 3'));
    await tester.pump();
    expect(focus.hasFocus, isFalse, reason: 'a tap outside');

    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.drag(find.text('row 5'), const Offset(0, -300));
    await tester.pump();
    expect(focus.hasFocus, isFalse, reason: 'a scroll');

    await tester.tap(find.byKey(const ValueKey('single')));
    await tester.pump();
    expect(other.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(other.hasFocus, isFalse, reason: 'Done');
  });

  test('phone memory: read on Android, Linux, iPhone and Mac; null where there is no sysctl', () async {
    final m = await totalMemoryBytes();
    if (Platform.isAndroid || Platform.isLinux || Platform.isIOS || Platform.isMacOS) {
      expect(m, greaterThan(0));
    } else {
      expect(m, isNull);
    }
    if (Platform.isMacOS || Platform.isIOS) {
      expect(sysctlMemsize(), greaterThan(_gb));
    } else if (Platform.isWindows) {
      expect(sysctlMemsize(), isNull);
    }
  });
}

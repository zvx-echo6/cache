// Two recommended files read the same ("Gemma 4 E2B · Q4_K_M") and could not be told apart. A recommended model now shows its
// name from the recommended list ("Gemma 4 E2B · tuned for Cache") with its size and quantisation under it ("3.2 GB · Q4_K_M");
// any other model keeps the name from its GGUF's general.name, as before. Checked at every place a model's name shows.

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/screens/settings/assistant_page.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/act_core_stand_in.dart';
import 'support/gguf_bytes.dart';
import 'support/settings_rig.dart';

const _stockFile = 'e2b-stock-cache-1.0-Q4_K_M.gguf';
const _trevorFile = 'e2b-trevorjs-cache-1.0-Q4_K_M.gguf';
const _q6File = 'e2b-stock-cache-1.0-Q6_K.gguf';
const _smolFile = 'SmolLM2-135M-Instruct-Q4_0.gguf';

// The sizes the list gives these files.
const _stockSize = 3427879936;
const _trevorSize = 3427873312;
const _q6Size = 3845346304;

const _gemma = ModelInfo(description: 'gemma4 E2B Q4_K - Medium', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);
const _smol = ModelInfo(description: 'llama 256M Q4_0', nCtx: 8192, chatFormat: 'x', supportsTools: true);

class _Session implements LlamaSession {
  _Session(this.info);
  ModelInfo info;
  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async => info;
  @override
  Future<void> unload() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

/// The real list (app/assets/models/recommended.json), read as the app's built-in copy.
Future<RecommendedModels> _realList() async {
  final list = RecommendedModels(
    builtIn: () async => File('assets/models/recommended.json').readAsStringSync(),
    fetch: () async => throw const SocketException('offline'),
  );
  await list.load();
  return list;
}

/// Wires an app to [list] as main.dart does.
void _wire(AppState app, RecommendedModels list) {
  app.isRecommended = (e) => list.isRecommendedFile(e.fileName);
  app.recommendedName = (e) => list.nameOfFile(e.fileName);
  app.recommendedReady = list.ready;
}

ModelEntry _entry(Directory dir, String file, int size) => ModelEntry(path: '${dir.path}/$file', size: size);

void main() {
  late Directory dir;
  late AppState app;
  late RecommendedModels list;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('twin-names');
    app = AppState(
      settingsDirOverride: dir,
      modelsDirOverride: Directory('${dir.path}/models'),
      memory: () async => const MemoryReading(avail: 8 << 30, total: 16 << 30, threshold: 200 << 20),
      session: _Session(_gemma),
    );
    app.modelsDir = Directory('${dir.path}/models')..createSync();
    list = await _realList();
    _wire(app, list);
  });
  tearDown(() {
    ModelDownloads.shared = null;
    dir.deleteSync(recursive: true);
  });

  group('the names', () {
    test('the two recommended Q4 files, and the Q6, read differently: the list names, with size and quant under', () {
      final stock = _entry(app.modelsDir!, _stockFile, _stockSize);
      final trevor = _entry(app.modelsDir!, _trevorFile, _trevorSize);
      final q6 = _entry(app.modelsDir!, _q6File, _q6Size);
      expect(app.displayName(stock), 'Gemma 4 E2B · tuned for Cache');
      expect(app.displayName(trevor), 'Gemma 4 E2B uncensored · tuned for Cache');
      expect(app.displayName(q6), 'Gemma 4 E2B Q6 · tuned for Cache');
      expect(app.sizeLine(stock), '3.2 GB · Q4_K_M');
      expect(app.sizeLine(trevor), '3.2 GB · Q4_K_M');
      expect(app.sizeLine(q6), '3.6 GB · Q6_K');
    });

    test('after a load the same names stand (llama.cpp\'s description does not decide)', () async {
      final f = File('${app.modelsDir!.path}/$_stockFile')..writeAsBytesSync(ggufBytes([kvString('general.name', 'Cache Merge E2B Stock')]));
      final e = ModelEntry(path: f.path, size: _stockSize);
      app.models = [e];
      await app.activate(e);
      expect(app.displayName(e), 'Gemma 4 E2B · tuned for Cache');
      expect(app.plainName(e), 'Gemma 4 E2B · tuned for Cache');
      expect(app.sizeLine(e), '3.2 GB · Q4_K_M');
    });

    test('a name stored by an earlier build is not shown for a recommended file', () async {
      final e = _entry(app.modelsDir!, _stockFile, _stockSize);
      expect(app.displayName(e), isNot('Gemma 4 E2B · Q4_K_M'));
      expect(app.displayName(e), 'Gemma 4 E2B · tuned for Cache');
    });

    test('a model that is not recommended keeps general.name and the quant, with the size alone under', () async {
      (app.session as _Session).info = _smol;
      final f = File('${app.modelsDir!.path}/$_smolFile')..writeAsBytesSync(ggufBytes([kvString('general.name', 'SmolLM2 135M Instruct')]));
      final e = ModelEntry(path: f.path, size: 90 << 20);
      app.models = [e];
      await app.activate(e);
      expect(app.displayName(e), 'SmolLM2 135M Instruct · Q4_0');
      expect(app.sizeLine(e), '90 MB');
    });
  });

  group('every place a model\'s name shows', () {
    Future<void> show(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1290, 2796);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: home));
      await tester.pump();
    }

    Widget ask() => AskScreen(app: app, chat: ChatController(actCore: const ActCoreStandIn(), tools: const []));

    testWidgets('Ask header and its menu: the list name', (tester) async {
      final e = _entry(app.modelsDir!, _trevorFile, _trevorSize);
      app.models = [e];
      app.active = e;
      await show(tester, ask());
      expect(find.descendant(of: find.byKey(const ValueKey('model-name')), matching: find.text('Gemma 4 E2B uncensored · tuned for Cache')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-name')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Gemma 4 E2B uncensored · tuned for Cache · loaded'), findsOneWidget);
    });

    testWidgets('Ask > Switch model: the two Q4 files are told apart, with the size and quant under', (tester) async {
      final q6 = _entry(app.modelsDir!, _q6File, _q6Size);
      final stock = _entry(app.modelsDir!, _stockFile, _stockSize);
      final trevor = _entry(app.modelsDir!, _trevorFile, _trevorSize);
      app.models = [q6, stock, trevor];
      await show(tester, ask());
      await tester.tap(find.byKey(const ValueKey('model-name')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-menu-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Gemma 4 E2B · tuned for Cache'), findsOneWidget);
      expect(find.text('Gemma 4 E2B uncensored · tuned for Cache'), findsOneWidget);
      expect(find.text('Gemma 4 E2B Q6 · tuned for Cache'), findsOneWidget);
      expect(find.text('3.2 GB · Q4_K_M'), findsNWidgets(2));
      expect(find.text('3.6 GB · Q6_K'), findsOneWidget);
      expect(find.text('Gemma 4 E2B · Q4_K_M'), findsNothing);
    });

    testWidgets('Ask > Switch model: a model that is not recommended shows as before', (tester) async {
      final stock = _entry(app.modelsDir!, _stockFile, _stockSize);
      final smol = ModelEntry(path: '${app.modelsDir!.path}/$_smolFile', size: 90 << 20);
      File(smol.path).writeAsBytesSync(ggufBytes([kvString('general.name', 'SmolLM2 135M Instruct')]));
      (app.session as _Session).info = _smol;
      await tester.runAsync(() => app.activate(smol));
      app.models = [stock, smol];
      app.active = stock;
      await show(tester, ask());
      await tester.tap(find.byKey(const ValueKey('model-name')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-menu-switch')));
      await tester.pumpAndSettle();
      expect(find.text('SmolLM2 135M Instruct · Q4_0'), findsOneWidget);
      expect(find.text('90 MB'), findsOneWidget);
    });

    testWidgets('Models (on this device): the list name, with the size and quant', (tester) async {
      final stock = _entry(app.modelsDir!, _stockFile, _stockSize);
      final trevor = _entry(app.modelsDir!, _trevorFile, _trevorSize);
      app.models = [stock, trevor];
      await show(tester, ModelsScreen(app: app, recommended: list, memory: 16 << 30));
      expect(find.text('Gemma 4 E2B · tuned for Cache'), findsWidgets);
      expect(find.text('Gemma 4 E2B uncensored · tuned for Cache'), findsWidgets);
      expect(find.textContaining('3.2 GB · Q4_K_M · Tap to use'), findsNWidgets(2));
    });

    testWidgets('Settings > Cache model and web search: the list name as the row, size and quant in its status', (tester) async {
      final r = await SettingsRig.create(tester);
      _wire(r.app, list);
      final e = _entry(r.modelsDir, _stockFile, _stockSize);
      r.app.models = [e];
      r.app.active = e;
      await r.show(tester, AssistantPage(deps: r.deps));
      await tester.pump();
      expect(find.text('Gemma 4 E2B · tuned for Cache'), findsOneWidget);
      expect(find.textContaining('3.2 GB · Q4_K_M'), findsOneWidget);
      await r.dispose(tester);
    });

    testWidgets('Settings list: the model row names the list name', (tester) async {
      final r = await SettingsRig.create(tester);
      _wire(r.app, list);
      final e = _entry(r.modelsDir, _trevorFile, _trevorSize);
      r.app.models = [e];
      r.app.resting = e;
      await r.show(tester, SettingsScreen(deps: r.deps));
      await tester.pump();
      expect(find.text('Gemma 4 E2B uncensored · tuned for Cache · web search off'), findsOneWidget);
      await r.dispose(tester);
    });
  });
}

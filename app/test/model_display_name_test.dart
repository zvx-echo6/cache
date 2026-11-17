// What "On this device" calls a model: a recommended model keeps its name from llama.cpp's description exactly as before; any
// other model shows the GGUF's own general.name with the same quantisation label; no general.name leaves today's name.

import 'dart:convert';
import 'dart:io';

import 'package:cache/models/recommendations.dart';

import 'package:cache/app_state.dart';
import 'package:cache/chat/model_name.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gguf_bytes.dart';

// What llama.cpp said for the SmolLM2 135M Q4_0 file: its own size guess, wrong.
const _smol = ModelInfo(description: 'llama 256M Q4_0', nCtx: 8192, chatFormat: 'x', supportsTools: true);
const _gemma = ModelInfo(description: 'gemma4 E2B Q4_K - Medium', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);

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

void main() {
  group('modelNameParts', () {
    test('another model: general.name and the same label', () {
      final p = modelNameParts('llama 256M Q4_0', fileName: 'SmolLM2-135M-Instruct-Q4_0.gguf', generalName: 'SmolLM2 135M Instruct');
      expect(p, (name: 'SmolLM2 135M Instruct', label: 'Q4_0'));
    });
    test('no general.name, or an empty one: today\'s name', () {
      for (final g in [null, '', '   ']) {
        expect(modelNameParts('llama 256M Q4_0', generalName: g), (name: 'Llama 256M', label: 'Q4_0'));
      }
    });
    test('a recommended model ignores general.name', () {
      expect(modelNameParts('gemma4 E2B Q4_K - Medium', generalName: 'gemma-4-E2B-it', recommended: true), (name: 'Gemma 4 E2B', label: 'Q4_K_M'));
    });
    test('a name with no label stays a name; an empty description stays null', () {
      expect(modelNameParts('mystery', generalName: 'My Model'), (name: 'My Model', label: null));
      expect(modelNameParts('', generalName: 'My Model'), isNull);
    });
    test('a long or untidy general.name is tidied', () {
      expect(modelNameParts('llama 1B Q8_0', generalName: '  A\n  B\t C  ')!.name, 'A B C');
      expect(modelNameParts('llama 1B Q8_0', generalName: 'x' * 500)!.name.length, lessThanOrEqualTo(120));
    });
  });

  group('what the model list shows after a load', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('display_name'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<AppState> loaded(String file, List<int> bytes, ModelInfo info, {bool recommended = false}) async {
      final f = File('${dir.path}/$file')..writeAsBytesSync(bytes);
      final app = AppState(
        settingsDirOverride: dir,
        modelsDirOverride: dir,
        memory: () async => const MemoryReading(avail: 8 << 30, total: 16 << 30, threshold: 200 << 20),
        session: _Session(info),
      );
      addTearDown(app.dispose);
      app.isRecommended = (_) => recommended;
      final e = ModelEntry(path: f.path, size: bytes.length);
      app.models = [e];
      await app.activate(e);
      return app;
    }

    test('SmolLM2 Q4_0 (not recommended) shows its general.name and the quant', () async {
      final bytes = ggufBytes([kvString('general.name', 'SmolLM2 135M Instruct')]);
      final app = await loaded('SmolLM2-135M-Instruct-Q4_0.gguf', bytes, _smol);
      expect(app.displayName(app.models.first), 'SmolLM2 135M Instruct · Q4_0');
      expect(app.plainName(app.models.first), 'SmolLM2 135M Instruct');
    });

    test('no general.name in the file: today\'s label', () async {
      final app = await loaded('SmolLM2-135M-Instruct-Q4_0.gguf', ggufBytes([kvString('general.architecture', 'llama')]), _smol);
      expect(app.displayName(app.models.first), 'Llama 256M · Q4_0');
    });

    test('a file that is not a GGUF: today\'s label', () async {
      final app = await loaded('x-Q4_0.gguf', List.filled(40, 7), _smol);
      expect(app.displayName(app.models.first), 'Llama 256M · Q4_0');
    });

    test('a recommended model keeps its name exactly', () async {
      final bytes = ggufBytes([kvString('general.name', 'Gemma-4-E2B-It')]);
      final app = await loaded('gemma-4-E2B-it-Q4_K_M.gguf', bytes, _gemma, recommended: true);
      expect(app.displayName(app.models.first), 'Gemma 4 E2B · Q4_K_M');
      expect(app.plainName(app.models.first), 'Gemma 4 E2B');
    });

    test('the server\'s answer (a browser has no file here) carries general_name', () async {
      const viaServer = ModelInfo(description: 'llama 256M Q4_0', nCtx: 8192, chatFormat: 'x', supportsTools: true, generalName: 'SmolLM2 135M Instruct');
      final app = await loaded('SmolLM2-135M-Instruct-Q4_0.gguf', List.filled(40, 7), viaServer);
      expect(app.displayName(app.models.first), 'SmolLM2 135M Instruct · Q4_0');
    });

    test('ModelInfo reads general_name from the server JSON', () {
      expect(ModelInfo.fromJson({'description': 'd', 'general_name': 'N'}).generalName, 'N');
      expect(ModelInfo.fromJson({'description': 'd'}).generalName, isNull);
    });
  });

  // The rework: the recommended list is read asynchronously, a file may differ in size from the list's, and an earlier build stored
  // the wrong name.
  group('a recommended file is recognised by its file name', () {
    const file = 'e2b-stock-cache-1.0-Q4_K_M.gguf';
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('display_name2'));
    tearDown(() => dir.deleteSync(recursive: true));

    // The real list (app/assets/models/recommended.json), as the app's built-in copy.
    RecommendedModels realList() => RecommendedModels(
          builtIn: () async => File('assets/models/recommended.json').readAsStringSync(),
          fetch: () async => throw const SocketException('offline'),
        );

    ModelEntry entryOf(List<int> bytes, {String name = file, int? size}) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return ModelEntry(path: f.path, size: size ?? bytes.length);
    }

    AppState appFor(RecommendedModels list, {bool wait = true}) {
      final app = AppState(
        settingsDirOverride: dir,
        modelsDirOverride: dir,
        memory: () async => const MemoryReading(avail: 8 << 30, total: 16 << 30, threshold: 200 << 20),
        session: _Session(_gemma),
      );
      addTearDown(app.dispose);
      app.isRecommended = (e) => list.isRecommendedFile(e.fileName);
      if (wait) app.recommendedReady = list.ready;
      return app;
    }

    final cacheMerge = ggufBytes([kvString('general.name', 'Cache Merge E2B Stock')]);

    test('the exact model, with its size and sha256 from the list, shows Gemma 4 E2B', () async {
      final list = realList();
      await list.load();
      final r = list.models.firstWhere((m) => m.file == file);
      expect(r.size, 3427879936);
      expect(r.sha256, 'bd342122ed2381d4b3d2aa87b0e4273cbfdf79058a72b126975baa0509c2ab2f');
      final app = appFor(list);
      final e = entryOf(cacheMerge, size: r.size);
      app.models = [e];
      await app.activate(e);
      expect(app.displayName(e), 'Gemma 4 E2B · Q4_K_M');
      expect(app.plainName(e), 'Gemma 4 E2B');
    });

    test('the list not read yet at activate: the load waits for it, and the name is still Gemma 4 E2B', () async {
      final list = realList();
      expect(list.models, isEmpty);
      final app = appFor(list);
      final e = entryOf(cacheMerge);
      app.models = [e];
      await app.activate(e);
      expect(app.displayName(e), 'Gemma 4 E2B · Q4_K_M');
    });

    test('the list unknown (never read): no general.name name is stored, today\'s name stays', () async {
      final list = realList();
      final app = appFor(list, wait: false);
      final e = entryOf(cacheMerge);
      app.models = [e];
      await app.activate(e);
      expect(list.models, isEmpty);
      expect(app.displayName(e), 'Gemma 4 E2B · Q4_K_M');
    });

    test('a different size on disk (an older download) is still the recommended model', () async {
      final list = realList();
      final app = appFor(list);
      final e = entryOf(cacheMerge, size: 3000000000);
      app.models = [e];
      await app.activate(e);
      expect(app.displayName(e), 'Gemma 4 E2B · Q4_K_M');
    });

    test('a file the list does not name still takes its general.name once the list is known', () async {
      final list = realList();
      final app = appFor(list);
      (app.session as _Session).info = _smol;
      final e = entryOf(ggufBytes([kvString('general.name', 'SmolLM2 135M Instruct')]), name: 'SmolLM2-135M-Instruct-Q4_0.gguf');
      app.models = [e];
      await app.activate(e);
      expect(app.displayName(e), 'SmolLM2 135M Instruct · Q4_0');
    });

    test('a wrong name stored by the earlier build is replaced on the next load', () async {
      final list = realList();
      final e = entryOf(cacheMerge);
      File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({
        'names': {e.key: 'Cache Merge E2B Stock · Q4_K_M'},
        'plainNames': {e.key: 'Cache Merge E2B Stock'},
      }));
      final app = appFor(list);
      await app.init();
      app.models = [e];
      expect(app.displayName(e), 'Cache Merge E2B Stock · Q4_K_M', reason: 'the stored name is read back');
      await app.activate(e);
      expect(app.displayName(e), 'Gemma 4 E2B · Q4_K_M');
      expect(app.plainName(e), 'Gemma 4 E2B');
    });
  });
}

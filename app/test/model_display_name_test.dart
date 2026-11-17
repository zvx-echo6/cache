// What "On this device" calls a model: a recommended model keeps its name from llama.cpp's description exactly as before; any
// other model shows the GGUF's own general.name with the same quantisation label; no general.name leaves today's name.

import 'dart:io';

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
}

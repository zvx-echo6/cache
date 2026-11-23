import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/server_models.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

const _info = ModelInfo(description: 'Gemma 4 E2B', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);

class _Session implements LlamaSession {
  final loads = <String>[];
  final adopted = <String>[];

  @override
  void adopt(String id) => adopted.add(id);

  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async {
    loads.add(path);
    return _info;
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

/// The server's model list, with the model another tab loaded (or none).
class _Server {
  String? loaded;
  int reads = 0;
  final posts = <String>[];

  Future<({int status, String body})> call(String method, String path, String? body) async {
    if (method == 'GET' && path.startsWith('/api/llm/models')) {
      reads++;
      return (
        status: 200,
        body: jsonEncode({
          'ok': true,
          'result': {
            'v': 1,
            'models': [
              for (final id in ['a.gguf', 'b.gguf']) {
                'id': id, 'size': 100, 'loaded': id == loaded,
                if (id == loaded) ...{'n_ctx': 4096, 'info': {'description': 'Gemma 4 E2B', 'n_ctx': 4096, 'chat_format': 'gemma', 'supports_tools': true}},
              },
            ],
          },
        }),
      );
    }
    if (method == 'POST') posts.add('$method $path');
    return (status: 404, body: '{}');
  }
}

void main() {
  late Directory dir;
  late _Server fake;
  late _Session session;
  late AppState app;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('server-model-loaded');
    fake = _Server();
    session = _Session();
    app = AppState(settingsDirOverride: dir, session: session, server: ServerModels(http: fake.call));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('the list keeps which model the server has loaded', () async {
    fake.loaded = 'b.gguf';
    final list = await ServerModels(http: fake.call).chatModels();
    expect(list.map((m) => (m.id, m.loaded)), [('a.gguf', false), ('b.gguf', true)]);
  });

  test('a refresh (a tab in front again, or Ask opened) shows the model another tab loaded, and then that it was unloaded', () async {
    await app.refreshModels();
    expect(app.active, isNull);

    fake.loaded = 'a.gguf';
    await app.syncServerModel();
    expect(app.active?.fileName, 'a.gguf');
    expect(app.activeInfo, isNotNull);
    expect(app.activeInfo?.nCtx, 4096, reason: 'the server\'s own numbers, not this tab\'s');
    expect(session.adopted, ['a.gguf'], reason: 'this tab\'s own session learns the model too');
    expect(session.loads, isEmpty, reason: 'adopting never loads');
    expect(fake.posts, isEmpty, reason: 'no POST /api/llm/load: another tab may be mid answer');

    await app.syncServerModel();
    expect(session.adopted, ['a.gguf'], reason: 'nothing changed');

    fake.loaded = 'b.gguf';
    await app.syncServerModel();
    expect(app.active?.fileName, 'b.gguf');

    fake.loaded = null;
    await app.syncServerModel();
    expect(app.active, isNull);
    expect(app.activeInfo, isNull);
  });

  test('opening Ask reads the server first', () async {
    await app.refreshModels();
    final before = fake.reads;
    fake.loaded = 'a.gguf';
    await app.wake();
    expect(fake.reads, before + 1);
    expect(app.active?.fileName, 'a.gguf');
  });
}

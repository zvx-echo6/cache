import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

const _info = ModelInfo(description: 'Gemma 4 E2B', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);

/// A session whose unload fails (a browser: the server refused or could not be reached).
class _FailingUnload implements LlamaSession {
  @override
  Future<void> unload() async => throw StateError('The server could not unload the model (HTTP 500)');

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  test('an unload the server did not do leaves the model active and says so plainly', () async {
    final dir = Directory.systemTemp.createTempSync('unload-failure');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/models').createSync();
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'), session: _FailingUnload());
    app.active = ModelEntry(path: 'chat.gguf', size: 3);
    app.activeInfo = _info;
    await app.unload();
    expect(app.active?.path, 'chat.gguf', reason: 'the server still has it loaded, so the page must not say otherwise');
    expect(app.activeInfo, same(_info));
    expect(app.loadError, 'Could not unload the model: The server could not unload the model (HTTP 500)');
  });
}

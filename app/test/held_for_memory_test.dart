import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/platform/memory.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('held-memory');
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/chat-Q6_K.gguf')
      ..createSync()
      ..writeAsBytesSync(List.filled(16, 0));
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'lastModel': 'chat-Q6_K.gguf'}));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AppState make(int availBytes) => AppState(
        settingsDirOverride: dir,
        modelsDirOverride: Directory('${dir.path}/models'),
        memory: () async => MemoryReading(avail: availBytes, total: 8 * _gb, threshold: 200 << 20),
      );

  test('the start gate holding the model back sets heldForMemory and the two numbers', () async {
    final app = make(900 << 20);
    await app.init();
    expect(app.heldForMemory, isTrue);
    expect(app.heldNeedMb, greaterThan(app.heldFreeMb!));
    expect(app.heldFreeMb, 700);
  });

  test('a gated wake sets it; a forced wake (a load begins) clears it', () async {
    final app = make(900 << 20);
    app.models = [ModelEntry(path: '${dir.path}/models/chat-Q6_K.gguf', size: 16)];
    app.resting = app.models.first;
    expect(app.heldForMemory, isFalse);
    await app.wake();
    expect(app.heldForMemory, isTrue);
    await app.wake(force: true);
    expect(app.heldForMemory, isFalse);
    expect(app.heldNeedMb, isNull);
  });

  test('with room it is never set', () async {
    final app = make(6 * _gb);
    await app.init();
    expect(app.heldForMemory, isFalse);
  });

  test('choosing another model clears it', () async {
    final app = make(900 << 20);
    await app.init();
    expect(app.heldForMemory, isTrue);
    File('${dir.path}/models/other.gguf').writeAsBytesSync(List.filled(16, 0));
    await app.refreshModels();
    await app.useModelFile('other.gguf');
    expect(app.heldForMemory, isFalse);
  });
}

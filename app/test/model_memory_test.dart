import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/platform/memory.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('model-memory');
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/chat-Q6_K.gguf')
      ..createSync()
      ..writeAsBytesSync(List.filled(16, 0));
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'lastModel': 'chat-Q6_K.gguf'}));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('at start the chosen model is not loaded when the memory free now is less than it needs; it rests, still chosen', () async {
    final app = AppState(
      settingsDirOverride: dir,
      modelsDirOverride: Directory('${dir.path}/models'),
      // less room than a model of any size needs (its working memory alone is a gigabyte)
      memory: () async => const MemoryReading(avail: 900 << 20, total: 8 * _gb, threshold: 200 << 20),
    );
    await app.init();
    expect(app.loading, isNull);
    expect(app.active, isNull);
    expect(app.resting?.fileName, 'chat-Q6_K.gguf');
    expect(app.failed, isNull, reason: 'it was not tried: no failure to show');
  });

  test('what a model needs: about two thirds of its file, plus a gigabyte to answer', () {
    expect(modelMemoryNeed(0), _gb);
    expect(modelMemoryNeed(3 * _gb) >> 20, closeTo(3 * 1024 * 0.65 + 1024, 1));
  });

  test('the model is let go when Android says memory runs low in front, or Cache went to the back with little free', () {
    const roomy = MemoryReading(avail: 3 * _gb, total: 8 * _gb, threshold: 200 << 20);
    const tight = MemoryReading(avail: 900 << 20, total: 8 * _gb, threshold: 200 << 20);
    expect(releaseModelOn(kTrimRunningLow, roomy), isTrue);
    expect(releaseModelOn(15, null), isTrue, reason: 'running critical');
    expect(releaseModelOn(kTrimUiHidden, roomy), isFalse, reason: 'to the back with room: kept, Ask answers at once on return');
    expect(releaseModelOn(kTrimUiHidden, tight), isTrue);
    expect(releaseModelOn(40, const MemoryReading(avail: 3 * _gb, total: 8 * _gb, low: true)), isTrue, reason: "the system's own low");
    expect(releaseModelOn(5, tight), isFalse, reason: 'running moderate: not yet');
  });

  group('wake', () {
    Future<AppState> resting(int availBytes) async {
      final app = AppState(
        settingsDirOverride: dir,
        modelsDirOverride: Directory('${dir.path}/models'),
        memory: () async => MemoryReading(avail: availBytes, total: 8 * _gb, threshold: 200 << 20),
      );
      app.models = [ModelEntry(path: '${dir.path}/models/chat-Q6_K.gguf', size: 16)];
      app.resting = app.models.first;
      return app;
    }

    test('gated: it needs more than the memory free now, so it stays resting and nothing loads', () async {
      final app = await resting(900 << 20); // the working memory alone is more
      await app.wake();
      expect(app.resting?.fileName, 'chat-Q6_K.gguf', reason: 'still the chosen one; Ask shows its Load button');
      expect(app.active, isNull);
      expect(app.loading, isNull);
      expect(app.loadError, isNull, reason: 'it was not tried');
    });

    test('gated, then the person taps Load: forced, it is tried whatever the room', () async {
      final app = await resting(900 << 20);
      await app.wake(force: true);
      expect(app.resting, isNull, reason: 'the load was begun (the test file is not a model, so it then fails)');
    });

    test('not gated: with the room, the load is tried', () async {
      final app = await resting(6 * _gb);
      await app.wake();
      expect(app.resting, isNull, reason: 'the load was begun (the test file is not a model, so it then fails)');
    });

    test('unknown memory does not gate', () async {
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'), memory: () async => null);
      app.models = [ModelEntry(path: '${dir.path}/models/chat-Q6_K.gguf', size: 16)];
      app.resting = app.models.first;
      await app.wake();
      expect(app.resting, isNull);
    });
  });
}

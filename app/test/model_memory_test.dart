import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/model_downloads.dart' show ModelFit;
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

  test('what a model needs by its size (the recommendation path, unchanged): about two thirds of its file, plus a gigabyte', () {
    expect(modelMemoryNeedBySize(0), _gb);
    expect(modelMemoryNeedBySize(3 * _gb) >> 20, closeTo(3 * 1024 * 0.65 + 1024, 1));
    expect(modelMemoryNeedBySize(3427879936), 3301863782, reason: 'a real E2B file: the same number as before the tensor-aware check');
    // the fit of a model in the lists still uses it: a 1 GiB file needs 0.65 GiB + 1 GiB (about 1.65 GiB) of room
    expect(ModelFit.of(_gb, 8 * _gb, room: (1.6 * _gb).round()), ModelFit.tight);
    expect(ModelFit.of(_gb, 8 * _gb, room: (1.7 * _gb).round()), ModelFit.fits);
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
}

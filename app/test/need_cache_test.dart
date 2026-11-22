// The memory need of a model file is read once per run for a file (its header is about 16 MB of reads on the UI isolate), and again
// when the file changed.
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/platform/memory_need.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late AppState app;
  late List<String> reads;
  late File file;
  late ModelEntry entry;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('need-cache');
    app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    reads = [];
    app.memoryNeedReader = (path, {int nCtx = 8192, int? fallbackBytes}) async {
      reads.add('$path|$nCtx');
      return MemoryNeed(weights: 1, kv: 1, compute: 1, fromHeader: true, sizeTotal: 0);
    };
    file = File('${dir.path}/m.gguf')..writeAsBytesSync(List.filled(16, 0));
    entry = ModelEntry(path: file.path, size: 16);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a second call does not read the header again', () async {
    final a = await app.needOf(entry);
    final b = await app.needOf(entry);
    expect(reads, hasLength(1));
    expect(identical(a, b), isTrue);
  });

  test('a changed file (length or modified time) is read again', () async {
    await app.needOf(entry);
    file.writeAsBytesSync(List.filled(32, 0)); // a new length and time
    await app.needOf(entry);
    expect(reads, hasLength(2));
    file.setLastModifiedSync(DateTime(2020));
    await app.needOf(entry);
    expect(reads, hasLength(3), reason: 'the same length with another time counts as changed');
    await app.needOf(entry);
    expect(reads, hasLength(3));
  });
}

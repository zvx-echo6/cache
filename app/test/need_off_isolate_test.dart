// The memory need's header read runs off the UI isolate; the result is cached as before; a read that fails falls back to the size.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:cache/app_state.dart';
import 'package:cache/platform/memory.dart' show modelMemoryNeed;
import 'package:cache/platform/memory_need.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  late int calls;
  late Future<R> Function<R>(FutureOr<R> Function() computation) original;
  late Future<R> Function<R>(FutureOr<R> Function() computation) inline;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('need-isolate');
    file = File('${dir.path}/m.gguf')..writeAsBytesSync(List.filled(64, 0)); // not a GGUF: the header cannot be read
    calls = 0;
    inline = memoryNeedRunner; // what the test config sets for every test
    original = Isolate.run; // the real runner, for this file
    memoryNeedRunner = <R>(FutureOr<R> Function() f) {
      calls++;
      return original<R>(f);
    };
  });
  tearDown(() {
    memoryNeedRunner = inline;
    dir.deleteSync(recursive: true);
  });

  test('the first read goes through the off-isolate runner, and that runner is not the UI isolate', () async {
    await memoryNeedForFile(file.path, fallbackBytes: 64);
    expect(calls, 1, reason: 'the header read was run through the isolate runner');
    final here = Isolate.current.hashCode;
    final there = await original<int>(() => Isolate.current.hashCode);
    expect(there, isNot(here), reason: 'the default runner is another isolate');
  });

  test('a second needOf is the cache: no isolate is started', () async {
    final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    final e = ModelEntry(path: file.path, size: 64);
    final a = await app.needOf(e);
    final b = await app.needOf(e);
    expect(calls, 1);
    expect(identical(a, b), isTrue);
    app.dispose();
  });

  test('when the read throws, the size-based estimate is used', () async {
    memoryNeedRunner = <R>(FutureOr<R> Function() f) => Future<R>.error(const FormatException('bad header'));
    final need = await memoryNeedForFile(file.path, fallbackBytes: 64);
    expect(need, isNotNull);
    expect(need!.fromHeader, isFalse);
    expect(need.total, modelMemoryNeed(64));
  });

  test('a file that is not a GGUF falls back to the size too', () async {
    final need = await memoryNeedForFile(file.path, fallbackBytes: 64);
    expect(need!.fromHeader, isFalse);
    expect(need.total, modelMemoryNeed(64));
  });
}

// The test APK's switch that defers Ask's search-model load until the prompt read ahead is done (--ez cache_defer_search_load true).
import 'dart:async';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/search_model.dart';
import 'package:cache/platform/bench_options.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake extends CacheEmbedder {
  _Fake(String path) : super(modelPath: path);
  int warms = 0;
  int embeds = 0;

  @override
  Future<void> warm() async => warms++;

  @override
  Future<List<double>> embed(String text) async {
    embeds++;
    return [0.25, 0.5, 0.75];
  }

  @override
  void free() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState app;
  late List<_Fake> made;
  late SearchModel sm;
  late List<String> log;
  late DebugPrintCallback oldPrint;
  const channel = MethodChannel('cache/bench');
  void answer(Object? Function(MethodCall) f) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async => f(c));

  setUp(() async {
    log = [];
    oldPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => log.add(m ?? '');
    dir = Directory.systemTemp.createTempSync('search-defer');
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/bge-m3-Q8_0.gguf').writeAsBytesSync(List.filled(1000, 1));
    app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
    made = [];
    await app.init();
    sm = SearchModel(
      app: app,
      modelsDir: () async => app.modelsDir!,
      make: (p) {
        final f = _Fake(p);
        made.add(f);
        return f;
      },
      remote: false,
      readMemoryNow: () async => MemoryReading(avail: 4096 << 20, total: 8192 << 20),
      readCounters: () => const {'VmRSS_kb': 2048},
    );
    SearchModel.shared = sm;
  });
  tearDown(() {
    debugPrint = oldPrint;
    benchDeferSearchLoad = false;
    SearchModel.shared = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    sm.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('gating: false by default, in a non-test build and off Android; true only from the test APK', () async {
    expect(BenchOptions.off.deferSearchLoad, isFalse);
    expect(benchDeferSearchLoad, isFalse);
    answer((_) => {'testApk': true});
    expect((await readBenchOptions(android: true)).deferSearchLoad, isFalse);
    answer((_) => {'testApk': false, 'cache_defer_search_load': true});
    expect((await readBenchOptions(android: true)).deferSearchLoad, isFalse);
    answer((_) => {'testApk': true, 'cache_defer_search_load': true});
    expect((await readBenchOptions(android: false)).deferSearchLoad, isFalse);
    final o = await readBenchOptions(android: true);
    expect(o.deferSearchLoad, isTrue);
    expect('$o', contains('defer_search_load=true'));
  });

  test('absent: Ask\'s open loads the search model at once, as always, and the deferral is never logged', () async {
    final readDone = Completer<void>();
    SearchModel.aboutToSearch(after: readDone.future);
    await pump();
    expect(made.single.warms, 1);
    expect(log.where((l) => l.contains('search model load:')), isEmpty);
  });

  test('on: the load waits for the read, then starts, with both lines logged', () async {
    benchDeferSearchLoad = true;
    final readDone = Completer<void>();
    SearchModel.aboutToSearch(after: readDone.future);
    await pump();
    expect(made, isEmpty, reason: 'deferred until the read is done');
    expect(log.any((l) => l.contains('search model load: deferred until the read is done')), isTrue);
    readDone.complete();
    await pump();
    expect(made.single.warms, 1);
    expect(log.any((l) => RegExp(r'search model load: started after the read \(\d+ ms after Ask open\)').hasMatch(l)), isTrue);
  });

  test('on: a search before the read is done loads the model at once, and nothing hangs', () async {
    benchDeferSearchLoad = true;
    final readDone = Completer<void>();
    SearchModel.aboutToSearch(after: readDone.future);
    await pump();
    expect(made, isEmpty);
    final r = await sm.embedder.embed('water').timeout(const Duration(seconds: 2));
    expect(r, isNotNull);
    expect(r!.$2, isNotEmpty);
    expect(made.single.embeds, 1, reason: 'the search loaded the model on use');
    readDone.complete();
    await pump();
  });

  test('on, but no read to wait for (no future given): it loads at once as always', () async {
    benchDeferSearchLoad = true;
    SearchModel.aboutToSearch();
    await pump();
    expect(made.single.warms, 1);
  });
}

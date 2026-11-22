// The test APK's embedder thread switch (--ei cache_embed_threads N): absent at 0, and only the test APK's extra counts.
import 'package:cache/platform/bench_options.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cache/bench');
  void answer(Object? Function(MethodCall) f) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async => f(c));
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    benchEmbedThreads = 0;
  });

  test('0 when the extra is absent: the option is not in the log line and the embedder keeps its 4 threads', () async {
    expect(BenchOptions.off.embedThreads, 0);
    answer((_) => {'testApk': true});
    final o = await readBenchOptions(android: true);
    expect(o.embedThreads, 0);
    expect('$o', isNot(contains('embed_threads')));
    expect(benchEmbedThreads, 0);
    expect(CacheEmbedder(modelPath: 'x.gguf').threads, 4);
  });

  test('0 in a non-test build and off Android', () async {
    answer((_) => {'testApk': false, 'cache_embed_threads': 6});
    expect((await readBenchOptions(android: true)).embedThreads, 0);
    answer((_) => {'testApk': true, 'cache_embed_threads': 6});
    expect((await readBenchOptions(android: false)).embedThreads, 0);
  });

  test('the test APK\'s extra counts', () async {
    answer((_) => {'testApk': true, 'cache_embed_threads': 6});
    final o = await readBenchOptions(android: true);
    expect(o.embedThreads, 6);
    expect('$o', contains('embed_threads=6'));
  });
}

// The test APK's n_ubatch switch (--ei cache_ubatch N): passed to the native load only when the test APK sends it.
import 'dart:convert';

import 'package:cache/platform/bench_options.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cache/bench');
  void answer(Object? Function(MethodCall) f) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async => f(c));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('0 (the engine default) when the extra is absent; the load option is 0', () async {
    expect(BenchOptions.off.ubatch, 0);
    answer((_) => {'testApk': true});
    expect((await readBenchOptions(android: true)).ubatch, 0);
    expect(jsonDecode(llamaLoadOptions())['n_ubatch'], 0);
  });

  test('0 in a non-test build and off Android', () async {
    answer((_) => {'testApk': false, 'cache_ubatch': 256});
    expect((await readBenchOptions(android: true)).ubatch, 0);
    answer((_) => {'testApk': true, 'cache_ubatch': 256});
    expect((await readBenchOptions(android: false)).ubatch, 0);
  });

  test('the test APK\'s extra counts and reaches the load options', () async {
    answer((_) => {'testApk': true, 'cache_ubatch': 256});
    final o = await readBenchOptions(android: true);
    expect(o.ubatch, 256);
    expect('$o', contains('cache_ubatch=256'));
    expect(jsonDecode(llamaLoadOptions(nUbatch: o.ubatch))['n_ubatch'], 256);
    expect(jsonDecode(llamaLoadOptions(nUbatch: -5))['n_ubatch'], 0);
  });
}

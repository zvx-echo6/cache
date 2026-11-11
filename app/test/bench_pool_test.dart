// The test APK's chat threadpool switches (--ez cache_pool_pause true, --ei cache_pool_poll N): keys absent by default, and only the
// test APK's extras count.
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

  test('absent by default: no pause, poll -1, and neither key in the load options', () async {
    expect(BenchOptions.off.poolPause, isFalse);
    expect(BenchOptions.off.poolPoll, -1);
    final o = jsonDecode(llamaLoadOptions()) as Map;
    expect(o.containsKey('pool_pause'), isFalse);
    expect(o.containsKey('pool_poll'), isFalse);
    expect(o.keys, containsAll(['prefix_dir', 'repack_weights', 'preread_mbps']));
    answer((_) => {'testApk': true});
    final r = await readBenchOptions(android: true);
    expect(r.poolPause, isFalse);
    expect(r.poolPoll, -1);
    expect('$r', 'preread_mbps=0');
  });

  test('not in a non-test build, and not off Android', () async {
    answer((_) => {'testApk': false, 'cache_pool_pause': true, 'cache_pool_poll': 0});
    var r = await readBenchOptions(android: true);
    expect(r.poolPause, isFalse);
    expect(r.poolPoll, -1);
    answer((_) => {'testApk': true, 'cache_pool_pause': true, 'cache_pool_poll': 0});
    r = await readBenchOptions(android: false);
    expect(r.poolPause, isFalse);
    expect(r.poolPoll, -1);
  });

  test('the test APK\'s extras count; poll 0 is a value, not absence, and reaches the load options', () async {
    answer((_) => {'testApk': true, 'cache_pool_pause': true, 'cache_pool_poll': 0});
    final r = await readBenchOptions(android: true);
    expect(r.poolPause, isTrue);
    expect(r.poolPoll, 0);
    expect('$r', contains('pool_pause=true'));
    expect('$r', contains('pool_poll=0'));
    final o = jsonDecode(llamaLoadOptions(poolPause: r.poolPause, poolPoll: r.poolPoll)) as Map;
    expect(o['pool_pause'], true);
    expect(o['pool_poll'], 0);
    answer((_) => {'testApk': true, 'cache_pool_poll': 250});
    expect((await readBenchOptions(android: true)).poolPoll, 100, reason: 'the poll level is 0 to 100');
  });
}

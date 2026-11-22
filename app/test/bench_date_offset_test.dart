// The test APK's date shift (--ei cache_date_offset_days N): the date line of the chat's system prompt moves, nothing else does.
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/system_prompt.dart';
import 'package:cache/platform/bench_options.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cache/bench');
  void answer(Object? Function(MethodCall) f) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async => f(c));
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    benchDateOffsetDays = 0;
  });

  test('0 when the extra is absent', () async {
    expect(BenchOptions.off.dateOffsetDays, 0);
    answer((_) => {'testApk': true});
    expect((await readBenchOptions(android: true)).dateOffsetDays, 0);
    expect('${await readBenchOptions(android: true)}', 'preread_mbps=0');
  });

  test('0 in a non-test build, even if something answered with the key; and off Android', () async {
    answer((_) => {'testApk': false, 'date_offset_days': 3});
    expect((await readBenchOptions(android: true)).dateOffsetDays, 0);
    answer((_) => {'date_offset_days': 3});
    expect((await readBenchOptions(android: true)).dateOffsetDays, 0, reason: 'no testApk flag');
    answer((_) => {'testApk': true, 'date_offset_days': 3});
    expect((await readBenchOptions(android: false)).dateOffsetDays, 0);
  });

  test('the test APK\'s extra counts', () async {
    answer((_) => {'testApk': true, 'date_offset_days': 1});
    final o = await readBenchOptions(android: true);
    expect(o.dateOffsetDays, 1);
    expect('$o', contains('date_offset_days=1'));
  });

  test('the offset moves the system prompt\'s date line only: the question\'s clock line is today\'s', () async {
    final backend = ScriptedBackend([(r) => say('ok')]);
    final chat = ChatController(actCore: const ActCoreStandIn(), tools: [BatchSearch([])])..setBackend(backend);
    benchDateOffsetDays = 1;
    await chat.send('hello');
    final req = backend.requests.single;
    final msgs = req['messages'] as List;
    final system = (msgs.first as Map)['content'] as String;
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final today = DateTime.now();
    String d(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    expect(system, contains('Current local date: ${const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][tomorrow.weekday - 1]}, ${d(tomorrow)}'));
    final user = (msgs[1] as Map)['content'] as String;
    expect(user, startsWith('Local time: '));
    expect(user, isNot(contains(d(tomorrow))));
    expect(buildSystemPrompt(now: today, locationKnown: false), isNot(contains(d(tomorrow))));
  });
}

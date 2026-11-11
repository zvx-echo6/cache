import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/zim_download.dart';
import 'package:cache/chat/ask_focus.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/model_backend.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:cache/platform/bench_options.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/zim_download_test.dart' show FakeKiwix, data;
import 'chat_fakes.dart';
import 'support/act_core_stand_in.dart';

/// A model that waits for [release] (or for stop) before it answers, so a test can look at the focus mid-answer.
class GatedBackend implements ModelBackend {
  GatedBackend({this.fail = false});

  final bool fail;
  final Completer<void> release = Completer<void>();
  final List<bool> focusedAtStart = [];
  AskFocus? focus;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    final messages = request['messages'] as List;
    if ('${(messages.last as Map)['content']}'.contains('title')) {
      yield PartialMessage(isFinal: true, content: 'A title');
      return;
    }
    focusedAtStart.add(focus?.focused ?? false);
    await release.future;
    if (fail) throw StateError('the model failed');
    yield PartialMessage(isFinal: true, content: 'Boil it.', promptTokens: 10, generatedTokens: 3);
  }

  @override
  void stop() {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> log;
  late AskFocus focus;
  setUp(() {
    log = [];
    focus = AskFocus(log: log.add);
  });
  tearDown(() {
    askFocusShared = null;
    focus.dispose();
  });

  group('AskFocus', () {
    test('counts begin and end: on at the first, off at the last, extra ends do nothing', () {
      var notified = 0;
      focus.addListener(() => notified++);
      focus.register('Sync');
      focus.register('Downloads');
      expect(focus.focused, isFalse);
      focus.begin();
      focus.begin();
      expect(focus.depth, 2);
      expect(focus.focused, isTrue);
      focus.end();
      expect(focus.focused, isTrue, reason: 'one answer is still generating');
      focus.end();
      expect(focus.focused, isFalse);
      focus.end();
      expect(focus.depth, 0, reason: 'an end with no begin changes nothing');
      expect(notified, 2, reason: 'listeners hear the first begin and the last end only');
      expect(log, hasLength(2));
      expect(log[0], 'Ask focus: on, held: Downloads, Sync');
      expect(log[1], matches(RegExp(r'^Ask focus: off after \d+ ms$')));
    });

    test('a worker that checks idle starts no new unit while focused, finishes the one running, and carries on after', () async {
      final started = <int>[];
      final unit1 = Completer<void>();
      Future<void> worker() async {
        for (var i = 1; i <= 3; i++) {
          await focus.idle(worker: 'Fake worker');
          started.add(i);
          if (i == 1) await unit1.future; // a unit that is running when the focus begins
        }
      }

      final done = worker();
      await Future<void>.delayed(Duration.zero);
      expect(started, [1]);
      focus.begin();
      unit1.complete(); // the running unit finishes normally
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(started, [1], reason: 'unit 2 does not start while Ask answers');
      focus.end();
      await done;
      expect(started, [1, 2, 3], reason: 'the work goes on where it left off');
      expect(focus.waited, ['Fake worker']);
    });

    test('with a maximum wait, idle returns while still focused (a download keeps its connection alive)', () async {
      focus.begin();
      final sw = Stopwatch()..start();
      await focus.idle(maxWait: const Duration(milliseconds: 30));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(25));
      expect(focus.focused, isTrue);
    });

    test('idle returns at once when nothing is focused, and with no shared focus askIdle does too', () async {
      await focus.idle();
      await askIdle();
      askFocusShared = focus;
      focus.begin();
      var released = false;
      final w = askIdle().then((_) => released = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(released, isFalse);
      focus.end();
      await w;
      expect(released, isTrue);
    });

    test('a download that has not started waits for the focus to end, then downloads the exact bytes', () async {
      HttpOverrides.global = null; // the test binding answers every request with 400; this one talks to a local server
      final tmp = Directory.systemTemp.createTempSync('askfocus');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final k = FakeKiwix(data(200000));
      await k.start();
      addTearDown(k.stop);
      askFocusShared = focus;
      focus.begin();
      final part = File('${tmp.path}/f.zim.part');
      final run = ZimDownloader(freeSpace: (_) => 1 << 40).download(
        url: k.url,
        part: part,
        sha256Url: Uri.parse('${k.url}.sha256'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(k.bodyRequests, 0, reason: 'no request goes out while Ask answers');
      expect(part.existsSync(), isFalse);
      focus.end();
      final r = await run;
      expect(r.verified, isTrue);
      expect(r.file.readAsBytesSync(), data(200000));
    });
  });

  group('ChatController holds the focus', () {
    ChatController make(ModelBackend b, AskFocus f) => ChatController(actCore: const ActCoreStandIn(), tools: const [], focus: f)..setBackend(b);

    test('from the start of the answer to its end', () async {
      final b = GatedBackend()..focus = focus;
      final chat = make(b, focus);
      final sent = chat.send('How do I make water safe?');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(focus.focused, isTrue);
      expect(b.focusedAtStart, [true]);
      b.release.complete();
      await sent;
      expect(focus.focused, isFalse);
      expect(chat.messages.last.text, 'Boil it.');
      expect(log.first, startsWith('Ask focus: on'));
      expect(log.last, startsWith('Ask focus: off after'));
    });

    test('ends when the model fails', () async {
      final b = GatedBackend(fail: true)..focus = focus;
      final chat = make(b, focus);
      final sent = chat.send('How do I make water safe?');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(focus.focused, isTrue);
      b.release.complete();
      await sent;
      expect(focus.depth, 0);
      expect(chat.messages.last.error, isNotNull);
    });

    test('ends when the answer is cancelled (a new chat while it generates)', () async {
      final b = GatedBackend()..focus = focus;
      final chat = make(b, focus);
      final sent = chat.send('How do I make water safe?');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(focus.focused, isTrue);
      chat.newChat(); // stops the loop, which stops the backend
      await sent.timeout(const Duration(seconds: 5));
      expect(focus.depth, 0);
      expect(log.where((l) => l.startsWith('Ask focus: off')), hasLength(1));
    });

    test('an empty question holds nothing', () async {
      final chat = make(ScriptedBackend([(_) => say('x')]), focus);
      await chat.send('   ');
      expect(log, isEmpty);
      expect(focus.depth, 0);
    });
  });

  group('bench options', () {
    const channel = MethodChannel('cache/bench');
    void answer(Object? Function(MethodCall) f) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async => f(c));
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('the pre-read is off (0) unless the bench asks for it', () async {
      expect(kDefaultPrereadMbps, 0);
      expect(BenchOptions.off.prereadMbps, 0);
      expect(jsonDecode(llamaLoadOptions())['preread_mbps'], 0);
    });

    test('an extra that was given counts (60 turns the pre-read on)', () async {
      answer((_) => {'testApk': true, 'preread_mbps': 60});
      expect((await readBenchOptions(android: true)).prereadMbps, 60);
      answer((_) => {'testApk': true, 'preread_mbps': 40});
      final o = await readBenchOptions(android: true);
      expect(o.prereadMbps, 40);
      expect('$o', 'preread_mbps=40');
    });

    test('the default when the extra is absent (release build), the build is not Android, or the channel does not answer', () async {
      answer((_) => {'testApk': false});
      expect((await readBenchOptions(android: true)).prereadMbps, 0);
      answer((_) => {'preread_mbps': 0});
      expect((await readBenchOptions(android: false)).prereadMbps, 0, reason: 'only Android asks');
      answer((_) => throw PlatformException(code: 'x'));
      expect((await readBenchOptions(android: true)).prereadMbps, 0);
      answer((_) => 'nonsense');
      expect((await readBenchOptions(android: true)).prereadMbps, 0);
    });
  });
}

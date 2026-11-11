// The prompt read ahead: Ask shown with the model loaded reads the chat prompt's start (system prompt and tool schemas) into the
// model's cache before the first question. The native layer is faked (test/support/fake_native_chat.dart): these tests cover the
// Dart side (the request, when it starts, the guards, joining, stopping, the logs); cl_warm itself needs a model and is covered by
// the native test tool (cl_prefix) only.
import 'dart:async';
import 'dart:io';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/chat_location.dart';
import 'package:cache/chat/prompt_read_ahead.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'location_service_test.dart' show FakeSource;
import 'support/act_core_stand_in.dart';
import 'support/fake_native_chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> log;
  late DebugPrintCallback oldPrint;
  late FakeNativeChat native;
  late ChatController chat;
  var known = false;
  var hot = false;
  Future<FixWait> Function(Duration)? fixWait;
  late PromptReadAhead ahead;

  List<String> readLog() => [for (final l in log) if (l.contains('Prompt read ahead')) l.substring(l.indexOf('Prompt read ahead'))];

  setUp(() {
    log = [];
    oldPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => log.add(m ?? '');
    native = FakeNativeChat();
    known = false;
    hot = false;
    fixWait = null;
    chat = ChatController(
      actCore: const ActCoreStandIn(),
      tools: [BatchSearch([])],
      locationKnown: () => known,
    )..setBackend(native);
    ahead = PromptReadAhead(
      engine: native,
      request: (cancelled) => chat.warmRequest(isCancelled: cancelled),
      isHot: () async => hot,
      waitForFix: (t) => fixWait == null ? Future.value(FixWait.none) : fixWait!(t),
    );
  });
  tearDown(() => debugPrint = oldPrint);

  test('the tokens read ahead are a prefix of the tokens of the first real request, built by the production path', () async {
    final warm = await chat.warmRequest();
    expect(warm, isNotNull);
    final start = FakeNativeChat.stableStart(warm!)!;
    await chat.send('how do I purify water');
    final real = native.questions.single;
    expect(real.sublist(0, start.length), start, reason: 'the real request starts with the tokens the read ahead decodes');
    // The start is the system prompt and the tools, not a stub.
    expect(start, contains('<tools>'));
    expect(start.join(' '), contains('offline survival and preparedness assistant'));
    expect(start.length, greaterThan(40));
    // And the question comes after it.
    expect(real.length, greaterThan(start.length));
  });

  test('the read ahead request and the first question\'s request carry the same system prompt, tools and thinking switch', () async {
    final warm = (await chat.warmRequest())!;
    await chat.send('hello');
    final real = native.questionRequests.single;
    expect((warm['messages'] as List).single, (real['messages'] as List).first);
    expect(warm['tools'], real['tools']);
    expect(warm['tools'], isNotEmpty);
    expect(warm['enable_thinking'], real['enable_thinking']);
    expect(warm.containsKey('tool_choice'), real.containsKey('tool_choice'));
  });

  test('reads the start ahead, saves it, and the question that follows evaluates none of it', () async {
    await ahead.start();
    expect(native.readCalls, 1);
    expect(native.files, hasLength(1));
    final start = native.reads.single;
    expect(native.decoded, start.length);
    final lines = readLog();
    expect(lines.first, 'Prompt read ahead: started (${start.length} tokens)');
    expect(lines.last, matches(RegExp(r'^Prompt read ahead: done, \d+ tokens in [\d.]+ s \(a question joined: no\)$')));
    await chat.send('hello');
    for (var p = 0; p < start.length; p++) {
      expect(native.decodedAt[p], 1, reason: 'position $p was decoded once');
    }
    expect(chat.messages.last.text, 'ok');
  });

  test('covered: a start already in the cache or in a saved file is not read again', () async {
    await ahead.start();
    log.clear();
    await ahead.start();
    expect(native.readCalls, 1);
    expect(readLog(), ['Prompt read ahead: skipped (already read)']);
    // Only in a saved file: the cache is gone.
    native.cached = [];
    log.clear();
    await ahead.start();
    expect(native.readCalls, 1);
    expect(readLog(), ['Prompt read ahead: skipped (already read)']);
  });

  test('no model, no read: nothing is asked of the engine', () async {
    native.loaded = false;
    await ahead.start();
    expect(native.checks + native.readCalls, 0);
    expect(native.warmRequests, isEmpty);
    expect(readLog(), ['Prompt read ahead: skipped (no model is loaded)']);
  });

  test('a question sent mid-read waits behind it: the start is evaluated once, and the answer is normal', () async {
    final batchGate = Completer<void>();
    final inRead = Completer<void>();
    native.afterBatch = (n) async {
      if (n == native.batch && !inRead.isCompleted) {
        inRead.complete();
        await batchGate.future;
      }
    };
    final reading = ahead.start();
    await inRead.future;
    expect(ahead.reading, isTrue);
    final asked = chat.send('how do I purify water');
    await Future<void>.delayed(Duration.zero);
    expect(native.questions, isEmpty, reason: 'the question queues behind the read');
    batchGate.complete();
    await reading;
    await asked;
    final start = native.reads.single;
    for (var p = 0; p < start.length; p++) {
      expect(native.decodedAt[p], 1, reason: 'position $p of the start was evaluated once');
    }
    expect(native.decoded, native.questions.single.length, reason: 'the start once, the question once, nothing twice');
    expect(chat.messages.last.text, 'ok');
    expect(chat.messages.last.error, isNull);
    expect(readLog().last, contains('(a question joined: yes)'));
  });

  test('Cache going to the back aborts the read: whole batches stay in the cache, no prefix file is written', () async {
    final inRead = Completer<void>();
    final batchGate = Completer<void>();
    native.afterBatch = (n) async {
      if (!inRead.isCompleted) {
        inRead.complete();
        await batchGate.future;
      }
    };
    final reading = ahead.start();
    await inRead.future;
    ahead.toBackground();
    batchGate.complete();
    await reading;
    expect(native.stopCalls, 1);
    expect(native.files, isEmpty);
    expect(native.cached, hasLength(native.batch), reason: 'the batch decoded whole stays');
    expect(readLog().last, startsWith('Prompt read ahead: skipped (stopped after ${native.batch} of '));
  });

  test('Cache going to the back after the read is queued and before it starts: nothing is read, and it is logged as stopped', () async {
    final hold = Completer<void>();
    native.holdBeforeRead = hold.future; // the worker is busy with an earlier call
    final reading = ahead.start();
    for (var i = 0; i < 20 && native.checks == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    expect(native.readCalls, 0);
    ahead.toBackground();
    hold.complete();
    await reading;
    expect(native.readCalls, 0);
    expect(native.decoded, 0);
    expect(native.cached, isEmpty);
    expect(native.files, isEmpty);
    expect(readLog().last, matches(RegExp(r'^Prompt read ahead: skipped \(stopped after 0 of \d+ tokens\)$')));
  });

  test('leaving Ask with Cache still in front lets the read finish', () async {
    final inRead = Completer<void>();
    final leave = Completer<void>();
    native.afterBatch = (n) async {
      if (!inRead.isCompleted) {
        inRead.complete();
        await leave.future;
      }
    };
    final reading = ahead.start();
    await inRead.future;
    // The person leaves Ask: nothing is told to the read ahead (only Cache going to the back is).
    leave.complete();
    await reading;
    expect(native.stopCalls, 0);
    expect(native.files, hasLength(1));
    expect(readLog().last, startsWith('Prompt read ahead: done'));
  });

  test('loop guard: one read per opening; a read in flight is not restarted, whatever changes in the prompt', () async {
    final inRead = Completer<void>();
    final go = Completer<void>();
    native.afterBatch = (n) async {
      if (!inRead.isCompleted) {
        inRead.complete();
        await go.future;
      }
    };
    final first = ahead.start();
    await inRead.future;
    known = true; // a location flicker changes the prompt
    await ahead.start();
    await ahead.start();
    expect(native.readCalls, 1);
    expect(readLog().where((l) => l == 'Prompt read ahead: skipped (a read is already running)'), hasLength(2));
    go.complete();
    await first;
    expect(native.readCalls, 1);
    expect(native.reads, hasLength(1));
  });

  test('a hot device skips the read (the throttle\'s heat signal)', () async {
    hot = true;
    await ahead.start();
    expect(native.checks + native.readCalls, 0);
    expect(readLog(), ['Prompt read ahead: skipped (device hot)']);
  });

  group('the location wait', () {
    test('a fix that arrives lets the read start, and the read says the location is known', () async {
      final fix = Completer<FixWait>();
      Duration? asked;
      fixWait = (t) {
        asked = t;
        return fix.future;
      };
      final run = ahead.start();
      await Future<void>.delayed(Duration.zero);
      expect(native.readCalls, 0, reason: 'waiting for the fix');
      known = true;
      fix.complete(FixWait.arrived);
      await run;
      expect(asked, kReadAheadFixWait);
      expect(kReadAheadFixWait, const Duration(seconds: 10));
      expect(readLog().first, contains('waited'));
      expect(readLog().first, contains('it arrived'));
      expect(native.reads.single.join(' '), contains('is known'));
    });

    test('no fix in time: it starts with the location not known', () async {
      fixWait = (t) async => FixWait.timedOut;
      await ahead.start();
      expect(readLog().first, contains('none came'));
      expect(native.reads.single.join(' '), contains('is not known'));
    });

    test('location off or denied: it starts at once, with nothing logged about a wait', () async {
      fixWait = (t) async => FixWait.none;
      await ahead.start();
      expect(readLog().where((l) => l.contains('waited')), isEmpty);
      expect(native.readCalls, 1);
    });
  });

  group('ChatLocation.waitForFix', () {
    late LocationService service;
    late ChatLocation bridge;
    late FakeSource source;

    setUp(() async {
      source = FakeSource()..state = LocationPermissionState.granted;
      final dir = Directory.systemTemp.createTempSync('read-ahead-location-');
      addTearDown(() => dir.deleteSync(recursive: true));
      late ChatLocation b;
      service = LocationService(source: source, settingsDirOverride: dir, onFix: (f) => b.update(f));
      bridge = b = ChatLocation(location: service, synchronize: (_) async => true);
      await service.init();
      addTearDown(service.dispose);
    });

    test('off: nothing to wait for', () async {
      await service.setEnabled(false);
      expect(await bridge.waitForFix(const Duration(seconds: 10)), FixWait.none);
    });

    test('denied: nothing to wait for', () async {
      service.permission = LocationPermissionState.denied;
      expect(await bridge.waitForFix(const Duration(seconds: 10)), FixWait.none);
    });

    test('a fix on its way arrives', () async {
      expect(bridge.fixPending, isTrue);
      final w = bridge.waitForFix(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      service.fix = Fix(lat: 42.5, lon: -113.8, accuracyM: 10, time: DateTime.now());
      bridge.update(service.fix);
      expect(await w, FixWait.arrived);
      expect(bridge.known, isTrue);
    });

    test('no fix within the time: timed out', () async {
      expect(await bridge.waitForFix(const Duration(milliseconds: 30)), FixWait.timedOut);
      expect(bridge.known, isFalse);
    });
  });
}

// The chat model at a start by the car. Android Auto can start Cache with the phone app closed. The car never asks the chat
// model anything, so that start does not load it (it used to, at every car connect); it loads when the phone's screen first
// appears, as it would have at a start with the screen, or when Ask needs it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/platform/phone_screen.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;
const _file = 'chat-Q6_K.gguf';
const _info = ModelInfo(description: 'Gemma 4 E2B', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);

/// The native session, by hand: it keeps what it was asked to do.
class _Session implements LlamaSession {
  final calls = <String>[];

  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async {
    calls.add('load');
    return _info;
  }

  @override
  Future<void> unload() async {
    calls.add('unload');
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  late Directory dir;
  late _Session session;
  var avail = 6 * _gb;

  /// A phone screen is there to answer the memory reading (on Android its activity does; with none, nothing answers).
  var answered = true;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('car-start-model');
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/$_file')
      ..createSync()
      ..writeAsBytesSync(List.filled(16, 0));
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'lastModel': _file}));
    session = _Session();
    avail = 6 * _gb;
    answered = true;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The app's state at a start; [noPhoneScreen]: the car started Cache with the phone app closed ([asked]: asked of the app).
  AppState make({bool? noPhoneScreen, bool Function()? asked}) {
    final no = noPhoneScreen;
    return AppState(
      settingsDirOverride: dir,
      modelsDirOverride: Directory('${dir.path}/models'),
      session: session,
      memory: () async => answered ? MemoryReading(avail: avail, total: 8 * _gb, threshold: 200 << 20) : null,
      startedWithNoPhoneScreen: asked ?? (no == null ? null : () => no),
    );
  }

  test('started by the car with the phone app closed, the chosen model is not loaded: it rests, still the chosen one', () async {
    final app = make(noPhoneScreen: true);
    await app.init();
    expect(session.calls, isEmpty);
    expect(app.active, isNull);
    expect(app.loading, isNull);
    expect(app.resting?.fileName, _file);
    expect(app.chosenModelFile, _file);
    expect(app.heldForMemory, isFalse, reason: 'not held for memory: nothing asked for it yet');
    expect(app.failed, isNull, reason: 'it was not tried');
    expect(app.started, isTrue);
  });

  test('it loads when the phone\'s screen first appears, once', () async {
    final app = make(noPhoneScreen: true);
    await app.init();
    await app.phoneScreenAppeared();
    expect(session.calls, ['load']);
    expect(app.active?.fileName, _file);
    expect(app.resting, isNull);
    // Later screens (the app closed and opened again) load nothing by themselves.
    await app.release();
    await app.phoneScreenAppeared();
    expect(session.calls, ['load', 'unload']);
    expect(app.resting?.fileName, _file);
  });

  test('the phone\'s screen appearing loads it under the same memory gate as a start', () async {
    final app = make(noPhoneScreen: true);
    await app.init();
    avail = 900 << 20; // less than a model of any size needs
    await app.phoneScreenAppeared();
    expect(session.calls, isEmpty);
    expect(app.resting?.fileName, _file);
    expect(app.heldForMemory, isTrue);
    expect(app.heldFreeMb, 700);
    // Ask's own Load button still loads it, as after any held start.
    await app.wake(force: true);
    expect(session.calls, ['load']);
    expect(app.active?.fileName, _file);
  });

  test('Ask needing it first loads it the usual way, and the screen appearing then loads nothing more', () async {
    final app = make(noPhoneScreen: true);
    await app.init();
    await app.wake();
    expect(session.calls, ['load']);
    await app.phoneScreenAppeared();
    expect(session.calls, ['load']);
  });

  test('a start with the phone\'s screen loads the chosen model as before', () async {
    final withScreen = make(noPhoneScreen: false);
    await withScreen.init();
    expect(session.calls, ['load']);
    expect(withScreen.active?.fileName, _file);
    // Where nothing says how Cache was started (every platform but Android, and the tests): the same.
    session.calls.clear();
    final plain = make();
    await plain.init();
    expect(session.calls, ['load']);
  });

  test('after a start with the phone\'s screen, a screen appearing wakes nothing: a model let go for memory waits for Ask', () async {
    final app = make(noPhoneScreen: false);
    await app.init();
    await app.release();
    expect(app.resting?.fileName, _file);
    await app.phoneScreenAppeared();
    expect(session.calls, ['load', 'unload']);
    expect(app.active, isNull);
  });

  // Bug: the model was loaded with no phone screen and whatever the free memory. The app had been told "a screen is in front"
  // by mistake (below), nothing answered the memory reading, and a load with no reading is not held back.
  test('a screen announced when none answers the memory reading loads nothing: the model goes on waiting for a real one', () async {
    final app = make(noPhoneScreen: true);
    await app.init();
    answered = false;
    await app.phoneScreenAppeared();
    await app.phoneScreenAppeared();
    expect(session.calls, isEmpty);
    expect(app.active, isNull);
    expect(app.loading, isNull);
    expect(app.resting?.fileName, _file);
    // The phone's screen really appears: its memory reading is there, and the model loads through the gate.
    answered = true;
    await app.phoneScreenAppeared();
    expect(session.calls, ['load']);
    expect(app.active?.fileName, _file);
  });

  group('the app as the car starts it, with the lifecycle as Android sends it', () {
    /// One lifecycle message from the platform, as the engine delivers it.
    Future<void> say(WidgetTester tester, String state) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/lifecycle', const StringCodec().encodeMessage('AppLifecycleState.$state'), (_) {});
    }

    /// Real time passes (the model's file is read for the memory gate) until [done] holds, at most about two seconds.
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    /// Time enough for a load to have begun, had anything asked for one.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    /// The app started by the car: an Android engine starts in the state detached, nothing answers the memory reading (no
    /// activity), and the app asks the lifecycle whether a phone screen is there, as main.dart does. The phone's interface is
    /// wired to the model as there too.
    Future<(AppState, List<String>)> carStarts(WidgetTester tester) async {
      await say(tester, 'detached');
      answered = false;
      final app = make(asked: () => noPhoneScreen(WidgetsBinding.instance.lifecycleState));
      await tester.runAsync(app.init);
      final screens = <String>[];
      await tester.pumpWidget(PhoneScreenScope(
        onScreen: () {
          screens.add('a screen in front');
          unawaited(app.phoneScreenAppeared());
        },
        builder: (context) => const SizedBox(),
      ));
      // An app's first frame is drawn whatever the lifecycle says (runApp's own); with frames off a test has to ask for it.
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      expect(find.byType(PhoneScreenScope), findsOneWidget);
      expect(session.calls, isEmpty, reason: 'not loaded at a start by the car');
      expect(app.resting?.fileName, _file);
      return (app, screens);
    }

    // Bug: when the car that had started Cache left, the car side sent the app "inactive, paused, detached" to say that nothing
    // showed it any more. After "detached" (the state an Android engine starts in) Flutter reports "resumed" before any other
    // state, so the app read a phone screen coming to the front and loaded the chat model: 3.3 GB in 15 s, for nothing, and
    // not held back by the memory gate. The car side no longer sends anything; this is what the app does if it ever comes.
    testWidgets('sent "inactive, paused, detached" with no phone screen, it loads no model', (tester) async {
      final (app, screens) = await carStarts(tester);
      await say(tester, 'inactive');
      await say(tester, 'paused');
      await say(tester, 'detached');
      await settle(tester);
      expect(screens, ['a screen in front'], reason: 'Flutter did report a resume first: the trap');
      expect(session.calls, isEmpty);
      expect(app.active, isNull);
      expect(app.loading, isNull);
      expect(app.resting?.fileName, _file, reason: 'still the chosen model, still waiting for a phone screen');

      // The phone's screen really opens later: now the model loads, through the memory gate.
      answered = true;
      await say(tester, 'resumed');
      await until(tester, () => app.active != null);
      expect(session.calls, ['load']);
      expect(app.active?.fileName, _file);
    });

    testWidgets('the first phone screen with too little memory free: the model is asked for at the open itself, and held back', (tester) async {
      final (app, screens) = await carStarts(tester);
      await settle(tester);
      expect(screens, isEmpty);
      expect(session.calls, isEmpty);

      answered = true;
      avail = 900 << 20;
      await say(tester, 'resumed');
      await until(tester, () => app.heldForMemory);
      expect(screens, ['a screen in front']);
      expect(session.calls, isEmpty);
      expect(app.heldForMemory, isTrue);
      expect(app.resting?.fileName, _file);
    });

    testWidgets('the first phone screen with room loads the model at the open itself', (tester) async {
      final (app, _) = await carStarts(tester);
      answered = true;
      await say(tester, 'resumed');
      await until(tester, () => app.active != null);
      expect(session.calls, ['load']);
    });
  });

  test('with no chosen model nothing rests and nothing loads', () async {
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'theme': 'dark'}));
    final app = make(noPhoneScreen: true);
    await app.init();
    await app.phoneScreenAppeared();
    expect(session.calls, isEmpty);
    expect(app.resting, isNull);
  });
}

// The chat model at a start by the car. Android Auto can start Cache with the phone app closed. The car never asks the chat
// model anything, so that start does not load it (it used to, at every car connect); it loads when the phone's screen first
// appears, as it would have at a start with the screen, or when Ask needs it.

import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache_llama/cache_llama.dart';
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

  setUp(() {
    dir = Directory.systemTemp.createTempSync('car-start-model');
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/$_file')
      ..createSync()
      ..writeAsBytesSync(List.filled(16, 0));
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'lastModel': _file}));
    session = _Session();
    avail = 6 * _gb;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The app's state at a start; [noPhoneScreen]: the car started Cache with the phone app closed.
  AppState make({bool? noPhoneScreen}) {
    final no = noPhoneScreen;
    return AppState(
      settingsDirOverride: dir,
      modelsDirOverride: Directory('${dir.path}/models'),
      session: session,
      memory: () async => MemoryReading(avail: avail, total: 8 * _gb, threshold: 200 << 20),
      startedWithNoPhoneScreen: no == null ? null : () => no,
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

  test('with no chosen model nothing rests and nothing loads', () async {
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'theme': 'dark'}));
    final app = make(noPhoneScreen: true);
    await app.init();
    await app.phoneScreenAppeared();
    expect(session.calls, isEmpty);
    expect(app.resting, isNull);
  });
}

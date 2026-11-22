// The chat model at a start (owner, 2026-11-13): it is never loaded at start, by the car or with the phone's screen, whatever the
// room. It rests, still the chosen model, and loads when Ask opens (AppState.wake, under the memory gate) or by Ask's Load button.
// It used to load at every start with the room for it, and an iPhone started by CarPlay held it through a whole drive.

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
    dir = Directory.systemTemp.createTempSync('chat-model-start');
    Directory('${dir.path}/models').createSync();
    File('${dir.path}/models/$_file')
      ..createSync()
      ..writeAsBytesSync(List.filled(16, 0));
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'lastModel': _file}));
    session = _Session();
    avail = 6 * _gb;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AppState make() => AppState(
        settingsDirOverride: dir,
        modelsDirOverride: Directory('${dir.path}/models'),
        session: session,
        memory: () async => MemoryReading(avail: avail, total: 8 * _gb, threshold: 200 << 20),
      );

  test('a start with all the room it needs loads nothing: the chosen model rests, still the chosen one', () async {
    final app = make();
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

  test('a start with too little room is the same: resting, not held (the gate runs when Ask opens)', () async {
    avail = 900 << 20;
    final app = make();
    await app.init();
    expect(session.calls, isEmpty);
    expect(app.resting?.fileName, _file);
    expect(app.heldForMemory, isFalse);
  });

  test('Ask opening loads it, once', () async {
    final app = make();
    await app.init();
    await app.wake();
    expect(session.calls, ['load']);
    expect(app.active?.fileName, _file);
    expect(app.resting, isNull);
    await app.wake();
    expect(session.calls, ['load'], reason: 'already loaded');
  });

  test('Ask opening with too little room holds it back; Ask\'s Load button loads it whatever the room', () async {
    avail = 900 << 20;
    final app = make();
    await app.init();
    await app.wake();
    expect(session.calls, isEmpty);
    expect(app.heldForMemory, isTrue);
    expect(app.heldFreeMb, 700);
    await app.wake(force: true);
    expect(session.calls, ['load']);
    expect(app.active?.fileName, _file);
  });

  test('let go, it rests again and the next Ask opening loads it again', () async {
    final app = make();
    await app.init();
    await app.wake();
    await app.release();
    expect(app.active, isNull);
    expect(app.resting?.fileName, _file);
    await app.wake();
    expect(session.calls, ['load', 'unload', 'load']);
  });

  test('with no chosen model nothing rests and nothing loads', () async {
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({}));
    final app = make();
    await app.init();
    expect(session.calls, isEmpty);
    expect(app.resting, isNull);
    expect(app.active, isNull);
  });
}

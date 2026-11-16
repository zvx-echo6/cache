import 'dart:isolate';
import 'dart:typed_data';

import 'package:cache_llama/embedder_io.dart';
import 'package:flutter_test/flutter_test.dart';

// Stand-in workers (top level, so they can start an isolate).

/// Throws before it says it is ready.
void _failsAtStart(SendPort toMain) => throw StateError('no native library');

/// Answers embed and free like the real worker.
void _works(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  rp.listen((dynamic m) {
    final msg = m as Map;
    switch (msg['type']) {
      case 'embed':
        toMain.send({'id': msg['id'], 'vector': TransferableTypedData.fromList([Float32List.fromList([1, 0])]), 'workerMs': 1});
      case 'load':
      case 'free':
        if (msg['id'] != null) toMain.send({'id': msg['id']});
    }
  });
}

/// Ready, then dies on the first embed.
void _diesOnEmbed(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  rp.listen((dynamic m) {
    if ((m as Map)['type'] == 'embed') throw StateError('native crash');
  });
}

/// Ready, answers embed, never answers free.
void _neverFrees(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  rp.listen((dynamic m) {
    final msg = m as Map;
    if (msg['type'] == 'embed') {
      toMain.send({'id': msg['id'], 'vector': TransferableTypedData.fromList([Float32List.fromList([1, 0])]), 'workerMs': 1});
    }
  });
}

CacheEmbedder _make(void Function(SendPort) entry) => CacheEmbedder(modelPath: '/none/model.gguf')..workerEntry = entry;

void main() {
  const limit = Duration(seconds: 10);

  test('a worker that fails at start makes the search fail, not wait forever', () async {
    final e = _make(_failsAtStart);
    await expectLater(e.embed('water').timeout(limit), throwsA(isA<StateError>()));
    await e.dispose();
  });

  test('after a failed start the next call starts a new worker', () async {
    final e = _make(_failsAtStart);
    await expectLater(e.embed('water').timeout(limit), throwsA(isA<StateError>()));
    e.workerEntry = _works;
    expect(await e.embed('water').timeout(limit), [1.0, 0.0]);
    await e.dispose();
  });

  test('a worker that dies during a search fails that search, and the next search gets a new worker', () async {
    final e = _make(_diesOnEmbed);
    await expectLater(e.embed('water').timeout(limit), throwsA(isA<StateError>()));
    e.workerEntry = _works;
    expect(await e.embed('fire').timeout(limit), [1.0, 0.0]);
    await e.dispose();
  });

  test('after free the next search loads again and works', () async {
    final e = _make(_works);
    await e.embed('water').timeout(limit);
    e.free();
    expect(await e.embed('fire').timeout(limit), [1.0, 0.0]);
    await e.dispose();
  });

  test('free and dispose with no worker do nothing', () async {
    final e = _make(_works)..free();
    await e.dispose().timeout(limit);
  });

  test('dispose waits for the worker to let the model go', () async {
    final e = _make(_works);
    await e.embed('water').timeout(limit);
    await e.dispose().timeout(limit);
  });

  test('dispose ends even when the worker never answers free', () async {
    final e = _make(_neverFrees)..freeTimeout = const Duration(milliseconds: 200);
    await e.embed('water').timeout(limit);
    await e.dispose().timeout(limit);
  });

  test('after dispose a new call starts a new worker', () async {
    final e = _make(_works);
    await e.embed('water').timeout(limit);
    await e.dispose();
    expect(await e.embed('fire').timeout(limit), [1.0, 0.0]);
    await e.dispose();
  });
}

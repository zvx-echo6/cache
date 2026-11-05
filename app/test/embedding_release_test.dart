import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

/// Emulates the existing worker protocol without opening native libraries.
void fakeEmbeddingWorker(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  var loaded = false;
  var loads = 0;
  receive.listen((dynamic message) {
    final m = message as Map;
    if (m['type'] == 'embed') {
      if (!loaded) {
        loaded = true;
        loads++;
      }
      main.send({
        'id': m['id'],
        'vector': TransferableTypedData.fromList([
          Float32List.fromList([loads.toDouble()]),
        ]),
      });
    } else if (m['type'] == 'free') {
      Timer(const Duration(milliseconds: 30), () {
        loaded = false;
        if (m['id'] != null) main.send({'id': m['id'], 'freed': true});
      });
    }
  });
}

void main() {
  test('free acknowledges release before a subsequent embed reloads the same engine', () async {
    final e = CacheEmbedder(modelPath: 'same-model.gguf', workerEntry: fakeEmbeddingWorker);
    expect(await e.embed('first'), [1.0]);
    var freed = false;
    final release = e.free().then((_) => freed = true);
    expect(freed, isFalse);
    await release;
    expect(freed, isTrue);
    expect(await e.embed('second'), [2.0]);
    await e.dispose();
  });
  test('free before first use is safe and does not prevent later use', () async {
    final e = CacheEmbedder(modelPath: 'same-model.gguf', workerEntry: fakeEmbeddingWorker);
    await e.free();
    expect(await e.embed('first'), [1.0]);
    await e.dispose();
  });
}

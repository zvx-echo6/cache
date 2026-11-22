import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'cache_llama_bindings.dart';

/// Turns text into a vector with an embedding GGUF (cl_embed_load, cl_embed). The model loads on the first call, in its own
/// background isolate, and is let go after [idleFor] without a call (it takes about 700 MB while loaded); the next call loads
/// it again. [warm] loads it ahead of a call, and while [keepLoaded] is true there is no idle release (the app sets it while it
/// holds the model warm in the foreground, and frees the model itself with [free]).
///
/// THE SETTINGS MATCH THE PACK BUILDER (cache_embed in the core): context 512, vectors normalised. The pooling comes from the
/// model's own metadata. A query then gets the same vector here as `places_pack embed` gave the pack's texts.
class CacheEmbedder {
  CacheEmbedder({required this.modelPath, this.threads = 4, this.idleFor = const Duration(minutes: 2)});

  /// Where the GGUF is.
  final String modelPath;
  final int threads;
  final Duration idleFor;

  /// Gets one line per embedding: `Embed: worker M ms, round trip R ms` (the app logs it). Null: not reported.
  void Function(String line)? onTiming;

  /// True: the model is not let go after [idleFor] (only [free] or [dispose] let it go).
  bool keepLoaded = false;

  /// The context length cl_embed_load is given.
  static const int nCtx = 512;

  /// The model id a query vector carries: the GGUF's file name, which is what `places_pack embed` records in the pack as
  /// `embed_model`.
  String get modelId => modelPath.split(RegExp(r'[\\/]')).last;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  ReceivePort? _errors;
  ReceivePort? _exits;
  Completer<void>? _ready;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  Timer? _idle;

  /// The worker's entry point; tests give a stand-in.
  @visibleForTesting
  void Function(SendPort toMain) workerEntry = _embedWorker;

  /// How long [dispose] waits for the worker to say the model is let go before it ends the worker anyway.
  @visibleForTesting
  Duration freeTimeout = const Duration(seconds: 5);

  Future<void> _ensureWorker() async {
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<void>();
    final rp = _fromWorker = ReceivePort();
    rp.listen((dynamic m) {
      if (m is SendPort) {
        _toWorker = m;
        if (!ready.isCompleted) ready.complete();
        return;
      }
      final msg = (m as Map).cast<String, dynamic>();
      _pending.remove(msg['id'])?.complete(msg);
    });
    // A worker that throws or ends (before or after it is ready) fails what waits on it, and the next call starts a new one.
    final errors = _errors = ReceivePort();
    errors.listen((dynamic e) => _lost(ready, 'The embedding engine crashed: ${e is List && e.isNotEmpty ? e.first : e}'));
    final exits = _exits = ReceivePort();
    exits.listen((_) => _lost(ready, 'The embedding engine stopped'));
    try {
      _isolate = await Isolate.spawn(workerEntry, rp.sendPort,
          debugName: 'cache_embed', onError: errors.sendPort, onExit: exits.sendPort, errorsAreFatal: true);
    } catch (e) {
      _lost(ready, 'The embedding engine did not start: $e');
    }
    return ready.future;
  }

  /// The worker of [ready] is gone: what waits on it gets [reason], and the state is cleared so the next call starts a new worker.
  void _lost(Completer<void> ready, String reason) {
    if (!identical(ready, _ready)) return; // an earlier worker, already replaced
    if (!ready.isCompleted) ready.completeError(StateError(reason));
    for (final c in _pending.values) {
      c.complete({'error': reason});
    }
    _pending.clear();
    _idle?.cancel();
    _fromWorker?.close();
    _errors?.close();
    _exits?.close();
    _isolate = null;
    _toWorker = null;
    _fromWorker = null;
    _errors = null;
    _exits = null;
    _ready = null;
  }

  /// Sends [msg] with a new id and waits for the worker's reply.
  Future<Map<String, dynamic>> _call(Map<String, dynamic> msg) async {
    await _ensureWorker();
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _toWorker!.send({...msg, 'id': id});
    return c.future;
  }

  /// The normalised vector of [text]. Throws a [StateError] with the reason when the model cannot load or embed.
  Future<List<double>> embed(String text) async {
    _idle?.cancel();
    final clock = Stopwatch()..start();
    final r = await _call({'type': 'embed', 'path': modelPath, 'threads': threads, 'text': text});
    // Measurement: the round trip here, and the time the worker spent around the native call (sent back in the reply).
    if (r['workerMs'] != null) onTiming?.call('Embed: worker ${r['workerMs']} ms, round trip ${clock.elapsedMilliseconds} ms');
    _armIdle();
    if (r['error'] != null) throw StateError(r['error'] as String);
    return (r['vector'] as TransferableTypedData).materialize().asFloat32List().toList();
  }

  /// Loads the model now, without embedding anything. Throws a [StateError] with the reason when it cannot load.
  Future<void> warm() async {
    _idle?.cancel();
    final r = await _call({'type': 'load', 'path': modelPath, 'threads': threads});
    _armIdle();
    if (r['error'] != null) throw StateError(r['error'] as String);
  }

  void _armIdle() {
    _idle?.cancel();
    if (!keepLoaded && _ready != null) _idle = Timer(idleFor, free);
  }

  /// Lets the model go (the next [embed] loads it again).
  void free() => unawaited(_free());

  /// [free], completing once the worker has let the model go (at once when no worker runs).
  Future<void> _free() async {
    _idle?.cancel();
    if (_toWorker == null) return;
    try {
      await _call({'type': 'free'});
    } on StateError {
      // The worker is gone, and the model with it.
    }
  }

  /// Frees the model, waits (at most [freeTimeout]) until the worker says it is let go, and ends the background isolate.
  Future<void> dispose() async {
    _idle?.cancel();
    final ready = _ready;
    if (_toWorker != null) {
      await _free().timeout(freeTimeout, onTimeout: () {});
    }
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    if (ready != null) _lost(ready, 'The embedding engine was closed');
  }
}

const int _kErr = 512;
const int _kInfo = 4096;

void _embedWorker(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  final b = CacheLlamaBindings.open();
  Pointer<Void> handle = nullptr;
  var nEmbd = 0;
  final err = malloc<Uint8>(_kErr).cast<Utf8>();
  final info = malloc<Uint8>(_kInfo).cast<Utf8>();
  String? loadError;

  // Loads the model when it is not loaded; false (with loadError) when it cannot.
  bool ensureLoaded(Map msg) {
    loadError = null;
    if (handle != nullptr) return true;
    final p = (msg['path'] as String).toNativeUtf8();
    handle = b.clEmbedLoad(p, CacheEmbedder.nCtx, msg['threads'] as int, err, _kErr);
    malloc.free(p);
    if (handle == nullptr) {
      loadError = 'The embedding model did not load: ${err.toDartString()}';
      return false;
    }
    final n = b.clEmbedInfo(handle, info, _kInfo);
    nEmbd = n < 0 ? 0 : ((jsonDecode(info.toDartString()) as Map)['n_embd'] as num).toInt();
    if (nEmbd <= 0) {
      b.clEmbedFree(handle);
      handle = nullptr;
      loadError = 'The embedding model did not say its size';
      return false;
    }
    return true;
  }

  rp.listen((dynamic m) {
    final msg = m as Map;
    switch (msg['type']) {
      case 'load':
        ensureLoaded(msg);
        toMain.send(loadError == null ? {'id': msg['id']} : {'id': msg['id'], 'error': loadError});
      case 'embed':
        final id = msg['id'];
        if (!ensureLoaded(msg)) {
          toMain.send({'id': id, 'error': loadError});
          break;
        }
        final text = (msg['text'] as String).toNativeUtf8();
        final out = malloc<Float>(nEmbd);
        final clock = Stopwatch()..start();
        final n = b.clEmbed(handle, text, out, nEmbd, 1);
        final workerMs = clock.elapsedMilliseconds;
        malloc.free(text);
        if (n != nEmbd) {
          malloc.free(out);
          toMain.send({'id': id, 'error': 'The text could not be embedded (code $n)'});
          break;
        }
        final v = Float32List.fromList(out.asTypedList(nEmbd));
        malloc.free(out);
        toMain.send({'id': id, 'vector': TransferableTypedData.fromList([v]), 'workerMs': workerMs});
      case 'free':
        if (handle != nullptr) {
          b.clEmbedFree(handle);
          handle = nullptr;
        }
        if (msg['id'] != null) toMain.send({'id': msg['id']});
    }
  });
}

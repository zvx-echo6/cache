import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'cache_llama_bindings.dart';

/// Turns text into a vector with an embedding GGUF (cl_embed_load, cl_embed). The model loads on the first call, in its own
/// background isolate, and is let go after [idleFor] without a call (it takes about 700 MB while loaded); the next call loads
/// it again.
///
/// THE SETTINGS MATCH THE PACK BUILDER (cache_embed in the core): context 512, vectors normalised. The pooling comes from the
/// model's own metadata. A query then gets the same vector here as `places_pack embed` gave the pack's texts.
class CacheEmbedder {
  CacheEmbedder({required this.modelPath, this.threads = 4, this.idleFor = const Duration(minutes: 2)});

  /// Where the GGUF is.
  final String modelPath;
  final int threads;
  final Duration idleFor;

  /// The context length cl_embed_load is given.
  static const int nCtx = 512;

  /// The model id a query vector carries: the GGUF's file name, which is what `places_pack embed` records in the pack as
  /// `embed_model`.
  String get modelId => modelPath.split(RegExp(r'[\\/]')).last;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<void>? _ready;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  Timer? _idle;

  Future<void> _ensureWorker() async {
    if (_ready != null) return _ready!.future;
    _ready = Completer<void>();
    final rp = ReceivePort();
    _fromWorker = rp;
    rp.listen((dynamic m) {
      if (m is SendPort) {
        _toWorker = m;
        _ready!.complete();
        return;
      }
      final msg = (m as Map).cast<String, dynamic>();
      _pending.remove(msg['id'])?.complete(msg);
    });
    final errors = ReceivePort();
    errors.listen((dynamic e) {
      for (final c in _pending.values) {
        c.complete({'error': 'The embedding engine crashed: ${(e as List).first}'});
      }
      _pending.clear();
    });
    _isolate = await Isolate.spawn(_embedWorker, rp.sendPort, debugName: 'cache_embed', onError: errors.sendPort);
    return _ready!.future;
  }

  /// The normalised vector of [text]. Throws a [StateError] with the reason when the model cannot load or embed.
  Future<List<double>> embed(String text) async {
    await _ensureWorker();
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _idle?.cancel();
    _toWorker!.send({'type': 'embed', 'id': id, 'path': modelPath, 'threads': threads, 'text': text});
    final r = await c.future;
    _idle = Timer(idleFor, free);
    if (r['error'] != null) throw StateError(r['error'] as String);
    return (r['vector'] as TransferableTypedData).materialize().asFloat32List().toList();
  }

  /// Lets the model go (the next [embed] loads it again).
  void free() {
    _idle?.cancel();
    _toWorker?.send({'type': 'free'});
  }

  /// Frees the model and ends the background isolate.
  Future<void> dispose() async {
    _idle?.cancel();
    _toWorker?.send({'type': 'free'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _fromWorker?.close();
    _isolate = null;
    _toWorker = null;
    _fromWorker = null;
    _ready = null;
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

  rp.listen((dynamic m) {
    final msg = m as Map;
    switch (msg['type']) {
      case 'embed':
        final id = msg['id'];
        if (handle == nullptr) {
          final p = (msg['path'] as String).toNativeUtf8();
          handle = b.clEmbedLoad(p, CacheEmbedder.nCtx, msg['threads'] as int, err, _kErr);
          malloc.free(p);
          if (handle == nullptr) {
            toMain.send({'id': id, 'error': 'The embedding model did not load: ${err.toDartString()}'});
            break;
          }
          final n = b.clEmbedInfo(handle, info, _kInfo);
          nEmbd = n < 0 ? 0 : ((jsonDecode(info.toDartString()) as Map)['n_embd'] as num).toInt();
          if (nEmbd <= 0) {
            b.clEmbedFree(handle);
            handle = nullptr;
            toMain.send({'id': id, 'error': 'The embedding model did not say its size'});
            break;
          }
        }
        final text = (msg['text'] as String).toNativeUtf8();
        final out = malloc<Float>(nEmbd);
        final n = b.clEmbed(handle, text, out, nEmbd, 1);
        malloc.free(text);
        if (n != nEmbd) {
          malloc.free(out);
          toMain.send({'id': id, 'error': 'The text could not be embedded (code $n)'});
          break;
        }
        final v = Float32List.fromList(out.asTypedList(nEmbd));
        malloc.free(out);
        toMain.send({'id': id, 'vector': TransferableTypedData.fromList([v])});
      case 'free':
        if (handle != nullptr) {
          b.clEmbedFree(handle);
          handle = nullptr;
        }
    }
  });
}

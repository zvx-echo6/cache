import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'cache_llama_bindings.dart';
import 'partial_message.dart';

/// Owns one loaded model. All native calls that can take time (load, start, token loop, parse) run
/// in a long-lived background isolate; [stop] calls cl_stop directly (it is thread-safe).
class LlamaSession {
  LlamaSession();

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<void>? _ready;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _loads = {};
  final Map<int, StreamController<PartialMessage>> _gens = {};
  CacheLlamaBindings? _mainBindings; // only used for cl_stop
  int _handleAddress = 0;

  bool get isLoaded => _handleAddress != 0;

  Future<void> _ensureWorker() async {
    if (_ready != null) return _ready!.future;
    _ready = Completer<void>();
    final rp = ReceivePort();
    _fromWorker = rp;
    rp.listen(_onMessage);
    final errors = ReceivePort();
    errors.listen((dynamic e) => _failAll('The model engine crashed: ${(e as List).first}'));
    _isolate = await Isolate.spawn(_workerMain, rp.sendPort, debugName: 'cache_llama', onError: errors.sendPort);
    return _ready!.future;
  }

  void _onMessage(dynamic m) {
    if (m is SendPort) {
      _toWorker = m;
      _ready!.complete();
      return;
    }
    final msg = m as Map;
    final id = msg['id'] as int;
    switch (msg['type']) {
      case 'loaded':
        _loads.remove(id)?.complete(msg.cast<String, dynamic>());
      case 'partial':
        _gens[id]?.add(PartialMessage.fromJson(jsonDecode(msg['json'] as String) as Map<String, dynamic>));
      case 'final':
        final c = _gens.remove(id);
        c?.add(PartialMessage.fromJson(jsonDecode(msg['json'] as String) as Map<String, dynamic>,
            isFinal: true,
            promptTokens: msg['promptTokens'] as int,
            generatedTokens: msg['generatedTokens'] as int));
        c?.close();
      case 'error':
        final c = _gens.remove(id);
        c?.addError(StateError(msg['error'] as String));
        c?.close();
    }
  }

  void _failAll(String why) {
    for (final c in _loads.values) {
      c.complete({'error': why});
    }
    _loads.clear();
    for (final c in _gens.values) {
      c.addError(StateError(why));
      c.close();
    }
    _gens.clear();
    _handleAddress = 0;
  }

  /// Loads the model (replacing a model loaded before). Throws a [StateError] with the reason on failure.
  Future<ModelInfo> load(String path, {int nCtx = 8192}) async {
    await _ensureWorker();
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _loads[id] = c;
    _handleAddress = 0;
    _toWorker!.send({'type': 'load', 'id': id, 'path': path, 'nCtx': nCtx});
    final r = await c.future;
    if (r['error'] != null) throw StateError(r['error'] as String);
    _handleAddress = r['handle'] as int;
    _mainBindings ??= CacheLlamaBindings.open();
    return ModelInfo.fromJson(jsonDecode(r['info'] as String) as Map<String, dynamic>);
  }

  /// Runs one generation. [request] is OpenAI style: {messages: [...], tools: [...]}.
  /// Emits the message parsed so far as tokens arrive, then a final message (isFinal = true).
  /// Cancelling the subscription stops the generation.
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    if (!isLoaded) {
      return Stream.error(StateError('No model is loaded'));
    }
    final id = _nextId++;
    late StreamController<PartialMessage> c;
    c = StreamController<PartialMessage>(onCancel: () {
      if (_gens.containsKey(id)) stop();
    });
    _gens[id] = c;
    _toWorker!.send({'type': 'generate', 'id': id, 'request': jsonEncode(request)});
    return c.stream;
  }

  /// Ends the running generation early (the final message still arrives). Thread-safe.
  void stop() {
    if (_handleAddress != 0) {
      _mainBindings?.clStop(Pointer<Void>.fromAddress(_handleAddress));
    }
  }

  /// Frees the model and ends the background isolate.
  Future<void> dispose() async {
    stop();
    _toWorker?.send({'type': 'free'});
    _handleAddress = 0;
    for (final c in _gens.values) {
      c.close();
    }
    _gens.clear();
    // Let the worker free the handle before it is killed.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _fromWorker?.close();
    _isolate = null;
    _toWorker = null;
    _fromWorker = null;
    _ready = null;
  }
}

// ---------------------------------------------------------------- worker isolate

const int _kErrLen = 512;
const int _kTokenBuf = 1024;
const int _kJsonBuf = 4 * 1024 * 1024;

void _workerMain(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  final b = CacheLlamaBindings.open();
  Pointer<Void> handle = nullptr;
  final err = malloc<Uint8>(_kErrLen).cast<Utf8>();
  final tok = malloc<Uint8>(_kTokenBuf).cast<Utf8>();
  final json = malloc<Uint8>(_kJsonBuf).cast<Utf8>();

  String readJson(int n) => n < 0 ? '{"role":"assistant","content":""}' : json.toDartString();

  rp.listen((dynamic m) {
    final msg = m as Map;
    final id = msg['id'];
    switch (msg['type']) {
      case 'load':
        if (handle != nullptr) {
          b.clFree(handle);
          handle = nullptr;
        }
        final p = (msg['path'] as String).toNativeUtf8();
        // 0 threads: the native layer picks the fast cores itself.
        handle = b.clLoad(p, msg['nCtx'] as int, 0, err, _kErrLen);
        malloc.free(p);
        if (handle == nullptr) {
          toMain.send({'type': 'loaded', 'id': id, 'error': err.toDartString()});
        } else {
          final n = b.clInfo(handle, json, _kJsonBuf);
          toMain.send({'type': 'loaded', 'id': id, 'handle': handle.address, 'info': n < 0 ? '{}' : json.toDartString()});
        }
      case 'generate':
        if (handle == nullptr) {
          toMain.send({'type': 'error', 'id': id, 'error': 'No model is loaded'});
          break;
        }
        final req = (msg['request'] as String).toNativeUtf8();
        final rc = b.clStart(handle, req, err, _kErrLen);
        malloc.free(req);
        if (rc != 0) {
          toMain.send({'type': 'error', 'id': id, 'error': err.toDartString()});
          break;
        }
        var n = 0;
        while ((n = b.clNext(handle, tok, _kTokenBuf)) >= 0) {
          if (n == 0) continue;
          final pn = b.clPartial(handle, json, _kJsonBuf);
          if (pn >= 0) toMain.send({'type': 'partial', 'id': id, 'json': json.toDartString()});
        }
        if (n == -2) {
          toMain.send({'type': 'error', 'id': id, 'error': 'The model stopped with an error while answering'});
          break;
        }
        final fn = b.clFinish(handle, json, _kJsonBuf);
        toMain.send({
          'type': 'final',
          'id': id,
          'json': readJson(fn),
          'promptTokens': b.clPromptTokens(handle),
          'generatedTokens': b.clGeneratedTokens(handle),
        });
      case 'free':
        if (handle != nullptr) {
          b.clFree(handle);
          handle = nullptr;
        }
    }
  });
}

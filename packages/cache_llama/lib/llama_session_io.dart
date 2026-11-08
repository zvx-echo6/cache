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

  /// Where a generation waits on a server; the phone runs the model itself, so it never waits: always null.
  Stream<int?> get queuePosition => const Stream<int?>.empty();

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
            generatedTokens: msg['generatedTokens'] as int,
            reusedTokens: msg['reusedTokens'] as int?,
            startMs: msg['startMs'] as int?,
            firstTokenMs: msg['firstTokenMs'] as int?,
            totalMs: msg['totalMs'] as int?,
            prefixNote: msg['prefixNote'] as String?));
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
  /// [memoryRoomBytes] (Android): what the system can still give the app now (availMem minus threshold); the native layer
  /// repacks the CPU weights only when that leaves room for the copy (see cl_configure), else keeps them in the mmap. Null: not
  /// known (repacked, as before). [prefixDir]: where the fixed prompt start (system prompt and tools) is saved between runs;
  /// null: not saved.
  Future<ModelInfo> load(String path, {int nCtx = 8192, int? memoryRoomBytes, String? prefixDir}) async {
    await _ensureWorker();
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _loads[id] = c;
    _handleAddress = 0;
    _toWorker!.send({
      'type': 'load',
      'id': id,
      'path': path,
      'nCtx': nCtx,
      'options': jsonEncode({'prefix_dir': prefixDir ?? '', 'mem_room_bytes': memoryRoomBytes ?? 0}),
    });
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
    // "max_tokens" caps what one request generates; the worker counts the tokens (the native request ignores the key).
    final max = request['max_tokens'];
    _toWorker!.send({'type': 'generate', 'id': id, 'request': jsonEncode(request), 'maxTokens': max is int && max > 0 ? max : null});
    return c.stream;
  }

  /// Ends the running generation early (the final message still arrives). Thread-safe.
  void stop() {
    if (_handleAddress != 0) {
      _mainBindings?.clStop(Pointer<Void>.fromAddress(_handleAddress));
    }
  }

  /// Frees the model's memory; the background isolate stays for the next [load]. A running generation is stopped first.
  Future<void> unload() async {
    if (_toWorker == null) return;
    stop();
    _handleAddress = 0;
    for (final c in _gens.values) {
      c.close();
    }
    _gens.clear();
    // The worker frees the handle once the stopped generation has ended.
    _toWorker!.send({'type': 'free'});
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
        // The app has one chat model at a time. A model an earlier Flutter engine of this process loaded (Android destroyed
        // the window and made a new one, the process lived on) was never freed: free it before loading, or both stay in
        // memory and Android kills the app.
        final left = b.clFreeAll();
        // ignore: avoid_print
        if (left > 0) print('cache_llama: freed $left model(s) an earlier engine of this process left loaded');
        final options = msg['options'] as String?;
        if (options != null && b.clConfigure != null) {
          final o = options.toNativeUtf8();
          b.clConfigure!(o);
          malloc.free(o);
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
        final clock = Stopwatch()..start();
        final req = (msg['request'] as String).toNativeUtf8();
        final rc = b.clStart(handle, req, err, _kErrLen);
        final startMs = clock.elapsedMilliseconds;
        malloc.free(req);
        if (rc != 0) {
          toMain.send({'type': 'error', 'id': id, 'error': err.toDartString()});
          break;
        }
        final maxTokens = msg['maxTokens'] as int?;
        var n = 0;
        int? firstTokenMs;
        while ((n = b.clNext(handle, tok, _kTokenBuf)) >= 0) {
          firstTokenMs ??= clock.elapsedMilliseconds;
          // The cap: the answer is what was generated up to it (cl_finish parses it as after a stop).
          final capped = maxTokens != null && b.clGeneratedTokens(handle) >= maxTokens;
          if (n > 0) {
            final pn = b.clPartial(handle, json, _kJsonBuf);
            if (pn >= 0) toMain.send({'type': 'partial', 'id': id, 'json': json.toDartString()});
          }
          if (capped) break;
        }
        if (n == -2) {
          toMain.send({'type': 'error', 'id': id, 'error': 'The model stopped with an error while answering'});
          break;
        }
        String? prefixNote;
        if (b.clPrefixNote != null && b.clPrefixNote!(handle, json, _kJsonBuf) > 0) prefixNote = json.toDartString();
        final fn = b.clFinish(handle, json, _kJsonBuf);
        toMain.send({
          'type': 'final',
          'id': id,
          'json': readJson(fn),
          'promptTokens': b.clPromptTokens(handle),
          'generatedTokens': b.clGeneratedTokens(handle),
          'reusedTokens': b.clReusedTokens?.call(handle),
          'startMs': startMs,
          'firstTokenMs': firstTokenMs,
          'totalMs': clock.elapsedMilliseconds,
          'prefixNote': prefixNote,
        });
      case 'free':
        if (handle != nullptr) {
          b.clFree(handle);
          handle = nullptr;
        }
    }
  });
}

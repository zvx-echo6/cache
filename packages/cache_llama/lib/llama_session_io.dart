import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'cache_llama_bindings.dart';
import 'load_options.dart';
import 'partial_message.dart';
import 'warm_result.dart';

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
  final Map<int, Completer<WarmResult>> _warms = {};
  int? _warmId; // the read ahead in flight (not a check)
  bool _warmJoined = false; // a generation was sent behind it
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
      case 'warmed':
        final c = _warms.remove(id);
        var joined = false;
        if (id == _warmId) {
          joined = _warmJoined;
          _warmId = null;
        }
        c?.complete(WarmResult(
          switch (msg['rc'] as int) {
            0 => WarmOutcome.covered,
            1 => WarmOutcome.read,
            2 => WarmOutcome.stopped,
            3 => WarmOutcome.skipped,
            _ => WarmOutcome.failed,
          },
          tokens: msg['tokens'] as int,
          joined: joined,
          error: msg['error'] as String?,
        ));
      case 'error':
        final c = _gens.remove(id);
        c?.addError(msg['contextFull'] == true
            ? ContextFullException(msg['error'] as String)
            : StateError(msg['error'] as String));
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
    _endWarms(why);
    _handleAddress = 0;
  }

  /// Loads the model (replacing a model loaded before). Throws a [StateError] with the reason on failure.
  /// On Android the CPU weights stay file-backed in the mmap; [repackWeights] repacks them instead, for measurement only (see
  /// cl_configure). [prefixDir]: where the fixed prompt start (system prompt and tools) is saved between runs; null: not saved.
  /// [prereadMbps]: the gentle pre-read rate in MB/s after the load (default [kDefaultPrereadMbps]; 0: off).
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = kDefaultPrereadMbps}) async {
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
      'options': llamaLoadOptions(prefixDir: prefixDir, repackWeights: repackWeights, prereadMbps: prereadMbps),
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
    if (_warmId != null) _warmJoined = true; // it waits behind the read ahead and reuses it
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

  /// Reads the prompt start of [request] (a request with no user message, as the app's tool loop builds it for the read ahead) into
  /// the model's cache ahead of the first question, and saves it as a prefix file (cl_warm). [checkOnly]: renders and tokenizes but
  /// decodes nothing, and says whether a read is needed ([WarmOutcome.covered] or [WarmOutcome.read] with the tokens to read).
  /// It runs in the worker isolate in order with the generations: a question sent while it reads waits behind it and then reuses
  /// what it read. It never loads the model: with none, or an older library, it is [WarmOutcome.skipped].
  Future<WarmResult> warm(Map<String, dynamic> request, {bool checkOnly = false}) {
    if (!isLoaded || _toWorker == null) return Future.value(const WarmResult(WarmOutcome.skipped, error: 'no model is loaded'));
    final id = _nextId++;
    final c = Completer<WarmResult>();
    _warms[id] = c;
    if (!checkOnly) {
      _warmId = id;
      _warmJoined = false;
    }
    // The stop epoch as of now, read here on the main isolate as cl_stop is called from here: a stop between this send and the
    // worker's cl_warm (the worker may be busy) is then seen by cl_warm, which reads nothing.
    final epoch = _handleAddress == 0 ? 0 : (_mainBindings?.clStopEpoch?.call(Pointer<Void>.fromAddress(_handleAddress)) ?? 0);
    _toWorker!.send({'type': 'warm', 'id': id, 'request': jsonEncode(request), 'checkOnly': checkOnly, 'epoch': epoch});
    return c.future;
  }

  /// Aborts a read ahead in flight (cl_stop: llama.cpp's abort hook and the check between batches). Not when a question was sent
  /// behind it: the question needs what the read gives, and cl_stop would reach it too. Thread-safe.
  void cancelWarm() {
    if (_warmId != null && !_warmJoined && _handleAddress != 0) {
      _mainBindings?.clStop(Pointer<Void>.fromAddress(_handleAddress));
    }
  }

  void _endWarms(String why) {
    for (final c in _warms.values) {
      c.complete(WarmResult(WarmOutcome.skipped, error: why));
    }
    _warms.clear();
    _warmId = null;
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
    _endWarms('the model was unloaded');
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
    _endWarms('the model was unloaded');
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
          // -3: the prompt does not fit the context (the chat is full); any other code is a plain failure.
          toMain.send({'type': 'error', 'id': id, 'error': err.toDartString(), 'contextFull': rc == -3});
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
      case 'warm':
        final checkOnly = msg['checkOnly'] == true;
        if (handle == nullptr || b.clWarm == null) {
          toMain.send({'type': 'warmed', 'id': id, 'rc': 3, 'tokens': 0, 'checkOnly': checkOnly});
          break;
        }
        final req = (msg['request'] as String).toNativeUtf8();
        final n = malloc<Int32>();
        n.value = 0;
        final rc = b.clWarm!(handle, req, checkOnly ? 1 : 0, msg['epoch'] as int, n, err, _kErrLen);
        final tokens = n.value;
        malloc.free(req);
        malloc.free(n);
        toMain.send({'type': 'warmed', 'id': id, 'rc': rc, 'tokens': tokens, 'checkOnly': checkOnly, 'error': rc < 0 ? err.toDartString() : null});
      case 'free':
        if (handle != nullptr) {
          b.clFree(handle);
          handle = nullptr;
        }
    }
  });
}

// Web build: there is no llama.cpp in a browser. The model runs on the Cache server and this session talks to it over /api/llm v1
// (server/docs/llm-protocol.md), same origin, with the page's cookies. Same public API as llama_session_io.dart. On the web the
// `path` of [load] is the model id the server lists (GET /api/llm/models).
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'llm_remote_events.dart';
import 'partial_message.dart';

class LlamaSession {
  LlamaSession();

  String? _modelId;
  _Run? _run;
  final StreamController<int?> _queue = StreamController<int?>.broadcast();

  bool get isLoaded => _modelId != null;

  /// Where this session's generation waits: how many are ahead of it (1 is next), null when it is running or none waits.
  Stream<int?> get queuePosition => _queue.stream;

  /// Loads the model with this id on the server (replacing the one loaded before; the server has one for all browsers).
  /// Throws a [StateError] with the reason on failure.
  Future<ModelInfo> load(String path, {int nCtx = 8192}) async {
    _modelId = null;
    final r = await _post('/api/llm/load', {'v': 1, 'model': path, 'n_ctx': nCtx});
    final body = await _text(r);
    if (!r.ok) throw StateError(llmErrorMessage(body, 'The server could not load the model (HTTP ${r.status})'));
    final j = jsonDecode(body) as Map<String, dynamic>;
    final result = j['result'];
    if (j['ok'] != true || result is! Map) throw StateError(llmErrorMessage(body, 'The server sent no model information'));
    _modelId = path;
    return ModelInfo.fromJson(result.cast<String, dynamic>());
  }

  /// Runs one generation. [request] is OpenAI style: {messages: [...], tools: [...]}.
  /// Emits the message parsed so far as tokens arrive, then a final message (isFinal = true).
  /// Cancelling the subscription stops the generation.
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    final id = _modelId;
    if (id == null) return Stream.error(StateError('No model is loaded'));
    final run = _Run();
    _run = run;
    late StreamController<PartialMessage> c;
    c = StreamController<PartialMessage>(onCancel: () {
      if (!run.finished) _end(run);
    });
    unawaited(_pump(run, id, request, c));
    return c.stream;
  }

  Future<void> _pump(_Run run, String id, Map<String, dynamic> request, StreamController<PartialMessage> c) async {
    void fail(Object e) {
      if (!c.isClosed) c.addError(e);
    }

    try {
      final r = await _post('/api/llm/generate', {'v': 1, 'model': id, 'request': request}, signal: run.abort.signal);
      if (!r.ok) {
        fail(StateError(llmErrorMessage(await _text(r), 'The server could not start the answer (HTTP ${r.status})')));
        return;
      }
      final body = r.body;
      if (body == null) {
        fail(StateError('The server sent no answer'));
        return;
      }
      var ended = false;
      await for (final e in parseLlmEvents(_chunks(body))) {
        if (c.isClosed) return;
        switch (e) {
          case LlmQueued(:final position):
            _queue.add(position);
          case LlmPartial(:final message):
            run.gotPartial = true;
            _queue.add(null);
            c.add(message);
          case LlmDone(:final message):
            _queue.add(null);
            c.add(message);
            ended = true;
          case LlmError(:final message):
            _queue.add(null);
            fail(StateError(message));
            ended = true;
        }
        if (ended) break;
      }
      if (!ended && !run.aborted) fail(StateError('The connection to the model was cut off'));
    } catch (e) {
      // Our own abort (stop or cancel) is not an error.
      if (!run.aborted) fail(e is StateError ? e : StateError('The connection to the model failed: $e'));
    } finally {
      run.finished = true;
      if (identical(_run, run)) _run = null;
      _queue.add(null);
      if (!c.isClosed) await c.close();
    }
  }

  /// Ends the running generation early. The stream is closed (no final message: the browser has cut the connection).
  void stop() {
    final run = _run;
    if (run != null) _end(run);
  }

  void _end(_Run run) {
    if (run.aborted) return;
    run.aborted = true;
    // Closing the request frees our place or our turn on the server. POST /stop stops whatever runs, so only once a partial
    // proved that this stream is the running one.
    if (run.gotPartial) unawaited(_post('/api/llm/stop', {'v': 1}).then((_) {}, onError: (Object _) {}));
    run.abort.abort();
  }

  /// Forgets the model here. The server keeps its model loaded (it is shared by every browser).
  Future<void> unload() async {
    stop();
    _modelId = null;
  }

  Future<void> dispose() async {
    stop();
    _modelId = null;
    await _queue.close();
  }
}

class _Run {
  final web.AbortController abort = web.AbortController();
  bool gotPartial = false;
  bool aborted = false;
  bool finished = false;
}

Future<web.Response> _post(String path, Map<String, dynamic> body, {web.AbortSignal? signal}) {
  final init = web.RequestInit(
    method: 'POST',
    headers: {'Content-Type': 'application/json'}.jsify() as JSObject,
    body: jsonEncode(body).toJS,
    credentials: 'same-origin',
    signal: signal,
  );
  return web.window.fetch(path.toJS, init).toDart;
}

Future<String> _text(web.Response r) async => (await r.text().toDart).toDart;

/// The response body as it arrives (fetch's ReadableStream; package:http's browser client would hold the whole body back).
Stream<List<int>> _chunks(web.ReadableStream body) async* {
  final reader = body.getReader() as web.ReadableStreamDefaultReader;
  try {
    while (true) {
      final r = await reader.read().toDart;
      if (r.done) break;
      yield (r.value as JSUint8Array).toDart;
    }
  } finally {
    try {
      unawaited(reader.cancel().toDart.then((_) {}, onError: (Object _) {}));
    } catch (_) {}
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/prompt_read_ahead.dart';
import 'package:cache_llama/cache_llama.dart';

/// The native chat layer by hand, for the read ahead's tests: a worker that runs one call at a time in the order they were sent
/// (as the session's worker isolate does), a KV cache of tokens, saved prefix files, and the rules cl_start and cl_warm follow:
///
/// - a "template" renders a request as tokens (the system message, the tools after it, then the messages);
/// - the stable prompt start is what the render shares for two different one-word questions, as the native code finds it;
/// - a read decodes that start in batches, stops between batches when asked (what was decoded stays in the cache) and saves a
///   prefix file only when the whole start was decoded;
/// - a question reuses the cache's common token prefix with its prompt, or a saved file's, and decodes the rest.
///
/// What it cannot show is the real template, tokenizer and llama.cpp: those are covered by the native test tool (cl_prefix) only.
class FakeNativeChat implements ModelBackend, ReadAheadEngine {
  FakeNativeChat({this.batch = 4, this.loaded = true});

  /// Tokens per decoded batch.
  final int batch;
  bool loaded;

  /// The KV cache: the tokens whose keys and values it holds.
  List<String> cached = [];

  /// Saved prefix files (their tokens).
  final List<List<String>> files = [];

  /// How many times each prompt position was decoded (all decodes of the model, read ahead or question).
  final Map<int, int> decodedAt = {};
  int decoded = 0;

  /// The tokens of every request a question sent, and of every read.
  final List<List<String>> questions = [];
  final List<Map<String, dynamic>> questionRequests = [];
  final List<List<String>> reads = [];
  final List<Map<String, dynamic>> warmRequests = [];
  int checks = 0;
  int readCalls = 0;
  int stopCalls = 0;

  /// Runs after each decoded batch of a read (a test holds the read here).
  Future<void> Function(int tokensDecoded)? afterBatch;

  /// Grows with every stop, as cl_stop_epoch does; a read stopped between its queueing and its start reads nothing.
  int stopEpoch = 0;

  /// Holds a read in the worker before it begins (the worker busy with an earlier call).
  Future<void>? holdBeforeRead;

  Future<void> _tail = Future.value();
  bool _stop = false;
  bool _warming = false;
  bool _joined = false;

  /// Tool names of the request, in the rendering. The fake template has the system message first and the tools after it.
  static List<String> render(Map<String, dynamic> request, {List<Map<String, dynamic>>? messages}) {
    final out = <String>['<bos>'];
    final msgs = messages ?? [for (final m in request['messages'] as List) (m as Map).cast<String, dynamic>()];
    for (final m in msgs) {
      if (m['role'] == 'system') {
        out.add('<system>');
        out.addAll('${m['content']}'.split(RegExp(r'\s+')));
        out.add('</system>');
        final tools = request['tools'];
        if (tools is List && tools.isNotEmpty) {
          out.add('<tools>');
          out.addAll(jsonEncode(tools).split(RegExp(r'(?<=[,:{}\[\]])')));
          out.add('</tools>');
        }
      } else {
        out.add('<${m['role']}>');
        out.addAll('${m['content'] ?? ''}'.split(RegExp(r'\s+')));
        out.add('</${m['role']}>');
      }
    }
    return out;
  }

  /// The stable prompt start of a request's shape: the render with two different one-word questions, as far as both agree.
  /// Null: there is none (no tools or no system message).
  static List<String>? stableStart(Map<String, dynamic> request) {
    final msgs = request['messages'] as List;
    final tools = request['tools'];
    if (msgs.isEmpty || (msgs.first as Map)['role'] != 'system' || tools is! List || tools.isEmpty) return null;
    final system = (msgs.first as Map).cast<String, dynamic>();
    final a = render(request, messages: [system, {'role': 'user', 'content': 'a'}]);
    final b = render(request, messages: [system, {'role': 'user', 'content': 'b'}]);
    var n = 0;
    while (n < a.length && n < b.length && a[n] == b[n]) {
      n++;
    }
    return a.sublist(0, n);
  }

  static int _common(List<String> a, List<String> b, [int? limit]) {
    var n = 0;
    final lim = [a.length, b.length, ?limit].reduce((x, y) => x < y ? x : y);
    while (n < lim && a[n] == b[n]) {
      n++;
    }
    return n;
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final r = _tail.then((_) => op());
    _tail = r.then((_) {}, onError: (_) {});
    return r;
  }

  int _fileBest(List<String> tokens) => files.fold(0, (m, f) {
        final c = _common(f, tokens);
        return c > m ? c : m;
      });

  // ---- ReadAheadEngine

  @override
  bool get isLoaded => loaded;

  /// Set by the test to what the chat says (busy).
  @override
  bool questionRunning = false;

  @override
  Future<WarmResult> warm(Map<String, dynamic> request, {bool checkOnly = false}) {
    if (!checkOnly) {
      _warming = true;
      _joined = false;
    }
    final epoch = stopEpoch; // read when it is queued, as the session does
    return _enqueue(() async {
      if (!checkOnly) await holdBeforeRead;
      if (epoch != stopEpoch) {
        if (!checkOnly) _warming = false;
        return const WarmResult(WarmOutcome.stopped);
      }
      final tokens = stableStart(request);
      if (!loaded || tokens == null) {
        if (!checkOnly) _warming = false;
        return const WarmResult(WarmOutcome.skipped);
      }
      final inMem = _common(cached, tokens);
      final best = _fileBest(tokens);
      if (inMem >= tokens.length || best >= tokens.length) {
        if (!checkOnly) _warming = false;
        return const WarmResult(WarmOutcome.covered);
      }
      final have = inMem > best ? inMem : best;
      if (checkOnly) {
        checks++;
        return WarmResult(WarmOutcome.read, tokens: tokens.length - have);
      }
      readCalls++;
      warmRequests.add(request);
      reads.add(tokens);
      _stop = false;
      if (best > inMem) cached = tokens.sublist(0, best);
      var i = cached.length > have ? have : cached.length;
      cached = cached.sublist(0, i);
      final from = i;
      while (i < tokens.length) {
        if (_stop) {
          _warming = false;
          return WarmResult(WarmOutcome.stopped, tokens: i - from, joined: _joined);
        }
        final n = (tokens.length - i) < batch ? tokens.length - i : batch;
        for (var k = i; k < i + n; k++) {
          decodedAt[k] = (decodedAt[k] ?? 0) + 1;
        }
        decoded += n;
        cached = [...cached, ...tokens.sublist(i, i + n)];
        i += n;
        await afterBatch?.call(i);
      }
      files.add(tokens);
      final joined = _joined;
      _warming = false;
      return WarmResult(WarmOutcome.read, tokens: i - from, joined: joined);
    });
  }

  @override
  void cancelWarm() {
    if (_warming && !_joined) {
      stopCalls++;
      stopEpoch++;
      _stop = true;
    }
  }

  // ---- ModelBackend

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    if (_warming) _joined = true;
    questionRequests.add(request);
    final c = StreamController<PartialMessage>();
    _enqueue(() async {
      final tokens = render(request);
      questions.add(tokens);
      var keep = _common(cached, tokens, tokens.length - 1);
      final best = _fileBest(tokens);
      if (best > keep) keep = best;
      cached = tokens.sublist(0, keep);
      for (var k = keep; k < tokens.length; k++) {
        decodedAt[k] = (decodedAt[k] ?? 0) + 1;
      }
      decoded += tokens.length - keep;
      cached = [...tokens, 'ok'];
      c.add(PartialMessage(isFinal: true, content: 'ok', promptTokens: tokens.length, reusedTokens: keep));
      await c.close();
    });
    return c.stream;
  }

  @override
  void stop() {
    stopEpoch++;
    _stop = true;
  }
}

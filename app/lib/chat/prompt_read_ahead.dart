import 'dart:async';

import 'package:cache_llama/cache_llama.dart';

import '../platform/app_log.dart';
import 'chat_location.dart';

/// How long the read ahead waits for the phone's position before it starts (location on and allowed, no fix yet): the prompt names
/// whether the position is known, and a read made with the other answer is read again by the first question.
const Duration kReadAheadFixWait = Duration(seconds: 10);

/// What the read ahead needs of the model engine. The phone's is [LocalReadAhead] over the native session.
abstract class ReadAheadEngine {
  /// The chat model is in memory. The read ahead never loads it.
  bool get isLoaded;

  /// A question is being answered now (the chat is busy): it comes first, and a read not begun is not begun.
  bool get questionRunning;

  /// Reads the prompt start of [request] (see [LlamaSession.warm]); [checkOnly]: only says whether a read is needed.
  Future<WarmResult> warm(Map<String, dynamic> request, {bool checkOnly = false});

  /// Aborts a read in flight (the native stop). Thread-safe.
  void cancelWarm();
}

/// The phone's engine: the native session, with the loaded model's own request settings put into the request as a question's are.
class LocalReadAhead implements ReadAheadEngine {
  LocalReadAhead(this.session, {this.extras, this.busy});

  final LlamaSession session;
  final Map<String, dynamic> Function()? extras;
  /// The chat is answering a question now.
  final bool Function()? busy;

  @override
  bool get isLoaded => session.isLoaded;

  @override
  bool get questionRunning => busy?.call() ?? false;

  @override
  Future<WarmResult> warm(Map<String, dynamic> request, {bool checkOnly = false}) {
    final e = extras?.call();
    return session.warm(e == null || e.isEmpty ? request : {...e, ...request}, checkOnly: checkOnly);
  }

  @override
  void cancelWarm() => session.cancelWarm();
}

/// Reads the start of the chat prompt (the system prompt and the tool schemas, which the chat template renders before any question)
/// into the model's cache while Ask is shown, so the first question of a day, whose date changes that start, does not read it
/// itself (about 1,900 tokens, 76 s on a Pixel 8).
///
/// Nothing the model sees changes: the request comes from the chat's own request builder ([ChatController.warmRequest]) and the
/// engine reads it with the code the first question's start uses (cl_warm). The person sees nothing of it.
///
/// - One read per opening of Ask ([start]); one in flight is never restarted, whatever changes in the prompt meanwhile.
/// - Never loads the model and does not pass the memory gate: no model, no read.
/// - A hot device ([IndexThrottle.hot], the same signal that holds index work) skips it.
/// - With the position on its way it waits up to [kReadAheadFixWait] for it first.
/// - A question sent meanwhile queues behind the read in the engine and reuses it ([WarmResult.joined]).
/// - Cache going to the back aborts it ([toBackground]); leaving Ask with Cache in front does not.
class PromptReadAhead {
  PromptReadAhead({
    required this.engine,
    required this.request,
    this.isHot,
    this.waitForFix,
    this.fixWait = kReadAheadFixWait,
  });

  final ReadAheadEngine engine;

  /// The request to read ([ChatController.warmRequest]); null: nothing to read. [isCancelled] turns true when the read is given up.
  final Future<Map<String, dynamic>?> Function(bool Function() isCancelled) request;

  /// The device is too hot for background work ([IndexThrottle.hot], after a fresh reading); null: never.
  final Future<bool> Function()? isHot;

  /// Waits for the phone's position ([ChatLocation.waitForFix]); null: no waiting.
  final Future<FixWait> Function(Duration timeout)? waitForFix;
  final Duration fixWait;

  _Read? _current;

  /// A read (or its preparation) is in flight.
  bool get reading => _current != null;

  /// Ask is shown with the model loaded (after the model's wake): reads the prompt start ahead unless it is covered already, one
  /// read at most per opening. Returns when the read has ended (every outcome is logged, never thrown).
  Future<void> start() async {
    if (_current != null) {
      _skip('a read is already running');
      return;
    }
    final read = _current = _Read();
    try {
      await _run(read);
    } catch (e) {
      _skip('error: $e');
    } finally {
      if (identical(_current, read)) _current = null;
    }
  }

  /// Cache went to the background: a read in flight is given up (the native stop aborts the one decoding). The model's release
  /// after its grace period then applies as built.
  void toBackground() {
    final read = _current;
    if (read == null) return;
    read.cancelled = true;
    if (read.decoding) engine.cancelWarm();
  }

  Future<void> _run(_Read read) async {
    if (!engine.isLoaded) return _skip('no model is loaded');
    if (engine.questionRunning) return _skip('a question is already running');
    if (await (isHot?.call() ?? Future.value(false))) return _skip('device hot');
    if (read.cancelled) return _skip('Cache went to the background');

    final wait = waitForFix;
    if (wait != null) {
      final clock = Stopwatch()..start();
      // Logged only when there is something to wait for (the answer comes at once when location is off, denied or already known).
      final r = await wait(fixWait);
      if (r != FixWait.none) {
        final s = (clock.elapsedMilliseconds / 100).round() / 10;
        logInfo(r == FixWait.arrived
            ? 'Prompt read ahead: waited $s s for the location fix, it arrived'
            : 'Prompt read ahead: waited $s s for the location fix, none came; reading with the location not known');
      }
    }
    if (read.cancelled) return _skip('Cache went to the background');
    if (!engine.isLoaded) return _skip('no model is loaded');
    if (engine.questionRunning) return _skip('a question is already running');

    final req = await request(() => read.cancelled);
    if (read.cancelled) return _skip('Cache went to the background');
    if (req == null) return _skip('no request to read');
    if (!engine.isLoaded) return _skip('no model is loaded');

    final check = await engine.warm(req, checkOnly: true);
    switch (check.outcome) {
      case WarmOutcome.covered:
        return _skip('already read');
      case WarmOutcome.skipped:
        return _skip('nothing to read${check.error == null ? '' : ' (${check.error})'}');
      case WarmOutcome.failed:
        return _skip('check failed (${check.error})');
      case WarmOutcome.stopped:
        return _skip('stopped');
      case WarmOutcome.read:
        break;
    }
    if (read.cancelled) return _skip('Cache went to the background');

    logInfo('Prompt read ahead: started (${check.tokens} tokens)');
    final clock = Stopwatch()..start();
    read.decoding = true;
    final WarmResult res;
    try {
      res = await engine.warm(req);
    } finally {
      read.decoding = false;
    }
    final s = (clock.elapsedMilliseconds / 100).round() / 10;
    switch (res.outcome) {
      case WarmOutcome.read:
        logInfo('Prompt read ahead: done, ${res.tokens} tokens in $s s (a question joined: ${res.joined ? 'yes' : 'no'})');
      case WarmOutcome.covered:
        logInfo('Prompt read ahead: done, 0 tokens in $s s (a question joined: ${res.joined ? 'yes' : 'no'})');
      case WarmOutcome.stopped:
        _skip('stopped after ${res.tokens} of ${check.tokens} tokens');
      case WarmOutcome.failed:
        _skip('failed (${res.error})');
      case WarmOutcome.skipped:
        _skip('nothing to read${res.error == null ? '' : ' (${res.error})'}');
    }
  }

  void _skip(String why) => logInfo('Prompt read ahead: skipped ($why)');
}

class _Read {
  bool cancelled = false;

  /// The engine is decoding (the native stop reaches it); before that there is nothing to stop.
  bool decoding = false;
}

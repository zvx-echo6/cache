import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/app_log.dart';

/// While Ask answers, Cache's own background work (notebook and settings sync, region and model downloads, indexing) holds off
/// starting new units, so the phone's memory, storage and CPU go to the answer. [ChatController] calls [begin] when an answer starts
/// generating and [end] when it finishes, fails or is cancelled; calls nest (the count is kept), and the focus is on while any is
/// open. A worker that observes this registers its [name] (for the log), asks [idle] before it starts its next unit (the next file,
/// chunk, folder or batch) and carries on where it left off when the focus ends. A unit already running is never interrupted.
///
/// Not for Ask's own work (search and read tools, the warm search model): those are part of the answer and never wait here.
class AskFocus extends ChangeNotifier {
  AskFocus({void Function(String line)? log, Stopwatch Function()? stopwatch})
      : _log = log ?? ((line) => logInfo(line)),
        _stopwatch = stopwatch ?? Stopwatch.new;

  final void Function(String line) _log;
  final Stopwatch Function() _stopwatch;

  /// Test builds only, set by the app when the bench asks for it: drops the image and tile caches as a focus begins. Returns the
  /// words to log (what was dropped), or null.
  Future<String?> Function()? dropCaches;

  int _depth = 0;
  Completer<void>? _off;
  Stopwatch? _clock;
  final Map<String, int> _workers = {};
  final Set<String> _waited = {};

  /// Whether an answer is being generated right now.
  bool get focused => _depth > 0;

  /// How many [begin] calls are open.
  int get depth => _depth;

  /// The names of the workers that observe this focus, for the log.
  List<String> get workers => _workers.keys.toList()..sort();

  /// The workers that waited in [idle] during the focus now on or the last one.
  List<String> get waited => _waited.toList()..sort();

  /// Registers a worker by [name] (a worker with several parts registers each once). Returns the call that takes it off again.
  VoidCallback register(String name) {
    _workers[name] = (_workers[name] ?? 0) + 1;
    var done = false;
    return () {
      if (done) return;
      done = true;
      final n = (_workers[name] ?? 1) - 1;
      if (n <= 0) {
        _workers.remove(name);
      } else {
        _workers[name] = n;
      }
    };
  }

  /// An answer starts generating. Every [begin] needs one [end].
  void begin() {
    _depth++;
    if (_depth != 1) return;
    _off = Completer<void>();
    _clock = _stopwatch()..start();
    _waited.clear();
    _log('Ask focus: on, held: ${workers.isEmpty ? 'none' : workers.join(', ')}');
    final drop = dropCaches;
    if (drop != null) {
      unawaited(() async {
        try {
          final what = await drop();
          if (what != null) _log('Ask focus: $what');
        } catch (e) {
          _log('Ask focus: caches not dropped ($e)');
        }
      }());
    }
    notifyListeners();
  }

  /// The answer finished, failed or was cancelled. An [end] with no open [begin] does nothing.
  void end() {
    if (_depth == 0) return;
    _depth--;
    if (_depth != 0) return;
    final ms = _clock?.elapsedMilliseconds ?? 0;
    _clock = null;
    final off = _off;
    _off = null;
    _log('Ask focus: off after $ms ms');
    off?.complete();
    notifyListeners();
  }

  /// Returns at once when no answer is being generated; otherwise waits until it is done. A worker awaits this before it starts its
  /// next unit. With [maxWait], it returns after that long even while the focus is on (a download that must not let its connection
  /// go quiet for long). [worker] names the caller for the log.
  Future<void> idle({String? worker, Duration? maxWait}) async {
    while (true) {
      final off = _off;
      if (off == null) return;
      if (worker != null) _waited.add(worker);
      if (maxWait == null) {
        await off.future;
      } else {
        var timedOut = false;
        await Future.any<void>([off.future, Future<void>.delayed(maxWait).then((_) => timedOut = true)]);
        if (timedOut) return;
      }
    }
  }
}

/// The longest a download holds its stream at a time while Ask answers (see ZimDownloader).
const Duration kAskHoldMax = Duration(seconds: 20);

/// The app's one focus, set at start (like the index throttle); null in tests that do not need one, where [askIdle] returns at once.
AskFocus? askFocusShared;

/// What a background worker awaits before it starts its next unit.
Future<void> askIdle({String? worker, Duration? maxWait}) => askFocusShared?.idle(worker: worker, maxWait: maxWait) ?? Future<void>.value();

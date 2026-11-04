import 'dart:async';

import 'package:cache_search/cache_search.dart' show CacheSearchException;

import '../../platform/app_log.dart';
import '../../platform/memory.dart';

/// Records both sides of an awaited operation. Waiting messages do not count as
/// progress: a blocked operation must still be caught by the index watchdog.
Future<T> tracePdfOperation<T>(
  String step,
  Future<T> Function() action, {
  String? job,
  bool Function()? alive,
  Set<Timer>? timers,
  Duration pendingEvery = const Duration(seconds: 30),
  Future<String> Function()? memory,
}) async {
  final elapsed = Stopwatch()..start();
  logInfo('PDF $step starts; ${memoryNow()}', job: job);
  var sampling = false;
  Future<void> sample() async {
    if (sampling || (alive != null && !alive())) return;
    sampling = true;
    try {
      final reading = await (memory ?? memorySnapshot)().timeout(const Duration(seconds: 2));
      if (alive == null || alive()) {
        logInfo('PDF $step memory at ${elapsed.elapsedMilliseconds} ms: $reading', job: job);
      }
    } catch (error) {
      logDetail('PDF $step memory probe failed: $error', job: job);
    } finally {
      sampling = false;
    }
  }

  unawaited(sample());
  final pending = Timer.periodic(pendingEvery, (timer) {
    if (alive != null && !alive()) {
      timer.cancel();
      return;
    }
    logInfo('PDF $step still waiting after ${elapsed.elapsedMilliseconds} ms', job: job);
    unawaited(sample());
  });
  timers?.add(pending);
  try {
    final result = await action();
    logInfo('PDF $step done in ${elapsed.elapsedMilliseconds} ms; ${memoryNow()}', job: job);
    return result;
  } catch (error, stack) {
    final code = error is CacheSearchException ? ' (${error.code})' : '';
    logError('PDF $step failed$code after ${elapsed.elapsedMilliseconds} ms', error: error, stack: stack, job: job);
    rethrow;
  } finally {
    pending.cancel();
    timers?.remove(pending);
  }
}

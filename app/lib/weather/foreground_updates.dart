import 'dart:async';

import '../platform.dart' as plat;

/// Whether the app updates weather and alerts by itself while it is in front. Android's scheduled job (WorkManager, see
/// weather/background.dart) runs whether Cache is in front or not, so there it is the only one and this stays off. Everywhere
/// else nothing scheduled runs for an app in front: an iPhone's background refresh does not run for the app on the screen, and
/// off phones there is no scheduled job at all.
bool foregroundUpdatesWanted({bool? android}) => !(android ?? plat.isAndroid);

/// The update that runs while the app is left open in front: every [every] (the interval of the background schedule), the same
/// update a background run makes ([update]), while something is switched on ([on]). Someone who drives for hours with Cache on
/// the screen got no new alerts: updates started only when the app opened or came back to the front, by the system's scheduled
/// job, or when "Where I am" settled somewhere new.
///
/// [front] starts it (the app is in front), [back] stops it (the app left the front); starting again when it runs changes
/// nothing. One update at a time: a tick that finds the last one still running does nothing.
class ForegroundUpdates {
  ForegroundUpdates({required this.every, required this.on, required this.update, this.wanted = true});

  final Duration every;

  /// Whether there is anything to update (a source is switched on): what also decides whether the background job is scheduled.
  final bool Function() on;

  /// The update: the weather part's own, with its own limits (the connection, each source's refresh time and quota, one at a time).
  final Future<void> Function() update;

  /// False where a scheduled job already updates while the app is in front ([foregroundUpdatesWanted]): then nothing ever starts.
  final bool wanted;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  /// The app is in front and the updates are timed.
  bool get ticking => _timer != null;

  void front() {
    if (!wanted || _disposed || _timer != null) return;
    _timer = Timer.periodic(every, (_) => unawaited(_tick()));
  }

  void back() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_running || _disposed || !on()) return;
    _running = true;
    try {
      await update();
    } catch (_) {
      // an update that fails says so itself (the status line, the log); the next one comes with the next tick
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    back();
  }
}

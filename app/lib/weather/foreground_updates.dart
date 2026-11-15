import 'dart:async';

import '../platform.dart' as plat;

/// Whether the app updates weather and alerts by itself while it is in front. Android's scheduled job (WorkManager, see
/// weather/background.dart) runs whether Cache is in front or not, so there it is the only one and this stays off. Everywhere
/// else nothing scheduled runs for an app in front: an iPhone's background refresh does not run for the app on the screen, and
/// off phones there is no scheduled job at all.
bool foregroundUpdatesWanted({bool? android}) => !(android ?? plat.isAndroid);

/// How often the app in front checks whether weather is due: five minutes. Each tick asks [ForegroundUpdates.update], which is the
/// due check (`updateIfDue`: it updates only when the last good update is older than the background schedule's interval), so a tick
/// that is not due does nothing and costs no fetch. Weather is then updated within five minutes of falling due, also when Cache
/// starts a little before it is due (a start 29 minutes after the last run used to wait a whole interval for the first tick).
const Duration kForegroundTick = Duration(minutes: 5);

/// The update that runs while the app is left open in front: every [every] ([kForegroundTick]) it makes the update that is due
/// ([update], the same as a background run), while something is switched on ([on]). Someone who drives for hours with Cache on
/// the screen got no new alerts: updates started only when the app opened or came back to the front, by the system's scheduled
/// job, or when "Where I am" settled somewhere new.
///
/// Two things hold it: the phone's own screen in front ([front], [back]) and a car screen attached ([car]). With a car on
/// CarPlay or Android Auto the phone's screen stays in the back, so the car counts as showing the app. It runs while either
/// holds it and stops when neither does; starting again when it runs changes nothing. One update at a time: a tick that finds the last one still running does nothing.
class ForegroundUpdates {
  ForegroundUpdates({required this.every, required this.on, required this.update, this.wanted = true});

  final Duration every;

  /// Whether there is anything to update (a source is switched on): what also decides whether the background job is scheduled.
  final bool Function() on;

  /// The update: the weather part's own due check and update (`updateIfDue`), with its own limits (the connection, each source's
  /// refresh time and quota, one at a time). Called at every tick; it does nothing when no update is due.
  final Future<void> Function() update;

  /// False where a scheduled job already updates while the app is in front ([foregroundUpdatesWanted]): then nothing ever starts.
  final bool wanted;

  Timer? _timer;
  bool _phone = false;
  bool _car = false;
  bool _running = false;
  bool _disposed = false;

  /// The app is in front and the updates are timed.
  bool get ticking => _timer != null;

  /// The phone's screen is in front.
  void front() {
    _phone = true;
    _sync();
  }

  /// The phone's screen left the front; the timer goes on while a car is attached.
  void back() {
    _phone = false;
    _sync();
  }

  /// A car screen is attached ([attached] true) or gone; the timer goes on while the phone's screen is in front.
  void car(bool attached) {
    _car = attached;
    _sync();
  }

  void _sync() {
    if (!wanted || _disposed || !(_phone || _car)) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(every, (_) => unawaited(_tick()));
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
    _sync();
  }
}

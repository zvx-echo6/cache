/// Times the launch screen: from the start of the app until both the app (its settings and models list read) and the search
/// core are ready, which is when the screen lifts. One log line says how long that took and which of the two it waited on.
class LaunchClock {
  LaunchClock(this._write, {Stopwatch? watch}) : _watch = watch ?? Stopwatch();

  final void Function(String line) _write;
  final Stopwatch _watch;
  int? _appMs;
  int? _coreMs;
  bool _logged = false;

  /// The app has started (call as early as possible: this is the clock's zero).
  void begin() => _watch
    ..reset()
    ..start();

  /// The app's own state is ready (the first of these counts).
  void appReady() {
    _appMs ??= _watch.elapsedMilliseconds;
    _done();
  }

  /// The search core has finished starting, opened or failed (the first of these counts).
  void coreReady() {
    _coreMs ??= _watch.elapsedMilliseconds;
    _done();
  }

  void _done() {
    final app = _appMs, core = _coreMs;
    if (_logged || app == null || core == null) return;
    _logged = true;
    final total = app > core ? app : core;
    _write('Launch screen: ${_s(total)} s (app ready at ${_s(app)} s, core ready at ${_s(core)} s)');
  }

  static String _s(int ms) => (ms / 1000).toStringAsFixed(1);
}

import 'dart:io';
import 'dart:io' as io show pid;

/// The work the app and a background run can both do, by name: adding PDFs (Add PDF's jobs and the watched folders' checks
/// that queue them). A background run of it never runs while the app is open, and the app stops a background run of it before
/// doing it itself.
const String kAddPdfWork = 'pdf-add';

/// The one lock between the app and the background runs (WorkManager's engine, which may run in the app's own process while
/// the app is in the background, or in a process of its own). Small files in `<support>/background/`:
/// - `app-open`: the app is open (the time, written when it comes to the front and every [refreshEvery] while it is);
/// - `run-<work>`: a background run is doing that work (the time, refreshed while it runs);
/// - `stop-<work>`: the app asks that run to stop (it does at its next check, keeping what is done);
/// - `generation`: a count every background run adds one to, so the app knows to read its kept state again.
/// A time older than [fresh] is stale (a run or an app that was killed): it no longer holds anything.
class BackgroundLock {
  BackgroundLock(this.dir, {DateTime Function()? clock, this.fresh = const Duration(minutes: 2), int? pid}) : _clock = clock ?? DateTime.now, _pid = pid ?? io.pid;

  final int _pid;

  final Directory dir;
  final Duration fresh;
  final DateTime Function() _clock;

  /// How often the holder writes its time again.
  static const Duration refreshEvery = Duration(seconds: 30);

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  /// A run's file is its time, and on a second line the process that wrote it: a run whose process is gone (Cache was force-stopped
  /// while the service ran: Android 15 emulator, 2026-11-14) holds nothing, and need not be waited for until its time is stale.
  bool _isFresh(String name, {bool alive = false}) {
    try {
      final f = _file(name);
      if (!f.existsSync()) return false;
      final lines = f.readAsStringSync().trim().split('\n');
      final t = DateTime.tryParse(lines.first.trim());
      if (t == null || _clock().difference(t) >= fresh) return false;
      if (alive && lines.length > 1 && !_processAlive(int.tryParse(lines[1].trim()))) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether [pid] is a process now. Where the process list cannot be read (not Linux or Android), it is taken as alive: the
  /// time alone decides, as before.
  bool _processAlive(int? pid) {
    if (pid == null || pid == _pid) return true;
    if (!(Platform.isAndroid || Platform.isLinux)) return true;
    try {
      return Directory('/proc/$pid').existsSync();
    } catch (_) {
      return true;
    }
  }

  void _touch(String name, {bool withProcess = false}) {
    try {
      dir.createSync(recursive: true);
      _file(name).writeAsStringSync(withProcess ? '${_clock().toIso8601String()}\n$_pid' : _clock().toIso8601String(), flush: true);
    } catch (_) {}
  }

  void _delete(String name) {
    try {
      final f = _file(name);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ---- the app

  /// The app came to the front, or is still there (called every [refreshEvery] while it is).
  void appOpened() => _touch('app-open');

  /// The app went to the back: background runs may go ahead.
  void appClosed() => _delete('app-open');

  bool get appOpen => _isFresh('app-open');

  /// A background run is doing [work] now.
  bool runs(String work) => _isFresh('run-$work', alive: true);

  /// The app is about to do [work]: a background run of it is asked to stop. True when none runs, now or within [wait].
  Future<bool> takeOver(String work, {Duration wait = const Duration(seconds: 30), Duration look = const Duration(milliseconds: 250)}) async {
    if (!runs(work)) {
      _delete('stop-$work');
      return true;
    }
    _touch('stop-$work');
    final end = _clock().add(wait);
    while (runs(work) && _clock().isBefore(end)) {
      await Future<void>.delayed(look);
    }
    final free = !runs(work);
    if (free) _delete('stop-$work');
    return free;
  }

  /// The count of background runs so far (see [hold]).
  int get generation {
    try {
      final f = _file('generation');
      return f.existsSync() ? int.tryParse(f.readAsStringSync().trim()) ?? 0 : 0;
    } catch (_) {
      return 0;
    }
  }

  // ---- a background run

  /// A background run may do [work]: the app is not open and no other run does it. True: the run holds it (and the generation
  /// goes up) until [release].
  bool hold(String work) {
    if (appOpen || runs(work)) return false;
    _delete('stop-$work');
    _touch('run-$work', withProcess: true);
    try {
      dir.createSync(recursive: true);
      _file('generation').writeAsStringSync('${generation + 1}', flush: true);
    } catch (_) {}
    return true;
  }

  /// The run is still going: its time again.
  void refresh(String work) => _touch('run-$work', withProcess: true);

  /// The app asked the run to stop, or came to the front.
  bool stopAsked(String work) => appOpen || _file('stop-$work').existsSync();

  void release(String work) {
    _delete('run-$work');
    _delete('stop-$work');
  }
}

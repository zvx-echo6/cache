import 'dart:io';
import 'dart:io' as io show pid;

/// The work the app and a background run can both do, by name: adding PDFs (Add PDF's jobs and the watched folders' checks
/// that queue them). A background run of it never runs while the app is open, and the app stops a background run of it before
/// doing it itself.
const String kAddPdfWork = 'pdf-add';

/// The sync work: a background round with the linked devices (background/sync_background.dart). The app's own sync engine and a
/// background round never run together (the sync engine's store and identity belong to one engine at a time): the app writes
/// `engine-sync` while its engine runs, and a background round holds `run-sync`.
const String kSyncWork = 'sync';

/// The one lock between the app and the background runs (WorkManager's engine, which may run in the app's own process while
/// the app is in the background, or in a process of its own). Small files in `<support>/background/`:
/// - `app-open`: the app is open (the time, written when it comes to the front and every [refreshEvery] while it is);
/// - `run-<work>`: a background run is doing that work (the time, refreshed while it runs);
/// - `stop-<work>`: the app asks that run to stop (it does at its next check, keeping what is done);
/// - `generation`: a count every background run adds one to, so the app knows to read its kept state again.
/// A time older than [fresh] is stale (a run or an app that was killed): it no longer holds anything.
class BackgroundLock {
  BackgroundLock(this.dir, {DateTime Function()? clock, this.fresh = const Duration(minutes: 2), this.engineFresh = const Duration(minutes: 5), int? pid})
    : _clock = clock ?? DateTime.now,
      _pid = pid ?? io.pid;

  final int _pid;

  final Directory dir;
  final Duration fresh;

  /// How long the app's engine mark holds without being written again (the app's timers may be held back while it is in the
  /// background, so it is longer than [fresh]).
  final Duration engineFresh;
  final DateTime Function() _clock;

  /// How often the holder writes its time again.
  static const Duration refreshEvery = Duration(seconds: 30);

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  /// A mark's file is its time, and on a second line the process that wrote it (every mark a holder writes: `run-<work>` for every
  /// work, `engine-<work>`): a holder whose process is gone (Cache was force-stopped while the service ran: Android 15 emulator,
  /// 2026-11-14) holds nothing, and need not be waited for until its time is stale. [within]: how old the time may be (default
  /// [fresh]); [alive]: also needs the writing process to be there, where the file names one. `app-open` names none.
  bool _isFresh(String name, {Duration? within, bool alive = false}) {
    try {
      final f = _file(name);
      if (!f.existsSync()) return false;
      final lines = f.readAsStringSync().trim().split('\n');
      final t = DateTime.tryParse(lines.first.trim());
      if (t == null || _clock().difference(t) >= (within ?? fresh)) return false;
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

  /// The app's own engine for [work] runs (it may do so with the app in the background, after [appClosed]): a background run of
  /// [work] does not start. Written again every [refreshEvery] while it runs.
  void engineStarted(String work) => _touch('engine-$work', withProcess: true);

  /// The app's engine for [work] has stopped.
  void engineStopped(String work) => _delete('engine-$work');

  bool engineRuns(String work) => _isFresh('engine-$work', within: engineFresh, alive: true);

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

  /// The app is back at the front and had last seen generation [seen]: when a background run has happened since, each of [reads]
  /// (what the app keeps: Add PDF's jobs, the watched folders, the libraries and the search index work) runs, in order, so the app
  /// shows and searches what the run did. A read that throws is skipped (the next one still runs). Returns the generation now,
  /// for the caller to keep as the next [seen].
  Future<int> catchUp(int seen, List<Future<void> Function()> reads) async {
    final g = generation;
    if (g == seen) return seen;
    for (final r in reads) {
      try {
        await r();
      } catch (_) {}
    }
    return g;
  }

  // ---- a background run

  /// A background run may do [work]: the app is not open, its own engine for [work] does not run and no other run does it.
  /// True: the run holds it (and the generation goes up, unless [bump] is false: a run that changes nothing the app keeps in
  /// state) until [release].
  bool hold(String work, {bool bump = true}) {
    if (appOpen || runs(work) || engineRuns(work)) return false;
    _delete('stop-$work');
    _touch('run-$work', withProcess: true);
    if (!bump) return true;
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

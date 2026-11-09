import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/battery.dart';
import '../settings/space.dart';
import '../platform/memory.dart';
import 'index_status.dart' show indexStatusLine;
import 'index_throttle.dart';
import '../platform/app_log.dart';

/// The app's one index scheduler, set at start; null in tests that do not need it (the Library then shows only what the PDF
/// state says).
IndexScheduler? indexSchedulerShared;

/// Work listed again this soon after it finished counts as a repeat; more than two repeats in a row and it is stuck.
const Duration kIndexRedoWithin = Duration(seconds: 15);

/// Running work with no progress at all for this long is stuck (see [IndexScheduler.stuckAfter]).
const Duration kIndexStuckAfter = Duration(minutes: 5);

/// One piece of automatic index work: build a source's index (the core's `index_source`), seal an index built before snapshots
/// (`index_seal`), or make a ZIM's PDFs searchable (the PDF loop). [key] is `<kind>/<source id>`, the same folder the
/// snapshot goes to.
class IndexTask {
  const IndexTask({
    required this.key,
    required this.start,
    this.size = 0,
    this.uses = 0,
    this.long = true,
    this.bytesNeeded = 0,
    this.title = '',
    this.progress,
    this.pulse,
    this.step,
  });

  final String key;

  /// The step it is on now, in words ("Reading page 12 of 300 · PDF 3 of 37 · 12 MB"); null when it cannot say.
  final String? Function()? step;

  /// A sign of life while it runs, finer than [progress] (a PDF's pages, a core job's step): the watchdog calls the work stuck
  /// when neither changes for [IndexScheduler.stuckAfter]. Null: [progress] alone.
  final Object? Function()? pulse;

  /// What the work is on, as the person knows it: the library's or video's name ("Army Publishing"); empty when not known.
  final String title;

  /// How far the work is while it runs (items done, of all): the PDFs read, the caption files or EPUBs read. Null when the
  /// work cannot say.
  final (int, int)? Function()? progress;

  /// What the work is about, to put the small first: bytes of the source, or items in it.
  final int size;

  /// How often the source is used (searches, opens), to put the most used first.
  final int uses;

  /// Long work waits for charging or more than half a battery, and pauses when the battery runs low. Short work only waits
  /// while the battery is low.
  final bool long;

  /// Room the work needs on the device beyond what Cache keeps free.
  final int bytesNeeded;

  /// Starts (or resumes) the work. The work is resumable: [IndexRun.pause] keeps what is done.
  final Future<IndexRun> Function() start;
}

/// Work that is running.
abstract class IndexRun {
  /// Ends with true when the work is done, false when it stopped (paused, failed, or found it was not needed).
  Future<bool> get finished;

  /// Stops the work, keeping what is done for the next start; [why] is the scheduler's reason (what the work's own status says).
  Future<void> pause([IndexWait why = IndexWait.none]);

  /// How the work may run from now on (the throttle's duty, every time it changes): a core job takes it through cs_job_set at
  /// its next checkpoint; the app's own loops follow the throttle through [indexPermit] and ignore this.
  void setDuty(IndexDuty duty);
}

/// Where automatic index work comes from: the core's sources that need a build or a seal, and the PDF loop. Each call answers
/// what is still to do now; work whose snapshot already came from a linked device is not listed.
abstract class IndexWorkSource {
  Future<List<IndexTask>> pending();
}

/// Why nothing runs right now, when there is work: Cache is in the background, the battery is low, long work waits for
/// charging, not enough room, the device is warm, Ask is answering, or the person paused it all.
/// [stuck]: it ran with no progress at all for [IndexScheduler.stuckAfter] and was skipped for now (Retry, or the next start).
enum IndexWait { none, closed, battery, charging, storage, heat, model, person, stuck }

/// Where one piece of work stands: running now, queued (next in turn, nothing holds it but the one running), held (with its
/// reason), or done this session.
enum IndexState { running, queued, held, done }

/// One piece of work as the scheduler sees it now: the one source of the Library rows, their menus, the Library's overview and
/// the Settings line, so none of them says "Making" for work that is not running.
class IndexItem {
  const IndexItem({required this.key, required this.state, this.title = '', this.why = IndexWait.none, this.position = 0, this.progress, this.bytesNeeded = 0, this.slowed = false, this.warm = false, this.step});

  /// The step it is on (running), or was on when it stopped moving (stuck): "Opening · PDF 1 of 37 · 12 MB".
  final String? step;

  final String key;
  final IndexState state;
  final String title;

  /// Why it is held ([IndexState.held]).
  final IndexWait why;

  /// Its place in the queue, from 1 (queued and held work); 0 for running and done work.
  final int position;

  /// Items done, of all, while it runs.
  final (int, int)? progress;

  /// The room it needs (for "Needs 1.2 GB free").
  final int bytesNeeded;

  /// Running, but slowed down for heat (the device warm, or the system forecasting it would be).
  final bool slowed;

  /// The system's thermal status says the device is warm (not only the forecast): only then do the words say "device is warm".
  final bool warm;

  /// The kind of work: the part of the key before its last "/" ("zim-pdf", "zim-epub", "zim-captions", "captions", "zim",
  /// "library").
  String get kind => key.contains('/') ? key.substring(0, key.indexOf('/')) : key;
}

/// The one place that decides when automatic index work runs (every kind: index_source, index_seal, the PDF loop). Rules:
/// only while the app is open; one piece at a time, the most used first and, among those, the smallest; long work needs
/// charging or more than half a battery and pauses when the battery runs low (under 20% and not plugged in); work that needs
/// more room than the device has beyond Cache's reserve waits. Work is looked for again on [kick] (the sources changed, a
/// snapshot arrived) and every [every] while the app is open.
class IndexScheduler extends ChangeNotifier {
  IndexScheduler({
    required this.sources,
    required this.space,
    this.throttle,
    BatteryReader? battery,
    this.every = const Duration(seconds: 30),
    this.stuckAfter = kIndexStuckAfter,
    this.watchEvery = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _battery = battery ?? throttle?.read ?? readBattery,
       _clock = clock ?? DateTime.now {
    throttle?.addListener(_onDuty);
  }

  /// Running work with no progress at all for this long is stuck: skipped for now, so one bad source never holds up the rest.
  final Duration stuckAfter;

  /// How often the running work's progress is looked at for that.
  final Duration watchEvery;
  final DateTime Function() _clock;

  /// Work skipped as stuck this session ([IndexWait.stuck]); [retry] tries it again.
  final Set<String> _stuck = {};

  /// The step stuck work was on when it stopped moving: what its row keeps showing.
  final Map<String, String> _stuckAt = {};

  /// When each piece of work last finished, and how often it was listed again within [kIndexRedoWithin] of that.
  final Map<String, DateTime> _finishedAt = {};
  final Map<String, int> _redo = {};
  Timer? _watch;
  Object? _lastPulse;

  /// Time the running work has had to work since its last sign of life: time held (heat, the battery, Ask answering) is not
  /// counted.
  Duration _quiet = Duration.zero;
  DateTime _lastLook = DateTime.fromMillisecondsSinceEpoch(0);

  /// How long running work may go without a sign of life at the duty now: [stuckAfter] at full speed, longer in proportion as
  /// the throttle slows it (a third of the time: three times as long).
  Duration get stuckAfterNow {
    final d = throttle?.duty;
    final share = d == null || d.paused || d.share <= 0 ? 1.0 : d.share.clamp(0.05, 1.0);
    return Duration(microseconds: (stuckAfter.inMicroseconds / share).round());
  }

  static Object? _pulseOf(IndexTask t) => (t.progress?.call(), t.pulse?.call());

  /// The watchdog: the running work's progress and sign of life (a PDF's pages, a core job's step); unchanged for
  /// [stuckAfterNow] of time it could work (time held for heat, the battery or Ask answering does not count), it is stopped
  /// and skipped, and the next one runs.
  void _watchdog() {
    final t = _current;
    if (t == null || _disposed) {
      _watch?.cancel();
      _watch = null;
      return;
    }
    final now = _clock();
    final since = now.difference(_lastLook);
    _lastLook = now;
    final p = _pulseOf(t);
    if (p != _lastPulse) {
      _lastPulse = p;
      _quiet = Duration.zero;
      return;
    }
    if (throttle?.duty.paused ?? false) return;
    _quiet += since;
    final limit = stuckAfterNow;
    if (_quiet < limit) return;
    final at = t.step?.call();
    logError('Index work ${t.key} is stuck at "${at ?? 'a step it cannot name'}": no progress for ${limit.inMinutes} min of working time (at ${t.progress?.call()}); skipped for now', job: t.key);
    _stuck.add(t.key);
    if (at != null) _stuckAt[t.key] = at;
    _watch?.cancel();
    _watch = null;
    unawaited(_pause(IndexWait.stuck).then((_) {
      notifyListeners();
      return kick();
    }));
  }

  /// Tries work skipped as stuck again (the queue sheet's Retry).
  Future<void> retry(String key) {
    _stuck.remove(key);
    _stuckAt.remove(key);
    _why.remove(key);
    notifyListeners();
    return kick();
  }

  final List<IndexWorkSource> sources;

  /// The one throttle (how fast work may run, worked out again every few seconds while work runs): its duty goes to the running
  /// work whenever it changes. Null in tests that do not need it.
  final IndexThrottle? throttle;

  /// The storage the work writes to (the indexes folder's).
  final Space Function() space;
  final BatteryReader _battery;
  final Duration every;

  bool _open = false;
  bool _disposed = false;
  Timer? _timer;
  IndexTask? _current;
  IndexRun? _run;
  Future<void>? _ticker;
  bool _again = false;

  /// Work seen since the last time everything was done, and how much of it is done: the status line's "3 of 12".
  final Set<String> _seen = {};
  final Set<String> _done = {};

  /// The work listed at the last look, in the order it runs, and why each is held (none: queued or running).
  List<String> _order = const [];
  final Map<String, IndexWait> _why = {};
  final Map<String, IndexTask> _tasks = {};
  final Map<String, String> _titles = {};

  bool _saidNoBattery = false;

  /// The person's Pause all: nothing runs until Resume.
  bool _pausedAll = false;
  bool get pausedAll => _pausedAll;

  /// The battery at the last look (null when the device cannot say: then nothing waits for the battery).
  BatteryReading? reading;

  IndexWait wait = IndexWait.none;

  /// The key of the work running now.
  String? get running => _current?.key;
  int get doneCount => _done.length;
  int get totalCount => _seen.length;

  /// The quiet line Settings and the Library's overview show while there is work; null when there is none.
  String? get line => indexStatusLine(this);

  /// How much of all the work seen is done, 0 to 1, for the overview's bar. Each source counts as one equal share (the
  /// headline says "3 of 9 done" in sources); inside its share a source fills by the items it reports (PDFs read of all its
  /// PDFs, caption files or EPUBs read), so the bar moves while a big library runs instead of sitting still for an hour. Work
  /// that cannot say its progress fills its share when it is done.
  double get fraction {
    if (_seen.isEmpty) return 1;
    var sum = 0.0;
    for (final k in _seen) {
      if (_done.contains(k)) {
        sum += 1;
        continue;
      }
      final p = _tasks[k]?.progress?.call();
      if (p != null && p.$2 > 0) sum += (p.$1 / p.$2).clamp(0.0, 1.0);
    }
    return (sum / _seen.length).clamp(0.0, 1.0);
  }

  /// The system's thermal status says the device is warm (see [IndexThrottle.thermalWarm]).
  bool get deviceWarm => throttle?.thermalWarm ?? false;

  /// Whether there is work not done yet (the Settings line and the Library's overview show while there is).
  bool get busy => _seen.isNotEmpty && _done.length < _seen.length;

  /// Where [key]'s work stands now; null when the scheduler has not seen it (nothing to do, or not listed yet).
  IndexItem? statusOf(String key) {
    final title = _titles[key] ?? '';
    final t = _tasks[key];
    if (_current?.key == key) {
      // Running, but the throttle may be holding it at its next checkpoint (too warm, a low battery, Ask answering): that is
      // its reason; warm but not held is slowed down.
      final d = throttle?.duty;
      final held = d != null && d.paused
          ? switch (d.hold) {
              IndexHold.heat => IndexWait.heat,
              IndexHold.battery => IndexWait.battery,
              IndexHold.model || IndexHold.none => IndexWait.model,
            }
          : IndexWait.none;
      return IndexItem(key: key, state: IndexState.running, title: title, why: held, progress: t?.progress?.call(), slowed: held == IndexWait.none && (throttle?.warm ?? false), warm: deviceWarm, step: t?.step?.call());
    }
    final at = _order.indexOf(key);
    if (at >= 0) {
      final why = _why[key] ?? IndexWait.none;
      return IndexItem(
        key: key,
        state: why == IndexWait.none ? IndexState.queued : IndexState.held,
        title: title,
        why: why,
        position: at + 1,
        bytesNeeded: t?.bytesNeeded ?? 0,
        progress: t?.progress?.call(),
        warm: deviceWarm,
        step: why == IndexWait.stuck ? _stuckAt[key] : null,
      );
    }
    if (_done.contains(key)) return IndexItem(key: key, state: IndexState.done, title: title);
    return null;
  }

  /// Everything seen since the last time all was done: the running work, then the rest in the order it runs, then what is done.
  List<IndexItem> get items => [
    if (_current case final c?) statusOf(c.key)!,
    for (final k in _order)
      if (k != _current?.key) statusOf(k)!,
    for (final k in _seen)
      if (_done.contains(k) && !_order.contains(k) && k != _current?.key) IndexItem(key: k, state: IndexState.done, title: _titles[k] ?? ''),
  ];

  /// Why the work does not go on as usual, for the Settings line and the overview: the running work's slowing down, else the
  /// reason the first held work waits; none when work runs as usual or is only queued.
  IndexWait get reason {
    if (_current case final c?) return statusOf(c.key)!.why;
    for (final k in _order) {
      final w = _why[k] ?? IndexWait.none;
      if (w != IndexWait.none) return w;
    }
    return wait;
  }

  /// The person's Pause all (the Library's queue sheet): what runs pauses and keeps its work, and nothing starts until
  /// [resumeAll].
  Future<void> pauseAll() async {
    if (_pausedAll) return;
    _pausedAll = true;
    for (final k in _order) {
      _why[k] = IndexWait.person;
    }
    await _pause(IndexWait.person);
    notifyListeners();
  }

  /// Resume after [pauseAll]: the rules decide again at once.
  Future<void> resumeAll() async {
    if (!_pausedAll) return;
    _pausedAll = false;
    _why.clear();
    notifyListeners();
    await kick();
  }

  /// The app came to the front (true) or went to the back (false): work runs only while it is open.
  void setOpen(bool open) {
    if (_open == open) return;
    _open = open;
    _timer?.cancel();
    _timer = null;
    if (open) {
      _timer = Timer.periodic(every, (_) => kick());
      kick();
    } else {
      unawaited(_pause(IndexWait.closed));
    }
  }

  /// Looks for work and runs or pauses it by the rules now. While a look is under way, it is looked again after it, and the
  /// future ends when that is done too.
  Future<void> kick() {
    if (_disposed) return Future.value();
    final running = _ticker;
    if (running != null) {
      _again = true;
      return running;
    }
    return _ticker = () async {
      try {
        do {
          _again = false;
          await _tick();
        } while (_again && !_disposed);
      } finally {
        _ticker = null;
      }
    }();
  }

  Future<void> _tick() async {
    if (!_open) return _pause(IndexWait.closed);
    if (_pausedAll) return _pause(IndexWait.person);
    final work = <IndexTask>[];
    for (final s in sources) {
      try {
        work.addAll(await s.pending());
      } catch (e) {
        logError('Index work could not be listed', error: e);
      }
    }
    final keys = {for (final t in work) t.key};
    // Work that finished and is listed again at once, over and over, is a loop (its source still says it needs doing): stuck,
    // with the reason, never run again and again (it would hold every other piece of work up).
    final now = _clock();
    for (final k in keys) {
      final at = _finishedAt.remove(k);
      if (at == null || _stuck.contains(k)) continue;
      if (now.difference(at) > kIndexRedoWithin) {
        _redo.remove(k);
        continue;
      }
      final n = _redo[k] = (_redo[k] ?? 0) + 1;
      if (n > 2) {
        logError('Index work $k finished but was listed again at once, $n times; stopped as stuck', job: k);
        _stuck.add(k);
        _stuckAt[k] = 'Finished, but asked to run again at once';
        _redo.remove(k);
      }
    }
    _seen.addAll(keys);
    // Listed again is not done (a library that got more to index after it was done, or a job stopped and listed again): the
    // count and the rows say what is really left.
    _done.removeAll(keys);
    // What is no longer listed is done (built here, or its snapshot came from a linked device).
    _done.addAll(_seen.where((k) => !keys.contains(k) && k != _current?.key));
    if (work.isEmpty && _current == null) {
      if (_done.length >= _seen.length) {
        _seen.clear();
        _done.clear();
        _order = const [];
        _why.clear();
        _tasks.clear();
      }
      _set(IndexWait.none);
      notifyListeners();
      return;
    }
    work.sort((a, b) => b.uses != a.uses ? b.uses.compareTo(a.uses) : a.size.compareTo(b.size));
    for (final t in work) {
      _tasks[t.key] = t;
      if (t.title.isNotEmpty) _titles[t.key] = t.title;
    }
    _order = [for (final t in work) t.key];
    _why.removeWhere((k, _) => !keys.contains(k));
    final b = await _battery();
    // A device that cannot say its battery (a desktop, or a failed read) never holds work for the battery: it runs as if plugged
    // in. Said once in the log.
    if (b == null && !_saidNoBattery) {
      _saidNoBattery = true;
      logInfo('Index work: the battery could not be read; it runs as if plugged in');
    }
    reading = b;
    final s = space();
    // The running work goes on while the rules allow it; otherwise it pauses (resumable). The rest wait their turn.
    final cur = _current;
    if (cur != null) {
      final why = _blocked(cur, b, s, running: true);
      for (final t in work) {
        _why[t.key] = IndexWait.none;
      }
      if (why != IndexWait.none) {
        await _pause(why);
      } else {
        notifyListeners();
      }
      return;
    }
    // Each in turn: the first the rules let through starts; those before it say why they wait; those after it are queued.
    var started = false;
    for (final t in work) {
      if (started) {
        _why[t.key] = IndexWait.none;
        continue;
      }
      final why = _blocked(t, b, s, running: false);
      _why[t.key] = why;
      if (why == IndexWait.none) {
        started = true;
        await _start(t);
      } else {
        _set(why);
      }
    }
    notifyListeners();
  }

  IndexWait _blocked(IndexTask t, BatteryReading? b, Space s, {required bool running}) {
    if (_stuck.contains(t.key)) return IndexWait.stuck;
    // Held by the throttle (too warm, a low battery, the model generating): nothing new starts; what runs is held by its duty.
    final d = throttle?.duty;
    if (!running && d != null && d.paused) {
      return switch (d.hold) {
        IndexHold.heat => IndexWait.heat,
        IndexHold.battery => IndexWait.battery,
        IndexHold.model || IndexHold.none => IndexWait.model,
      };
    }
    if (b != null) {
      if (b.low) return IndexWait.battery;
      // Long work starts only on charge or above half; once running it goes on until the battery is low.
      if (t.long && !running && !b.charging && b.percent <= 50) return IndexWait.charging;
    }
    if (t.bytesNeeded > 0 && s.shortBy(t.bytesNeeded) > 0) return IndexWait.storage;
    if (s.usable == 0) return IndexWait.storage;
    return IndexWait.none;
  }

  bool _heldForModel = false;

  void _onDuty() {
    final d = throttle?.duty;
    final forModel = d != null && d.paused && d.hold == IndexHold.model;
    if (forModel && !_heldForModel) {
      // The model is loading or writing an answer: the running work STOPS (it keeps what it did) instead of only waiting at its
      // next checkpoint, so its memory goes back before the model needs it: a core job's index writer, the PDF loop's open
      // document and pages. A model and a busy index on one phone was enough for Android to kill Cache mid-answer.
      _heldForModel = true;
      if (_current != null) {
        unawaited(_pause(IndexWait.model).then((_) => logInfo('Index work stopped while the model runs; ${memoryNow()}')));
      }
    } else if (!forModel && _heldForModel) {
      // The answer is written: the rules decide again (the work carries on from what it kept).
      _heldForModel = false;
      unawaited(kick());
    }
    if (d != null) _run?.setDuty(d);
    notifyListeners();
  }

  Future<void> _start(IndexTask t) async {
    _current = t;
    _set(IndexWait.none);
    _lastPulse = _pulseOf(t);
    _quiet = Duration.zero;
    _lastLook = _clock();
    _watch?.cancel();
    _watch = Timer.periodic(watchEvery, (_) => _watchdog());
    try {
      final run = await t.start();
      _run = run;
      // The throttle reads the device every few seconds while work runs, and the run follows its duty from the start.
      throttle?.watch(true);
      final d = throttle?.duty;
      if (d != null) run.setDuty(d);
      unawaited(run.finished.then((ok) {
        if (_current?.key != t.key) return;
        if (ok) {
          _done.add(t.key);
          _order = [for (final k in _order) if (k != t.key) k];
          _finishedAt[t.key] = _clock();
        }
        _current = null;
        _run = null;
        throttle?.watch(false);
        notifyListeners();
        kick();
      }, onError: (Object e) {
        logError('Index work ${t.key} failed', error: e, job: t.key);
        if (_current?.key == t.key) {
          _current = null;
          _run = null;
        }
        notifyListeners();
      }));
    } catch (e) {
      logError('Index work ${t.key} could not start', error: e, job: t.key);
      _current = null;
      _run = null;
      notifyListeners();
    }
  }

  Future<void> _pause(IndexWait why) async {
    final run = _run;
    final cur = _current;
    _current = null;
    _run = null;
    throttle?.watch(false);
    // What ran goes back to the front of the queue, held for the same reason; on closing or Pause all, everything is held.
    if (cur != null && !_order.contains(cur.key)) _order = [cur.key, ..._order];
    if (cur != null) _why[cur.key] = why;
    if (why == IndexWait.closed || why == IndexWait.person) {
      for (final k in _order) {
        _why[k] = why;
      }
    }
    _set(why);
    if (run != null) {
      try {
        await run.pause(why);
      } catch (e) {
        logError('Index work could not pause', error: e);
      }
    }
  }

  void _set(IndexWait w) {
    if (wait == w) return;
    wait = w;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _watch?.cancel();
    throttle?.removeListener(_onDuty);
    _timer?.cancel();
    final run = _run;
    _run = null;
    _current = null;
    if (run != null) unawaited(run.pause(IndexWait.closed).catchError((_) {}));
    super.dispose();
  }
}

/// The core's own index work: sources whose index needs a build (cs_status `index.needs_build`, cs_job_start "index_source")
/// and indexes built before snapshots that need sealing ("index_seal"). Their runs take the throttle's duty through cs_job_set. The core calls are not in this core yet, so the app
/// uses [IndexCoreCalls.none] until they land; tests use a fake.
abstract class IndexCoreCalls {
  /// What the core says needs a build or a seal now.
  Future<List<CoreIndexNeed>> needs();

  /// Starts the job for [need].
  Future<IndexRun> start(CoreIndexNeed need);

  static const IndexCoreCalls none = _NoCoreCalls();
}

/// One source the core says needs index work.
class CoreIndexNeed {
  const CoreIndexNeed({required this.kind, required this.sourceId, required this.seal, this.size = 0, this.uses = 0, this.bytesNeeded = 0, this.indexDir, this.title = '', this.progress, this.pulse, this.step});

  /// The running job's step in words ("Looking through the library · 2,000 of 40,000").
  final String? Function()? step;

  /// The running job's step and place in it (any step, also those [progress] leaves out), for the watchdog.
  final Object? Function()? pulse;

  /// The library's or video's name.
  final String title;

  /// The running job's progress (items read, of all), while it runs.
  final (int, int)? Function()? progress;

  final String kind;
  final String sourceId;

  /// True for an index built before snapshots ("index_seal"), false for a build ("index_source").
  final bool seal;

  /// For a seal: the old index's folder (cs_status's index "dir"), for when no handle has the source.
  final String? indexDir;
  final int size;
  final int uses;
  final int bytesNeeded;
}

class _NoCoreCalls implements IndexCoreCalls {
  const _NoCoreCalls();

  @override
  Future<List<CoreIndexNeed>> needs() async => const [];

  @override
  Future<IndexRun> start(CoreIndexNeed need) => throw UnsupportedError('this core has no index_source or index_seal');
}

/// [IndexWorkSource] over the core's calls. A seal only copies what is built, so it is short work; a build is long.
class CoreIndexWork implements IndexWorkSource {
  CoreIndexWork(this.calls);

  final IndexCoreCalls calls;

  @override
  Future<List<IndexTask>> pending() async => [
        for (final n in await calls.needs())
          IndexTask(
            key: '${n.kind}/${n.sourceId}',
            size: n.size,
            uses: n.uses,
            long: !n.seal,
            bytesNeeded: n.bytesNeeded,
            title: n.title,
            progress: n.progress,
            pulse: n.pulse,
            step: n.step,
            start: () => calls.start(n),
          ),
      ];
}

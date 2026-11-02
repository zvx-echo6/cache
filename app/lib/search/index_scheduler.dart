import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/battery.dart';
import '../settings/space.dart';

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
  });

  final String key;

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

  /// Stops the work, keeping what is done for the next start.
  Future<void> pause();
}

/// Where automatic index work comes from: the core's sources that need a build or a seal, and the PDF loop. Each call answers
/// what is still to do now; work whose snapshot already came from a linked device is not listed.
abstract class IndexWorkSource {
  Future<List<IndexTask>> pending();
}

/// Why nothing runs right now, when there is work.
enum IndexWait { none, closed, battery, charging, storage }

/// The one place that decides when automatic index work runs (every kind: index_source, index_seal, the PDF loop). Rules:
/// only while the app is open; one piece at a time, the most used first and, among those, the smallest; long work needs
/// charging or more than half a battery and pauses when the battery runs low (under 20% and not plugged in); work that needs
/// more room than the device has beyond Cache's reserve waits. Work is looked for again on [kick] (the sources changed, a
/// snapshot arrived) and every [every] while the app is open.
class IndexScheduler extends ChangeNotifier {
  IndexScheduler({
    required this.sources,
    required this.space,
    BatteryReader? battery,
    this.every = const Duration(seconds: 30),
  }) : _battery = battery ?? readBattery;

  final List<IndexWorkSource> sources;

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

  IndexWait wait = IndexWait.none;

  /// The key of the work running now.
  String? get running => _current?.key;
  int get doneCount => _done.length;
  int get totalCount => _seen.length;

  /// The quiet line Settings shows while there is work; null when there is none.
  String? get line {
    if (_seen.isEmpty || _done.length >= _seen.length) return null;
    final head = 'Getting search ready: ${_done.length} of ${_seen.length}';
    return switch (wait) {
      IndexWait.battery => '$head · paused, battery low',
      IndexWait.charging => '$head · waits for charging',
      IndexWait.storage => '$head · paused, not enough space',
      _ => head,
    };
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
    final work = <IndexTask>[];
    for (final s in sources) {
      try {
        work.addAll(await s.pending());
      } catch (e) {
        debugPrint('Index work could not be listed: $e');
      }
    }
    final keys = {for (final t in work) t.key};
    _seen.addAll(keys);
    // What is no longer listed is done (built here, or its snapshot came from a linked device).
    _done.addAll(_seen.where((k) => !keys.contains(k) && k != _current?.key));
    if (work.isEmpty && _current == null) {
      if (_done.length >= _seen.length) {
        _seen.clear();
        _done.clear();
      }
      _set(IndexWait.none);
      return;
    }
    work.sort((a, b) => b.uses != a.uses ? b.uses.compareTo(a.uses) : a.size.compareTo(b.size));
    final b = await _battery();
    final s = space();
    // The running work goes on while the rules allow it; otherwise it pauses (resumable).
    final cur = _current;
    if (cur != null) {
      final why = _blocked(cur, b, s, running: true);
      if (why != IndexWait.none) await _pause(why);
      return;
    }
    for (final t in work) {
      final why = _blocked(t, b, s, running: false);
      if (why == IndexWait.none) {
        await _start(t);
        return;
      }
      _set(why);
    }
  }

  IndexWait _blocked(IndexTask t, BatteryReading? b, Space s, {required bool running}) {
    if (b != null) {
      if (b.low) return IndexWait.battery;
      // Long work starts only on charge or above half; once running it goes on until the battery is low.
      if (t.long && !running && !b.charging && b.percent <= 50) return IndexWait.charging;
    }
    if (t.bytesNeeded > 0 && s.shortBy(t.bytesNeeded) > 0) return IndexWait.storage;
    if (s.usable == 0) return IndexWait.storage;
    return IndexWait.none;
  }

  Future<void> _start(IndexTask t) async {
    _current = t;
    _set(IndexWait.none);
    try {
      final run = await t.start();
      _run = run;
      unawaited(run.finished.then((ok) {
        if (_current?.key != t.key) return;
        if (ok) _done.add(t.key);
        _current = null;
        _run = null;
        notifyListeners();
        kick();
      }, onError: (Object e) {
        debugPrint('Index work ${t.key} failed: $e');
        if (_current?.key == t.key) {
          _current = null;
          _run = null;
        }
        notifyListeners();
      }));
    } catch (e) {
      debugPrint('Index work ${t.key} could not start: $e');
      _current = null;
      _run = null;
      notifyListeners();
    }
  }

  Future<void> _pause(IndexWait why) async {
    final run = _run;
    _current = null;
    _run = null;
    _set(why);
    if (run != null) {
      try {
        await run.pause();
      } catch (e) {
        debugPrint('Index work could not pause: $e');
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
    _timer?.cancel();
    final run = _run;
    _run = null;
    _current = null;
    if (run != null) unawaited(run.pause().catchError((_) {}));
    super.dispose();
  }
}

/// The core's own index work: sources whose index needs a build (cs_status `index.needs_build`, cs_job_start "index_source")
/// and indexes built before snapshots that need sealing ("index_seal"). The core calls are not in this core yet, so the app
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
  const CoreIndexNeed({required this.kind, required this.sourceId, required this.seal, this.size = 0, this.uses = 0, this.bytesNeeded = 0});

  final String kind;
  final String sourceId;

  /// True for an index built before snapshots ("index_seal"), false for a build ("index_source").
  final bool seal;
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
            start: () => calls.start(n),
          ),
      ];
}

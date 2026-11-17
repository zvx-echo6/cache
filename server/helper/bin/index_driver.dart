import 'dart:async';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/models.dart';
import 'host_load.dart';
import 'pdf_zim_indexer.dart';

typedef _Work = ({Map<String, dynamic> source, String kind, Map<String, dynamic> params, String? key});

/// Starts and drives the core's index jobs on the server, one at a time. On the phone SourcesState does this (it is not used in the
/// browser, because the device owns the sources); the browser only reads the status.
///
/// What it mirrors:
/// - the choice of what to index is SourcesState._refreshOnce (a ZIM that has an id... is not searchable, has no error, is not
///   being built and has no job of ours) and LibrariesState._resumeIndexes (a library that is not indexed, unless its settings
///   turn the keyword index off);
/// - the jobs are SourcesState._startIndex (`index_zim` with `heap_mb` 200) and LibrariesState._indexInstalled (`index_library`);
/// - the polling and the "give the core the list again when a job ends" step are SourcesState._pollJobs.
/// Beyond the keyword indexes, as on the phone (AppIndexCoreCalls and PdfIndexWork, run by its IndexScheduler):
/// - `index_seal` for an index built before snapshots (cs_status `index.needs_seal`), and `index_source` for the EPUBs and caption
///   files of a ZIM (`epubindex` and `captionsindex` with `needs_build`), with the same parameters, and `index_source` (kind
///   `captions`, with the videos folder) for each saved video whose `captions_index` says `needs_build` ([savedVideos], the
///   server's own saved videos in `<docs>/videos`, read from cs_video_downloads);
/// - the PDFs inside a ZIM that has none searchable yet (cs_status `pdfindex` is not ready): [ZimPdfIndexer] reads each PDF with
///   MuPDF (the pdfrx loop needs Flutter) and makes the same core calls, so the snapshot is the phone's format.
/// Order: a ZIM or library's keyword index, then seals, then EPUBs and captions, then saved videos' captions, then PDFs; one job
/// at a time.
/// The phone's throttle has a hook here too, as far as a server has one ([HostLoad]): `index_seal`, `index_source` and the PDF loop
/// follow the host's heat and memory (jobs through cs_job_set, the PDF loop between PDFs); with [load] null there is no yield.
///
/// A ZIM that is stale is indexed again as well. A source is tried once for each [useSources] call (open or rescan), so a source
/// whose index cannot be built does not start over in a loop; a failure is kept in [failures] until the next rescan.
///
/// The helper is single-threaded and answers one line at a time, so a timer tick never overlaps a request.
class IndexDriver {
  IndexDriver(this.dispatcher, {this.log, this.every = const Duration(seconds: 1), this.extra = const {}, this.load, this.pdf, this.savedVideos, this.videoDir, DateTime Function()? clock})
      : clock = clock ?? DateTime.now,
        _pacer = IndexPacer(load);

  final CoreDispatcher dispatcher;

  /// App configuration retained across source refreshes and shared-index builds.
  final Map<String, dynamic> extra;
  final void Function(String message)? log;
  final Duration every;

  /// The time, for the stuck watchdog and the redo rule; a test gives its own.
  final DateTime Function() clock;

  /// Running work with no progress for this long (host holds not counted) is stuck (the phone's kIndexStuckAfter).
  static const Duration stuckAfter = Duration(minutes: 5);

  /// How often the watchdog looks (the phone's: every 30 s).
  static const Duration watchEvery = Duration(seconds: 30);

  /// Work listed again this soon after it finished counts as a repeat; more than two repeats in a row is stuck
  /// (the phone's kIndexRedoWithin).
  static const Duration redoWithin = Duration(seconds: 15);

  /// The host's heat and memory, which index_seal, index_source and the PDF loop yield to; null: no yield.
  final HostLoad? load;

  /// The PDF reader and the indexes folder, for the PDFs inside ZIMs; null: they are not indexed.
  final PdfWork? pdf;

  /// The saved videos as cs_video_downloads lists them (each with its `captions_index`); null: there are none to index.
  final List<Map<String, dynamic>> Function()? savedVideos;

  /// The saved videos' folder, which index_source reads a video's caption files from.
  final String? videoDir;
  final IndexPacer _pacer;

  /// The running PDF run, and whether one is starting (it lists the ZIM's PDFs first).
  ZimPdfIndexer? _pdfRun;
  bool _pdfBusy = false;

  /// How many PDFs each ZIM has (by path and id), so a ZIM without any is not listed again at every rescan.
  final Map<String, int> _pdfCounts = {};
  Map<String, Map<String, dynamic>> _status = const {};

  /// Whether the running job takes cs_job_set (seals and index_source do), and the duty last sent to it.
  bool _paced = false;
  HostDuty? _sent;
  int _paceTicks = 0;

  List<Map<String, dynamic>> _sources = const [];
  final Set<String> _tried = {};
  final Map<String, String> failures = {};

  /// Work the watchdog or the redo rule stopped, by key, with why; skipped until [retry] (a rescan does not clear it).
  final Map<String, String> stuck = {};

  /// What finished in this helper session, by key in the order it finished, with the counts it ended on (null: not known).
  final Map<String, ({int? done, int? total})> _finished = {};

  /// The last counts a key's job reported, kept for the queue while it is stuck or failed.
  final Map<String, ({int? done, int? total})> _counts = {};
  final Map<String, DateTime> _finishedAt = {};
  final Map<String, int> _redo = {};
  Timer? _timer;

  /// Set by [_next] when a source that will want indexing is still opening, building or updating: the timer must keep running
  /// until it settles, or the index is never started (the library is usually still opening on the first tick after a rescan).
  bool _waiting = false;

  /// The running job's key in the dispatcher, its source path and what it is.
  int? _job;
  String? _jobPath;

  /// The running PDF run's key, while one is starting or running.
  String? _pdfKey;

  /// What each source being indexed has done so far, by source path (0..1, or null when the total is not known yet).
  final Map<String, double?> progress = {};

  /// The source list the core was given (the server's open or rescan); every source may be tried again once.
  void useSources(List<Map<String, dynamic>> sources) {
    _sources = sources;
    _tried.clear();
    failures.clear();
    kick();
  }

  /// Looks for the next source to index, soon. Safe to call at any time.
  void kick() {
    _timer ??= Timer.periodic(every, (_) => tick());
    scheduleMicrotask(tick);
  }

  bool get busy => _job != null || _pdfBusy;

  /// The person's Pause (the phone's Catalog "Pause all", IndexScheduler.pauseAll): what runs stops and keeps what it did, and nothing
  /// starts until [resume]. Kept in memory, as on the phone: a restart of the server resumes.
  bool _paused = false;
  bool get paused => _paused;

  /// The job a Pause cancelled, until the tick that sees it ended: it is tried again even when Resume came first.
  int? _pauseCancelled;

  /// Whether there is index work, running or still to start (the Catalog shows Pause only while there is).
  bool get hasWork {
    if (busy || _waiting) return true;
    try {
      // PDF work counts too: with only PDFs left and indexing paused, nothing runs, and Resume must stay on offer.
      return _next() != null || _nextPdf() != null;
    } catch (_) {
      return false;
    }
  }

  /// Stops the running job (the core honours cs_job_cancel and keeps what it did) or PDF run; it is started again by [resume].
  void pause() {
    if (_paused) return;
    _paused = true;
    final job = _job;
    if (job != null) {
      _pauseCancelled = job;
      try {
        dispatcher.handle('jobCancel', {'job': job});
      } catch (_) {}
    }
    _pdfRun?.cancel();
    log?.call('indexing paused');
  }

  /// Carries on: what was stopped is started again, and the rest in order.
  void resume() {
    if (!_paused) return;
    _paused = false;
    log?.call('indexing resumed');
    kick();
  }

  /// Why the host holds index work now ("heat" or "memory"), or null when it does not; `index.state` carries it.
  String? get hold => _hold;
  String? _hold;

  /// Logs when a hold starts, changes or ends (once each, not at every tick).
  void _noteHold(HostDuty? d) {
    final h = d != null && d.paused ? (d.hold ?? 'load') : null;
    if (h == _hold) return;
    _hold = h;
    if (h == null) {
      log?.call('index work goes on: the host no longer holds it');
    } else {
      log?.call('index work is held: ${h == 'memory' ? 'the host is short of memory' : h == 'heat' ? 'the host is too hot' : h}');
    }
  }

  /// Whether the timer is running (it stops when nothing is left to start or wait for).
  bool get running => _timer != null;

  void stop() {
    _pdfRun?.cancel();
    _timer?.cancel();
    _timer = null;
    _hold = null;
  }

  /// One step: advance the running job, or start the next one. Public so a test can drive it.
  void tick() {
    try {
      watchdog();
      if (_job != null) {
        _advance();
        if (_job != null) return;
      }
      if (_paused) {
        // The person's Pause: nothing starts; the host's hold is still followed, so index.state stays true.
        _noteHold(load?.duty());
        return;
      }
      if (_pdfBusy) {
        // The PDF loop waits between PDFs while the host holds work (the pacer's permit).
        _noteHold(load?.duty());
        return;
      }
      // The host is too hot or short of memory: nothing new starts now (the timer goes on and looks again).
      final duty = load?.duty();
      _noteHold(duty);
      if (duty?.paused ?? false) return;
      var next = _next();
      // Work that finished and is listed again at once, over and over, is a loop: stuck, never run again (it would hold all else up).
      while (next != null && _redoStuck(next.key ?? next.source['path'] as String)) {
        next = _next();
      }
      if (next == null) {
        if (_startPdf()) return;
        // Nothing to start now. Keep ticking while a source is still settling; stop only when all are done or not wanted.
        if (!_waiting) stop();
        return;
      }
      _start(next.source, next.kind, next.params, key: next.key);
    } on CacheSearchException catch (e) {
      // Not open yet, or the engine went away: nothing to do until the server opens or rescans again.
      log?.call('indexing paused: ${e.message}');
      _job = null;
      _jobPath = null;
      stop();
    } catch (e) {
      log?.call('indexing step failed: $e');
    }
  }

  void _advance() {
    final job = _job!, path = _jobPath!;
    JobProgress p;
    try {
      p = JobProgress.fromJson((dispatcher.handle('jobProgress', {'job': job}) as Map).cast<String, dynamic>());
    } catch (_) {
      // The job is gone (the core was closed, or the server's caller freed it).
      _job = null;
      _jobPath = null;
      _pauseCancelled = null;
      progress.remove(path);
      return;
    }
    progress[path] = p.fraction;
    _counts[path] = (done: p.total > 0 ? p.done : null, total: p.total > 0 ? p.total : null);
    if (!p.isFinished) {
      _pace(job);
      return;
    }
    try {
      dispatcher.handle('jobFree', {'job': job});
    } catch (_) {}
    final byPause = _paused || _pauseCancelled == job;
    _pauseCancelled = null;
    _job = null;
    _jobPath = null;
    progress.remove(path);
    if (p.state == JobState.failed) {
      failures[path] = p.errorMessage ?? 'Indexing failed';
      log?.call('index of $path failed: ${failures[path]}');
    } else if (p.state == JobState.cancelled && byPause) {
      // Stopped by Pause: it is tried again at Resume (also when Resume came before this tick saw the job end).
      _tried.remove(path);
      log?.call('index of $path paused');
    } else {
      if (p.state == JobState.done) _markFinished(path);
      log?.call('index of $path ${p.state.name}');
    }
    // A source whose index was being built is picked up again when the list is set again (SourcesState._pollJobs).
    dispatcher.handle('setSources', {'sources': _sources, 'extra': extra});
  }

  Map<String, Map<String, dynamic>> _readStatus() => {
        for (final s in (dispatcher.handle('status', const {}) as List)) (s as Map)['path'] as String: s.cast<String, dynamic>(),
      };

  _Work? _next() {
    final status = _readStatus();
    _waiting = false;
    _status = status;
    return _candidates(status).firstOrNull;
  }

  /// Whether a key may not be started: it failed, or it is stuck.
  bool _blocked(String key) => failures.containsKey(key) || stuck.containsKey(key);

  /// Every piece of work [_next] could take, in the order it would take it (the one place the selection rules live; [_next] takes
  /// the first, the queue lists them all). Lazy: [_next] reads no further than the first. Starts nothing.
  Iterable<_Work> _candidates(Map<String, Map<String, dynamic>> status) sync* {
    for (final src in _sources) {
      final path = src['path'] as String;
      if (_tried.contains(path) || _blocked(path)) continue;
      final s = status[path];
      if (s == null || s['error'] != null) continue;
      final settings = (src['settings'] as Map?)?.cast<String, dynamic>();
      if (s['building'] == true || s['opening'] == true || s['updating'] == true) {
        // Not ready to look at yet; look again on the next tick (unless its keyword index is switched off).
        if (src['kind'] != 'library' || (settings?['keyword_index'] ?? 'auto') != 'off') _waiting = true;
        continue;
      }
      if (src['kind'] == 'library') {
        if (s['id'] == null || s['indexed'] == true || (settings?['keyword_index'] ?? 'auto') == 'off') continue;
        yield (
          source: src,
          kind: 'index_library',
          params: {'library_path': path, 'index_dir': src['index_dir'], ..._indexRoot, 'heap_mb': 200, 'settings': ?settings},
          key: null,
        );
        continue;
      }
      final searchable = s['id'] != null && s['indexed'] == true;
      if (searchable && s['stale'] != true) continue;
      yield (source: src, kind: 'index_zim', params: {'zim_path': path, 'index_dir': src['index_dir'], ..._indexRoot, 'heap_mb': 200}, key: null);
    }
    yield* _coreWork(status);
  }

  /// The core's own index work the phone's AppIndexCoreCalls.needs lists: seals first, then the EPUBs and caption files of ZIMs.
  Iterable<_Work> _coreWork(Map<String, Map<String, dynamic>> status) sync* {
    final root = _indexRoot;
    if (root.isEmpty) return;
    for (final src in _sources) {
      final s = status[src['path'] as String];
      if (s == null || s['error'] != null || s['building'] == true || s['opening'] == true || s['updating'] == true) continue;
      final index = (s['index'] as Map?)?.cast<String, dynamic>();
      final id = s['source_id'] as String?;
      final kind = index?['kind'];
      final key = 'seal:$kind/$id';
      if (index != null && index['needs_seal'] == true && id != null && (kind == 'zim' || kind == 'library') && !_tried.contains(key) && !_blocked(key)) {
        yield (source: src, kind: 'index_seal', params: {...root, 'kind': kind, 'source_id': id, 'index_dir': ?index['dir']}, key: key);
      }
    }
    for (final src in _sources) {
      final s = status[src['path'] as String];
      if (s == null || s['error'] != null || s['building'] == true || s['opening'] == true || s['updating'] == true) continue;
      for (final sub in [s['captionsindex'], s['epubindex']]) {
        if (sub is! Map || sub['needs_build'] != true || sub['kind'] == null) continue;
        final id = (sub['source_id'] ?? s['source_id']) as String?;
        final key = '${sub['kind']}/$id';
        if (id == null || _tried.contains(key) || _blocked(key)) continue;
        yield (source: src, kind: 'index_source', params: {...root, 'kind': sub['kind'], 'source_id': id}, key: key);
      }
    }
    yield* _videoCaptions(root);
  }

  /// A saved video whose captions are not searchable yet (the phone's AppIndexCoreCalls.needs, its videos part).
  Iterable<_Work> _videoCaptions(Map<String, dynamic> root) sync* {
    final list = savedVideos;
    if (list == null) return;
    List<Map<String, dynamic>> videos;
    try {
      videos = list();
    } catch (e) {
      log?.call('saved videos not read: $e');
      return;
    }
    for (final v in videos) {
      final c = v['captions_index'];
      if (c is! Map || c['needs_build'] != true) continue;
      final id = c['source_id'];
      if (id is! String || id.isEmpty) continue;
      final key = 'captions/$id';
      if (_tried.contains(key) || _blocked(key)) continue;
      yield (
        source: {'path': key},
        kind: 'index_source',
        params: {...root, 'kind': 'captions', 'source_id': id, 'video_dir': ?videoDir},
        key: key,
      );
    }
  }

  /// Starts the PDF run for the next ZIM whose PDFs are not searchable yet (the phone's PdfIndexState.needsIndex); false when
  /// there is none, or the core has no PDF index calls.
  bool _startPdf() {
    final w = pdf;
    var next = _nextPdf();
    while (next != null && _redoStuck(next.key)) {
      next = _nextPdf();
    }
    if (w == null || next == null) return false;
    _tried.add(next.key);
    _counts.remove(next.key);
    _pdfBusy = true;
    _pdfKey = next.key;
    unawaited(_runPdf(w, next.path, next.id, next.key));
    return true;
  }

  /// The next ZIM whose PDFs are still to be indexed, from the status [_next] last read; null when there is none or the core has
  /// no PDF index calls. Starts nothing.
  ({String path, String id, String key})? _nextPdf() => _pdfCandidates(_status).firstOrNull;

  /// Every ZIM whose PDFs are still to be indexed, in the order [_nextPdf] takes them.
  Iterable<({String path, String id, String key})> _pdfCandidates(Map<String, Map<String, dynamic>> status) sync* {
    final w = pdf;
    if (w == null || !w.core.available) return;
    for (final src in _sources) {
      if (src['kind'] == 'library') continue;
      final path = src['path'] as String;
      final s = status[path];
      final id = s?['id'] as String?;
      if (s == null || id == null || s['error'] != null || s['building'] == true || s['opening'] == true || s['updating'] == true) continue;
      final state = (s['pdfindex'] as Map?)?['state'];
      if (state == 'ready' || state == 'opening') continue;
      final key = 'zim-pdf/$id';
      if (_tried.contains(key) || _blocked(key) || _pdfCounts['$path|$id'] == 0) continue;
      yield (path: path, id: id, key: key);
    }
    return null;
  }

  Future<void> _runPdf(PdfWork w, String path, String id, String key) async {
    var attach = false;
    try {
      progress[key] = null;
      final list = await w.core.zimPdfs(id);
      _pdfCounts['$path|$id'] = list.pdfs.length;
      if (list.pdfs.isEmpty) return;
      if (_paused) {
        // Paused while the PDFs were being listed (there was no run to cancel yet): the run does not start, and Resume starts it.
        _tried.remove(key);
        log?.call('PDF index of $path paused');
        return;
      }
      log?.call('indexing the PDFs of $path (${list.pdfs.length})');
      final run = _pdfRun = ZimPdfIndexer(core: w.core, read: w.read, indexesDir: w.indexesDir, permit: _pacer.permit, log: log);
      // A Pause also ends the wait for the host before a PDF; the run then sees its cancel before that PDF.
      _pacer.cancelled = () => _paused || !_pdfBusy || _timer == null;
      // Progress for the status (index.state) while it runs.
      final watch = Timer.periodic(const Duration(seconds: 1), (_) {
        progress[key] = run.fraction;
        _counts[key] = (done: run.done + run.skipped, total: run.total);
      });
      final ZimPdfEnd end;
      try {
        end = await run.run(list);
      } finally {
        watch.cancel();
      }
      switch (end) {
        case ZimPdfEnd.finished:
          attach = true;
          _counts[key] = (done: run.done + run.skipped, total: run.total);
          _markFinished(key);
          log?.call('PDF index of $path finished (${run.done} PDFs, ${run.skipped} skipped, ${run.reused} reused)');
        case ZimPdfEnd.paused:
          // Stopped with the server (or a rescan's stop); the build stays and is picked up at the next open.
          _tried.remove(key);
          log?.call('PDF index of $path paused');
        case ZimPdfEnd.failed:
          failures[key] = run.error ?? 'Indexing PDFs failed';
          log?.call('PDF index of $path failed: ${failures[key]}');
      }
    } catch (e) {
      failures[key] = '$e';
      log?.call('PDF index of $path failed: $e');
    } finally {
      _pdfRun = null;
      _pdfBusy = false;
      _pdfKey = null;
      progress.remove(key);
      if (attach) {
        // The core attaches the published snapshot when it is given the sources again (the phone's onIndexReady).
        try {
          dispatcher.handle('setSources', {'sources': _sources, 'extra': extra});
        } catch (_) {}
      }
      if (_timer != null) kick();
    }
  }

  /// Sends the host's duty to the running seal or index_source job when it changes (and every 15 ticks, so a lost set does not
  /// hold the job for ever), as the phone's CoreIndexRun does.
  void _pace(int job) {
    final l = load;
    if (l == null || !_paced) return;
    final d = l.duty();
    _noteHold(d);
    if (_sent == d && ++_paceTicks % 15 != 0) return;
    _sent = d;
    try {
      dispatcher.handle('jobSet', {'job': job, 'pace': d.pace()});
    } catch (_) {}
  }

  // ---- The queue, the stuck watchdog and retry (parity row 82: the browser's index queue sheet) ----

  void _markFinished(String key) {
    _finished.remove(key);
    _finished[key] = _counts[key] ?? (done: null, total: null);
    _finishedAt[key] = clock();
  }

  /// The redo rule (the phone's): work that finished and is listed again within [redoWithin], more than twice in a row, is stuck.
  /// True when [key] was just marked stuck (do not start it). Work about to start again is no longer "done".
  bool _redoStuck(String key) {
    final at = _finishedAt.remove(key);
    if (at != null) {
      if (clock().difference(at) > redoWithin) {
        _redo.remove(key);
      } else {
        final n = _redo[key] = (_redo[key] ?? 0) + 1;
        if (n > 2) {
          _redo.remove(key);
          _finished.remove(key);
          stuck[key] = 'Finished, but asked to run again at once';
          log?.call('index work $key finished but was listed again at once, $n times; stopped as stuck');
          return true;
        }
      }
    }
    _finished.remove(key);
    return false;
  }

  String? get _runningKey => _job != null ? _jobPath : (_pdfBusy ? _pdfKey : null);

  String? _watchKey;
  DateTime _watchNext = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLook = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastPulse = '';
  Duration _quiet = Duration.zero;

  String _pulse(String key) {
    final c = _counts[key];
    return '${progress[key]}|${c?.done}|${c?.total}';
  }

  /// The watchdog (the phone's IndexScheduler._watchdog): every [watchEvery], running work whose progress has not changed for
  /// [stuckAfter] of working time (time the host holds the work, or the person's Pause, does not count) is stopped and marked
  /// stuck; the queue moves on without it. Public so a test can drive it with its own [clock].
  void watchdog() {
    final key = _runningKey;
    final now = clock();
    if (key == null || stuck.containsKey(key)) {
      _watchKey = null;
      return;
    }
    if (_watchKey != key) {
      _watchKey = key;
      _lastLook = now;
      _watchNext = now.add(watchEvery);
      _lastPulse = _pulse(key);
      _quiet = Duration.zero;
      return;
    }
    if (now.isBefore(_watchNext)) return;
    _watchNext = now.add(watchEvery);
    final since = now.difference(_lastLook);
    _lastLook = now;
    final p = _pulse(key);
    if (p != _lastPulse) {
      _lastPulse = p;
      _quiet = Duration.zero;
      return;
    }
    if (_hold != null || _paused) return;
    _quiet += since;
    if (_quiet < stuckAfter) return;
    stuck[key] = 'No progress for ${stuckAfter.inMinutes} min';
    log?.call('index work $key is stuck: no progress for ${stuckAfter.inMinutes} min of working time; skipped for now');
    _watchKey = null;
    final job = _job;
    if (job != null && _jobPath == key) {
      try {
        dispatcher.handle('jobCancel', {'job': job});
      } catch (_) {}
    } else {
      _pdfRun?.cancel();
    }
  }

  /// Tries a stuck or failed piece of work again (the queue sheet's Retry): the mark is cleared and it goes back in the queue.
  /// False when [key] was neither stuck nor failed.
  bool retry(String key) {
    final was = stuck.remove(key) != null;
    final failed = failures.remove(key) != null;
    if (!was && !failed) return false;
    _tried.remove(key);
    _redo.remove(key);
    _finishedAt.remove(key);
    log?.call('index work $key: retry');
    kick();
    return true;
  }

  static String _stepOf(String key) {
    if (key.startsWith('seal:')) return 'seal';
    if (key.startsWith('zim-epub/')) return 'epubs';
    if (key.startsWith('captions/') || key.startsWith('zim-captions/')) return 'captions';
    if (key.startsWith('zim-pdf/')) return 'pdfs';
    return 'keywords';
  }

  /// The queue for `index.state`'s `_queue`: the running item first, then what [_candidates] would take (in that order), then
  /// what finished this session, then stuck, then failed. Starts nothing and changes nothing.
  Map<String, dynamic> queue() {
    Map<String, dynamic> item(String key, String state, ({int? done, int? total})? c) => {'key': key, 'state': state, 'done': c?.done, 'total': c?.total, 'step': _stepOf(key)};
    final items = <Map<String, dynamic>>[];
    final listed = <String>{};
    final run = _runningKey;
    if (run != null && !stuck.containsKey(run)) {
      items.add(item(run, 'running', _counts[run]));
      listed.add(run);
    }
    final waiting = _waiting;
    try {
      final status = _readStatus();
      for (final w in _candidates(status)) {
        final k = w.key ?? w.source['path'] as String;
        if (listed.add(k)) items.add(item(k, 'queued', null));
      }
      for (final w in _pdfCandidates(status)) {
        if (listed.add(w.key)) items.add(item(w.key, 'queued', null));
      }
    } catch (_) {
      // Not open yet: nothing queued to list.
    } finally {
      _waiting = waiting;
    }
    for (final e in _finished.entries) {
      if (listed.add(e.key)) items.add(item(e.key, 'done', e.value));
    }
    for (final k in stuck.keys) {
      if (listed.add(k)) items.add(item(k, 'stuck', _counts[k]));
    }
    for (final k in failures.keys) {
      if (listed.add(k)) items.add(item(k, 'failed', _counts[k]));
    }
    return {'items': items, 'done': items.where((i) => i['state'] == 'done').length, 'total': items.length};
  }

  Map<String, dynamic> get _indexRoot {
    final root = extra['indexes_dir'];
    return root is String && root.isNotEmpty ? {'indexes_dir': root} : const {};
  }

  void _start(Map<String, dynamic> source, String kind, Map<String, dynamic> params, {String? key}) {
    final path = key ?? source['path'] as String;
    _tried.add(path);
    _counts.remove(path);
    final paced = kind == 'index_seal' || kind == 'index_source';
    final duty = paced ? load?.duty() : null;
    try {
      _job = dispatcher.handle('jobStart', {'kind': kind, 'params': {...params, if (duty != null && !duty.paused) 'duty': {'work_ms': duty.workMs, 'idle_ms': duty.idleMs}}}) as int;
      _paced = paced;
      _sent = duty;
      _paceTicks = 0;
      _jobPath = path;
      progress[path] = null;
      log?.call('indexing $path ($kind)');
    } on CacheSearchException catch (e) {
      // "busy": another job holds the index folder; it is picked up at the next rescan (as on the phone).
      if (e.code != 'busy') failures[path] = e.message;
      log?.call('index of $path not started: ${e.code}: ${e.message}');
    }
  }
}

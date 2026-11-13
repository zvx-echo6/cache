import 'dart:async';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/models.dart';
import 'host_load.dart';
import 'pdf_zim_indexer.dart';

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
///   files of a ZIM (`epubindex` and `captionsindex` with `needs_build`), with the same parameters; videos' captions need saved
///   videos, which the server has none of;
/// - the PDFs inside a ZIM that has none searchable yet (cs_status `pdfindex` is not ready): [ZimPdfIndexer] reads each PDF with
///   MuPDF (the pdfrx loop needs Flutter) and makes the same core calls, so the snapshot is the phone's format.
/// Order: a ZIM or library's keyword index, then seals, then EPUBs and captions, then PDFs; one job at a time.
/// The phone's throttle has a hook here too, as far as a server has one ([HostLoad]): `index_seal`, `index_source` and the PDF loop
/// follow the host's heat and memory (jobs through cs_job_set, the PDF loop between PDFs); with [load] null there is no yield.
///
/// A ZIM that is stale is indexed again as well. A source is tried once for each [useSources] call (open or rescan), so a source
/// whose index cannot be built does not start over in a loop; a failure is kept in [failures] until the next rescan.
///
/// The helper is single-threaded and answers one line at a time, so a timer tick never overlaps a request.
class IndexDriver {
  IndexDriver(this.dispatcher, {this.log, this.every = const Duration(seconds: 1), this.extra = const {}, this.load, this.pdf}) : _pacer = IndexPacer(load);

  final CoreDispatcher dispatcher;

  /// App configuration retained across source refreshes and shared-index builds.
  final Map<String, dynamic> extra;
  final void Function(String message)? log;
  final Duration every;

  /// The host's heat and memory, which index_seal, index_source and the PDF loop yield to; null: no yield.
  final HostLoad? load;

  /// The PDF reader and the indexes folder, for the PDFs inside ZIMs; null: they are not indexed.
  final PdfWork? pdf;
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
  Timer? _timer;

  /// Set by [_next] when a source that will want indexing is still opening, building or updating: the timer must keep running
  /// until it settles, or the index is never started (the library is usually still opening on the first tick after a rescan).
  bool _waiting = false;

  /// The running job's key in the dispatcher, its source path and what it is.
  int? _job;
  String? _jobPath;

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
      final next = _next();
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
      log?.call('index of $path ${p.state.name}');
    }
    // A source whose index was being built is picked up again when the list is set again (SourcesState._pollJobs).
    dispatcher.handle('setSources', {'sources': _sources, 'extra': extra});
  }

  ({Map<String, dynamic> source, String kind, Map<String, dynamic> params, String? key})? _next() {
    final status = <String, Map<String, dynamic>>{
      for (final s in (dispatcher.handle('status', const {}) as List)) (s as Map)['path'] as String: s.cast<String, dynamic>(),
    };
    _waiting = false;
    _status = status;
    for (final src in _sources) {
      final path = src['path'] as String;
      if (_tried.contains(path) || failures.containsKey(path)) continue;
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
        return (
          source: src,
          kind: 'index_library',
          params: {'library_path': path, 'index_dir': src['index_dir'], ..._indexRoot, 'heap_mb': 200, 'settings': ?settings},
          key: null,
        );
      }
      final searchable = s['id'] != null && s['indexed'] == true;
      if (searchable && s['stale'] != true) continue;
      return (source: src, kind: 'index_zim', params: {'zim_path': path, 'index_dir': src['index_dir'], ..._indexRoot, 'heap_mb': 200}, key: null);
    }
    return _nextCoreWork(status);
  }

  /// The core's own index work the phone's AppIndexCoreCalls.needs lists: seals first, then the EPUBs and caption files of ZIMs.
  ({Map<String, dynamic> source, String kind, Map<String, dynamic> params, String? key})? _nextCoreWork(Map<String, Map<String, dynamic>> status) {
    final root = _indexRoot;
    if (root.isEmpty) return null;
    for (final src in _sources) {
      final s = status[src['path'] as String];
      if (s == null || s['error'] != null || s['building'] == true || s['opening'] == true || s['updating'] == true) continue;
      final index = (s['index'] as Map?)?.cast<String, dynamic>();
      final id = s['source_id'] as String?;
      final kind = index?['kind'];
      final key = 'seal:$kind/$id';
      if (index != null && index['needs_seal'] == true && id != null && (kind == 'zim' || kind == 'library') && !_tried.contains(key) && !failures.containsKey(key)) {
        return (source: src, kind: 'index_seal', params: {...root, 'kind': kind, 'source_id': id, 'index_dir': ?index['dir']}, key: key);
      }
    }
    for (final src in _sources) {
      final s = status[src['path'] as String];
      if (s == null || s['error'] != null || s['building'] == true || s['opening'] == true || s['updating'] == true) continue;
      for (final sub in [s['captionsindex'], s['epubindex']]) {
        if (sub is! Map || sub['needs_build'] != true || sub['kind'] == null) continue;
        final id = (sub['source_id'] ?? s['source_id']) as String?;
        final key = '${sub['kind']}/$id';
        if (id == null || _tried.contains(key) || failures.containsKey(key)) continue;
        return (source: src, kind: 'index_source', params: {...root, 'kind': sub['kind'], 'source_id': id}, key: key);
      }
    }
    return null;
  }

  /// Starts the PDF run for the next ZIM whose PDFs are not searchable yet (the phone's PdfIndexState.needsIndex); false when
  /// there is none, or the core has no PDF index calls.
  bool _startPdf() {
    final w = pdf;
    final next = _nextPdf();
    if (w == null || next == null) return false;
    _tried.add(next.key);
    _pdfBusy = true;
    unawaited(_runPdf(w, next.path, next.id, next.key));
    return true;
  }

  /// The next ZIM whose PDFs are still to be indexed, from the status [_next] last read; null when there is none or the core has
  /// no PDF index calls. Starts nothing.
  ({String path, String id, String key})? _nextPdf() {
    final w = pdf;
    if (w == null || !w.core.available) return null;
    for (final src in _sources) {
      if (src['kind'] == 'library') continue;
      final path = src['path'] as String;
      final s = _status[path];
      final id = s?['id'] as String?;
      if (s == null || id == null || s['error'] != null || s['building'] == true || s['opening'] == true || s['updating'] == true) continue;
      final state = (s['pdfindex'] as Map?)?['state'];
      if (state == 'ready' || state == 'opening') continue;
      final key = 'zim-pdf/$id';
      if (_tried.contains(key) || failures.containsKey(key) || _pdfCounts['$path|$id'] == 0) continue;
      return (path: path, id: id, key: key);
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
      final watch = Timer.periodic(const Duration(seconds: 1), (_) => progress[key] = run.fraction);
      final ZimPdfEnd end;
      try {
        end = await run.run(list);
      } finally {
        watch.cancel();
      }
      switch (end) {
        case ZimPdfEnd.finished:
          attach = true;
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

  Map<String, dynamic> get _indexRoot {
    final root = extra['indexes_dir'];
    return root is String && root.isNotEmpty ? {'indexes_dir': root} : const {};
  }

  void _start(Map<String, dynamic> source, String kind, Map<String, dynamic> params, {String? key}) {
    final path = key ?? source['path'] as String;
    _tried.add(path);
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

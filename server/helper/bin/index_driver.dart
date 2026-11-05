import 'dart:async';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../../../packages/cache_search/lib/src/models.dart';

/// Starts and drives the core's index jobs on the server, one at a time. On the phone SourcesState does this (it is not used in the
/// browser, because the device owns the sources); the browser only reads the status.
///
/// What it mirrors:
/// - the choice of what to index is SourcesState._refreshOnce (a ZIM that has an id... is not searchable, has no error, is not
///   being built and has no job of ours) and LibrariesState._resumeIndexes (a library that is not indexed, unless its settings
///   turn the keyword index off);
/// - the jobs are SourcesState._startIndex (`index_zim` with `heap_mb` 200) and LibrariesState._indexInstalled (`index_library`);
/// - the polling and the "give the core the list again when a job ends" step are SourcesState._pollJobs.
/// A ZIM that is stale is indexed again as well. A source is tried once for each [useSources] call (open or rescan), so a source
/// whose index cannot be built does not start over in a loop; a failure is kept in [failures] until the next rescan.
///
/// The helper is single-threaded and answers one line at a time, so a timer tick never overlaps a request.
class IndexDriver {
  IndexDriver(this.dispatcher, {this.log, this.every = const Duration(seconds: 1), this.extra = const {}});

  final CoreDispatcher dispatcher;

  /// App configuration retained across source refreshes and shared-index builds.
  final Map<String, dynamic> extra;
  final void Function(String message)? log;
  final Duration every;

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

  bool get busy => _job != null;

  /// Whether the timer is running (it stops when nothing is left to start or wait for).
  bool get running => _timer != null;

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One step: advance the running job, or start the next one. Public so a test can drive it.
  void tick() {
    try {
      if (_job != null) {
        _advance();
        if (_job != null) return;
      }
      final next = _next();
      if (next == null) {
        // Nothing to start now. Keep ticking while a source is still settling; stop only when all are done or not wanted.
        if (!_waiting) stop();
        return;
      }
      _start(next.source, next.kind, next.params);
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
      progress.remove(path);
      return;
    }
    progress[path] = p.fraction;
    if (!p.isFinished) return;
    try {
      dispatcher.handle('jobFree', {'job': job});
    } catch (_) {}
    _job = null;
    _jobPath = null;
    progress.remove(path);
    if (p.state == JobState.failed) {
      failures[path] = p.errorMessage ?? 'Indexing failed';
      log?.call('index of $path failed: ${failures[path]}');
    } else {
      log?.call('index of $path ${p.state.name}');
    }
    // A source whose index was being built is picked up again when the list is set again (SourcesState._pollJobs).
    dispatcher.handle('setSources', {'sources': _sources, 'extra': extra});
  }

  ({Map<String, dynamic> source, String kind, Map<String, dynamic> params})? _next() {
    final status = <String, Map<String, dynamic>>{
      for (final s in (dispatcher.handle('status', const {}) as List)) (s as Map)['path'] as String: s.cast<String, dynamic>(),
    };
    _waiting = false;
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
        );
      }
      final searchable = s['id'] != null && s['indexed'] == true;
      if (searchable && s['stale'] != true) continue;
      return (source: src, kind: 'index_zim', params: {'zim_path': path, 'index_dir': src['index_dir'], ..._indexRoot, 'heap_mb': 200});
    }
    return null;
  }

  Map<String, dynamic> get _indexRoot {
    final root = extra['indexes_dir'];
    return root is String && root.isNotEmpty ? {'indexes_dir': root} : const {};
  }

  void _start(Map<String, dynamic> source, String kind, Map<String, dynamic> params) {
    final path = source['path'] as String;
    _tried.add(path);
    try {
      _job = dispatcher.handle('jobStart', {'kind': kind, 'params': params}) as int;
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

import 'dart:async';

import 'package:cache_search/cache_search.dart' show CacheSearchException, CoreJobHandle, DownloadedVideo, JobProgress, JobState, SourceStatus;
import 'package:flutter/foundation.dart';

import 'index_scheduler.dart';
import 'index_throttle.dart';

/// The app's core index work, set at start; null in tests that do not need it (the Library then shows no EPUB progress).
AppIndexCoreCalls? coreIndexShared;

/// A core job as the index work sees it (the real one is a CoreJobHandle; tests give a fake).
abstract class IndexJob {
  Future<JobProgress> progress();
  Future<void> cancel();
  Future<void> free();

  /// cs_job_set: {"work_ms","idle_ms","paused"} at the job's next pace point (about a second).
  Future<void> pace(Map<String, Object?> pace);
}

/// [IndexJob] over the search core's job handle.
class CoreIndexJob implements IndexJob {
  CoreIndexJob(this.handle);

  final CoreJobHandle handle;

  @override
  Future<JobProgress> progress() => handle.progress();

  @override
  Future<void> cancel() => handle.cancel();

  @override
  Future<void> free() => handle.free();

  @override
  Future<void> pace(Map<String, Object?> pace) => handle.set(pace);
}

/// Starts a core job ([kind], [params]); null when the core is not open.
typedef IndexJobStarter = Future<IndexJob?> Function(String kind, Map<String, Object?> params);

/// The core's own index work: the caption files and EPUBs of each ZIM whose cs_status `captionsindex` or `epubindex` says
/// needs_build, and each saved video whose `captions_index` says so, built with cs_job_start("index_source"); and each ZIM or
/// library whose keyword index is still in the old place (`index.needs_seal`), moved into a snapshot with "index_seal". A seal
/// that fails index_missing (nothing to move) or index_stale (an unfinished or old-format index: the source's own index job
/// builds it again) is not tried again this session, and says nothing. Progress of the running job is in [progress], by
/// `<kind>/<source id>` (what the Library shows: "Making EPUBs searchable: 40 of 85"). Every job starts with the throttle's
/// duty ([duty]) and follows it through cs_job_set.
class AppIndexCoreCalls implements IndexCoreCalls {
  AppIndexCoreCalls({
    required this.statuses,
    required this.videos,
    required this.startJob,
    required this.indexesDir,
    this.videoDir,
    this.duty,
    this.poll = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Jobs the core said "busy" to (a writer or a merge still at work on that index, another job on it): tried again on a later
  /// pass, not before this time; the wait doubles each time, 30 s up to 10 min. Never shown as a failure.
  final Map<String, (DateTime, Duration)> _later = {};

  bool _waits(String key) {
    final l = _later[key];
    return l != null && _clock().isBefore(l.$1);
  }

  /// The throttle's duty now (cs_job_start's "duty"; the core's own default is gentle).
  final IndexDuty Function()? duty;

  /// Seals that will not work (index_missing, index_stale), by key: not listed again this session.
  final Set<String> _skip = {};

  final Iterable<SourceStatus> Function() statuses;
  final List<DownloadedVideo> Function() videos;
  final IndexJobStarter startJob;
  final String? Function() indexesDir;

  /// The saved videos' folder (index_source's video_dir for captions; the core finds it anyway when a handle has it).
  final String? Function()? videoDir;
  final Duration poll;

  /// The running job's progress (done, total), by key.
  final ValueNotifier<Map<String, (int, int)>> progress = ValueNotifier(const {});

  /// The running job's step and place in it ("merge 0 of 1"), by key: its sign of life for the scheduler's watchdog.
  final Map<String, String> pulse = {};

  @override
  Future<List<CoreIndexNeed>> needs() async {
    if (indexesDir() == null) return const [];
    return [
      for (final s in statuses())
        if (s.index case final i? when i.needsSeal && s.sourceId != null && (i.kind == 'zim' || i.kind == 'library') && !_skip.contains('${i.kind}/${s.sourceId}') && !_waits('${i.kind}/${s.sourceId}'))
          CoreIndexNeed(kind: i.kind!, sourceId: s.sourceId!, seal: true, indexDir: i.dir, title: s.title, pulse: () => pulse['${i.kind}/${s.sourceId}']),
      for (final s in statuses())
        for (final sub in [s.captionsIndex, s.epubIndex])
          if (sub != null && sub.needsBuild == true && sub.kind != null && (sub.sourceId ?? s.sourceId) != null && !_waits('${sub.kind}/${sub.sourceId ?? s.sourceId}'))
            CoreIndexNeed(
              kind: sub.kind!,
              sourceId: (sub.sourceId ?? s.sourceId)!,
              seal: false,
              size: sub.entries ?? 0,
              title: s.title,
              progress: () => progress.value['${sub.kind}/${sub.sourceId ?? s.sourceId}'],
              pulse: () => pulse['${sub.kind}/${sub.sourceId ?? s.sourceId}'],
            ),
      for (final v in videos())
        if (v.captionsIndex case final c? when c.needsBuild && c.sourceId.isNotEmpty && !_waits('captions/${c.sourceId}'))
          CoreIndexNeed(kind: 'captions', sourceId: c.sourceId, seal: false, size: c.files, title: v.title, progress: () => progress.value['captions/${c.sourceId}'], pulse: () => pulse['captions/${c.sourceId}']),
    ];
  }

  @override
  Future<IndexRun> start(CoreIndexNeed need) async {
    final dir = indexesDir();
    if (dir == null) throw StateError('no indexes folder');
    final vd = videoDir?.call();
    final d = duty?.call();
    final pace = d == null || d.paused ? null : {'work_ms': d.workMs, 'idle_ms': d.idleMs, 'threads': ?d.threads};
    final key = '${need.kind}/${need.sourceId}';
    final IndexJob? job;
    try {
      job = await startJob(need.seal ? 'index_seal' : 'index_source', {
        'indexes_dir': dir,
        'kind': need.kind,
        'source_id': need.sourceId,
        if (need.seal && need.indexDir != null) 'index_dir': need.indexDir,
        if (need.kind == 'captions' && vd != null) 'video_dir': vd,
        'duty': ?pace,
      });
    } on CacheSearchException catch (e) {
      // Busy (another job or a writer on that index): a later pass, after a wait.
      if (e.code == 'busy') _backOff(key);
      rethrow;
    }
    if (job == null) throw StateError('the search core is not open');
    debugPrint('Index job $key starts (${need.seal ? 'index_seal' : 'index_source'})');
    return CoreIndexRun(job, key, progress, pulse: pulse, poll: poll, onError: (code) {
      if (need.seal && (code == 'index_missing' || code == 'index_stale')) _skip.add(key);
      if (code == 'busy') _backOff(key);
    }, onDone: () => _later.remove(key));
  }

  void _backOff(String key) {
    final prev = _later[key]?.$2;
    final wait = prev == null ? const Duration(seconds: 30) : (prev * 2 > const Duration(minutes: 10) ? const Duration(minutes: 10) : prev * 2);
    _later[key] = (_clock().add(wait), wait);
  }
}

/// One index job: finished when it is done (true) or stopped (false). Its progress goes to the shared map while it runs. The
/// throttle's duty reaches it through cs_job_set at its next pace point: a pause holds it there (nothing is lost), a duty sets its
/// bursts and rests.
class CoreIndexRun implements IndexRun {
  CoreIndexRun(this.job, this.key, this.progress, {Map<String, String>? pulse, Duration poll = const Duration(seconds: 1), this.onError, this.onDone})
      : pulse = pulse ?? {} {
    _timer = Timer.periodic(poll, (_) => _check());
    unawaited(_check());
  }

  final IndexJob job;
  final String key;
  final ValueNotifier<Map<String, (int, int)>> progress;

  /// The job's step and place in it, by key (see [AppIndexCoreCalls.pulse]).
  final Map<String, String> pulse;

  /// The error code of a job that failed.
  final void Function(String code)? onError;

  /// The job finished.
  final void Function()? onDone;
  final Completer<bool> _done = Completer<bool>();
  late final Timer _timer;
  bool _checking = false;

  /// The last duty sent (cs_job_set), sent again now and then: a set that was lost (a pause whose "go on" never arrived) must
  /// not hold the job for ever.
  Map<String, Object?>? _pace;
  int _polls = 0;

  Future<void> _check() async {
    if (_done.isCompleted || _checking) return;
    _checking = true;
    try {
      final p = await job.progress();
      if (p.state == JobState.running) {
        if (++_polls % 15 == 0 && _pace != null) {
          unawaited(job.pace(_pace!).catchError((Object e) => debugPrint('Index job $key: $e')));
        }
        pulse[key] = '${p.phase} ${p.done} of ${p.total}';
        // What the person can follow: the look through the library's entries ("scan"), then the items read ("read" counts
        // the caption files or EPUBs).
        if (p.phase == null || p.phase == 'read' || p.phase == 'scan') progress.value = {...progress.value, key: (p.done, p.total)};
        return;
      }
      if (p.state == JobState.failed && p.errorCode != null) onError?.call(p.errorCode!);
      if (p.state == JobState.done) onDone?.call();
      debugPrint('Index job $key ends: ${p.state.name}${p.errorCode == null ? '' : ' (${p.errorCode})'}');
      _end(p.state == JobState.done);
    } catch (e) {
      debugPrint('Index job $key: $e');
      _end(false);
    } finally {
      _checking = false;
    }
  }

  void _end(bool ok) {
    if (_done.isCompleted) return;
    _timer.cancel();
    progress.value = {...progress.value}..remove(key);
    pulse.remove(key);
    unawaited(job.free());
    _done.complete(ok);
  }

  @override
  Future<bool> get finished => _done.future;

  /// The job stops (cs_job_cancel is honoured until it publishes) and keeps what it did.
  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    if (_done.isCompleted) return;
    await job.cancel();
    await _check();
  }

  /// cs_job_set: paused holds the job at its next pace point; otherwise its bursts and rests (an explicit set always wins over the
  /// core's own back-off). Writer threads are fixed when the job starts.
  @override
  void setDuty(IndexDuty duty) {
    if (_done.isCompleted) return;
    final pace = duty.paused ? {'paused': true} : {'work_ms': duty.workMs, 'idle_ms': duty.idleMs, 'paused': false};
    _pace = pace;
    unawaited(job.pace(pace).catchError((Object e) => debugPrint('Index job $key: $e')));
  }
}

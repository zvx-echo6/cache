import 'dart:async';

import 'package:cache_search/cache_search.dart' show CoreJobHandle, DownloadedVideo, JobProgress, JobState, SourceStatus;
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
}

/// Starts a core job ([kind], [params]); null when the core is not open.
typedef IndexJobStarter = Future<IndexJob?> Function(String kind, Map<String, Object?> params);

/// The core's own index work, for real: the caption files and EPUBs of each ZIM whose cs_status `captionsindex` or `epubindex`
/// says needs_build, and each saved video whose `captions_index` says so, built with cs_job_start("index_source"). Progress of
/// the running job is in [progress], by `<kind>/<source id>` (what the Library shows: "Making EPUBs searchable: 40 of 85").
/// index_seal (indexes built before snapshots) is not in this core yet.
class AppIndexCoreCalls implements IndexCoreCalls {
  AppIndexCoreCalls({
    required this.statuses,
    required this.videos,
    required this.startJob,
    required this.indexesDir,
    this.videoDir,
    this.poll = const Duration(seconds: 1),
  });

  final Iterable<SourceStatus> Function() statuses;
  final List<DownloadedVideo> Function() videos;
  final IndexJobStarter startJob;
  final String? Function() indexesDir;

  /// The saved videos' folder (index_source's video_dir for captions; the core finds it anyway when a handle has it).
  final String? Function()? videoDir;
  final Duration poll;

  /// The running job's progress (done, total), by key.
  final ValueNotifier<Map<String, (int, int)>> progress = ValueNotifier(const {});

  @override
  Future<List<CoreIndexNeed>> needs() async {
    if (indexesDir() == null) return const [];
    return [
      for (final s in statuses())
        for (final sub in [s.captionsIndex, s.epubIndex])
          if (sub != null && sub.needsBuild == true && sub.kind != null && (sub.sourceId ?? s.sourceId) != null)
            CoreIndexNeed(kind: sub.kind!, sourceId: (sub.sourceId ?? s.sourceId)!, seal: false, size: sub.entries ?? 0),
      for (final v in videos())
        if (v.captionsIndex case final c? when c.needsBuild && c.sourceId.isNotEmpty)
          CoreIndexNeed(kind: 'captions', sourceId: c.sourceId, seal: false, size: c.files),
    ];
  }

  @override
  Future<IndexRun> start(CoreIndexNeed need) async {
    final dir = indexesDir();
    if (dir == null) throw StateError('no indexes folder');
    final vd = videoDir?.call();
    final job = await startJob('index_source', {
      'indexes_dir': dir,
      'kind': need.kind,
      'source_id': need.sourceId,
      if (need.kind == 'captions' && vd != null) 'video_dir': vd,
    });
    if (job == null) throw StateError('the search core is not open');
    return CoreIndexRun(job, '${need.kind}/${need.sourceId}', progress, poll: poll);
  }
}

/// One index_source job: finished when it is done (true) or stopped (false). Its progress goes to the shared map while it runs.
/// The core's cs_job_set is not in this core yet, so a paused duty (heat, a low battery, the model generating) cancels the job,
/// which keeps what it did and goes on from there when the scheduler starts it again; a running duty changes nothing yet.
class CoreIndexRun implements IndexRun {
  CoreIndexRun(this.job, this.key, this.progress, {Duration poll = const Duration(seconds: 1)}) {
    _timer = Timer.periodic(poll, (_) => _check());
    unawaited(_check());
  }

  final IndexJob job;
  final String key;
  final ValueNotifier<Map<String, (int, int)>> progress;
  final Completer<bool> _done = Completer<bool>();
  late final Timer _timer;
  bool _checking = false;

  Future<void> _check() async {
    if (_done.isCompleted || _checking) return;
    _checking = true;
    try {
      final p = await job.progress();
      if (p.state == JobState.running) {
        // The items read are what the person can follow ("read" counts the caption files or EPUBs).
        if (p.phase == null || p.phase == 'read') progress.value = {...progress.value, key: (p.done, p.total)};
        return;
      }
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

  @override
  void setDuty(IndexDuty duty) {
    if (duty.paused) unawaited(pause());
  }
}

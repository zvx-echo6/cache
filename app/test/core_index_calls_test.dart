import 'package:cache/search/core_index_calls.dart';
import 'package:cache/search/epub_index_row.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart';
import 'package:cache/search/indexes_share.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

class _Job implements IndexJob {
  JobProgress now = const JobProgress(state: JobState.running, done: 0, total: 85, phase: 'read');
  int cancels = 0;
  bool freed = false;
  final List<Map<String, Object?>> paces = [];

  @override
  Future<void> pace(Map<String, Object?> pace) async => paces.add(pace);

  @override
  Future<JobProgress> progress() async => now;

  @override
  Future<void> cancel() async {
    cancels++;
    now = JobProgress(state: JobState.cancelled, done: now.done, total: now.total);
  }

  @override
  Future<void> free() async => freed = true;
}

SourceStatus _zim(String uuid, {Map<String, dynamic>? captions, Map<String, dynamic>? epub, Map<String, dynamic>? index}) => SourceStatus.fromJson({
      'id': uuid,
      'kind': 'zim',
      'path': '/z/$uuid.zim',
      'title': uuid,
      'indexed': true,
      'docs': 1,
      'source_id': uuid,
      'captionsindex': ?captions,
      'index': ?index,
      'epubindex': ?epub,
    });

DownloadedVideo _video(String uuid, {Map<String, dynamic>? captions}) => DownloadedVideo.fromJson({
      'instance': 'peertube.example',
      'uuid': uuid,
      'title': uuid,
      'size': 1,
      'path': '/v/$uuid.mp4',
      'captions_index': ?captions,
    });

Future<void> _ticks() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late List<SourceStatus> statuses;
  late List<DownloadedVideo> videos;
  late List<(String, Map<String, Object?>)> started;
  late _Job job;
  late AppIndexCoreCalls calls;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 11, 2, 12);
    statuses = [];
    videos = [];
    started = [];
    job = _Job();
    calls = AppIndexCoreCalls(
      statuses: () => statuses,
      videos: () => videos,
      startJob: (kind, params) async {
        started.add((kind, params));
        return job;
      },
      indexesDir: () => '/s/shared-indexes',
      videoDir: () => '/v',
      duty: () => IndexDuty.share(2 / 3, threads: 1),
      poll: const Duration(milliseconds: 10),
      clock: () => now,
    );
  });

  test("the work: each ZIM's caption files and EPUBs that need a build, and each saved video's captions", () async {
    statuses = [
      _zim('u1', captions: {'state': 'none', 'kind': 'zim-captions', 'source_id': 'u1', 'entries': 12, 'needs_build': true}, epub: {'state': 'ready', 'kind': 'zim-epub', 'source_id': 'u1', 'needs_build': false}),
      _zim('u2', epub: {'state': 'none', 'kind': 'zim-epub', 'source_id': 'u2', 'entries': 85, 'needs_build': true}),
      // Not looked at yet: no needs_build, nothing to do yet.
      _zim('u3', epub: {'state': 'none', 'kind': 'zim-epub', 'source_id': 'u3'}),
    ];
    videos = [
      _video('v1', captions: {'source_id': 'peertube.example/v1', 'kind': 'captions', 'files': 2, 'built': false, 'needs_build': true}),
      _video('v2', captions: {'source_id': 'peertube.example/v2', 'kind': 'captions', 'files': 1, 'built': true, 'needs_build': false}),
      _video('v3'),
    ];
    final tasks = await CoreIndexWork(calls).pending();
    expect([for (final t in tasks) t.key], ['zim-captions/u1', 'zim-epub/u2', 'captions/peertube.example/v1']);
    expect([for (final t in tasks) t.size], [12, 85, 2]);
    expect(tasks.every((t) => t.long), isTrue);
    await tasks.last.start();
    expect(started.single.$1, 'index_source');
    expect(started.single.$2, {
      'indexes_dir': '/s/shared-indexes',
      'kind': 'captions',
      'source_id': 'peertube.example/v1',
      'video_dir': '/v',
      'duty': {'work_ms': 2000, 'idle_ms': 1000, 'threads': 1},
    });
  });

  test('no indexes folder, no work', () async {
    calls = AppIndexCoreCalls(statuses: () => [_zim('u2', epub: {'kind': 'zim-epub', 'source_id': 'u2', 'needs_build': true})], videos: () => const [], startJob: (k, p) async => job, indexesDir: () => null);
    expect(await calls.needs(), isEmpty);
  });

  test('a run: its progress while it reads, finished when done, and the job freed', () async {
    final run = await calls.start(const CoreIndexNeed(kind: 'zim-epub', sourceId: 'u2', seal: false));
    job.now = const JobProgress(state: JobState.running, done: 40, total: 85, phase: 'read');
    await _ticks();
    expect(calls.progress.value['zim-epub/u2'], (40, 85));
    expect(epubLine(const ZimSubIndex(state: 'none', needsBuild: true), calls.progress.value['zim-epub/u2']), 'Making EPUBs searchable: 40 of 85');
    job.now = const JobProgress(state: JobState.done, done: 85, total: 85);
    expect(await run.finished.timeout(const Duration(seconds: 2)), isTrue);
    expect(calls.progress.value, isEmpty);
    expect(job.freed, isTrue);
  });

  test("the throttle's duty reaches a running job through cs_job_set; the scheduler's pause cancels it (it keeps what it did)", () async {
    var run = await calls.start(const CoreIndexNeed(kind: 'zim-epub', sourceId: 'u2', seal: false));
    run.setDuty(IndexDuty.share(0.2, workMs: 1000));
    run.setDuty(const IndexDuty(workMs: 0, idleMs: 0, paused: true, hold: IndexHold.heat));
    run.setDuty(IndexDuty.share(2 / 3));
    await _ticks();
    expect(job.paces, [
      {'work_ms': 1000, 'idle_ms': 4000, 'paused': false},
      {'paused': true},
      {'work_ms': 2000, 'idle_ms': 1000, 'paused': false},
    ], reason: 'a pause holds the job at its next pace point; it is not cancelled');
    expect(job.cancels, 0);
    await run.pause(IndexWait.charging);
    expect(job.cancels, 1);
    expect(await run.finished.timeout(const Duration(seconds: 2)), isFalse);
  });

  test('index_seal: an index in the old place is moved into a snapshot; missing or stale ones are dropped quietly', () async {
    statuses = [
      _zim('u1', index: {'kind': 'zim', 'location': 'legacy', 'format': 3, 'dir': '/i/u1.idx', 'needs_seal': true}),
      _zim('u2', index: {'kind': 'zim', 'location': 'snapshot', 'snapshot': 'b1', 'format': 3}),
      SourceStatus.fromJson({
        'id': 'lib', 'kind': 'library', 'path': '/l', 'title': 'L', 'indexed': true, 'docs': 1, 'source_id': 'field-guide@2',
        'index': {'kind': 'library', 'location': 'legacy', 'dir': '/l/index', 'needs_seal': true},
      }),
    ];
    final tasks = await CoreIndexWork(calls).pending();
    expect([for (final t in tasks) t.key], ['zim/u1', 'library/field-guide@2']);
    expect(tasks.every((t) => !t.long), isTrue, reason: 'a seal links files, it is short');
    final run = await tasks.first.start();
    expect(started.single.$1, 'index_seal');
    expect(started.single.$2, {
      'indexes_dir': '/s/shared-indexes',
      'kind': 'zim',
      'source_id': 'u1',
      'index_dir': '/i/u1.idx',
      'duty': {'work_ms': 2000, 'idle_ms': 1000, 'threads': 1},
    });
    job.now = const JobProgress(state: JobState.failed, done: 0, total: 0, errorCode: 'index_missing');
    expect(await run.finished.timeout(const Duration(seconds: 2)), isFalse);
    expect([for (final t in await CoreIndexWork(calls).pending()) t.key], ['library/field-guide@2'], reason: 'not tried again');
    job = _Job();
    final r2 = await (await CoreIndexWork(calls).pending()).single.start();
    job.now = const JobProgress(state: JobState.failed, done: 0, total: 0, errorCode: 'index_stale');
    expect(await r2.finished.timeout(const Duration(seconds: 2)), isFalse);
    expect(await CoreIndexWork(calls).pending(), isEmpty);
  });

  test('busy (a writer or merge still at work on the index) is tried again on a later pass, waiting longer each time', () async {
    statuses = [_zim('u1', index: {'kind': 'zim', 'location': 'legacy', 'dir': '/i/u1.idx', 'needs_seal': true})];
    Future<void> busyOnce() async {
      job = _Job();
      final run = await (await CoreIndexWork(calls).pending()).single.start();
      job.now = const JobProgress(state: JobState.failed, done: 0, total: 0, errorCode: 'busy');
      expect(await run.finished.timeout(const Duration(seconds: 2)), isFalse);
    }

    await busyOnce();
    expect(await CoreIndexWork(calls).pending(), isEmpty, reason: 'not at once');
    now = now.add(const Duration(seconds: 31));
    await busyOnce();
    now = now.add(const Duration(seconds: 31));
    expect(await CoreIndexWork(calls).pending(), isEmpty, reason: 'the wait doubled to a minute');
    now = now.add(const Duration(seconds: 30));
    final run = await (await CoreIndexWork(calls).pending()).single.start();
    job.now = const JobProgress(state: JobState.done, done: 1, total: 1);
    expect(await run.finished.timeout(const Duration(seconds: 2)), isTrue);
  });

  test('busy when starting is a later pass too', () async {
    calls = AppIndexCoreCalls(
      statuses: () => [_zim('u1', index: {'kind': 'zim', 'location': 'legacy', 'needs_seal': true})],
      videos: () => const [],
      startJob: (k, p) async => throw const CacheSearchException('busy', 'another job builds it'),
      indexesDir: () => '/s',
      clock: () => now,
    );
    final task = (await CoreIndexWork(calls).pending()).single;
    await expectLater(task.start(), throwsA(isA<CacheSearchException>()));
    expect(await CoreIndexWork(calls).pending(), isEmpty);
  });

  test('the EPUB line', () {
    expect(epubLine(null, null), isNull);
    expect(epubLine(const ZimSubIndex(state: 'none'), null), isNull, reason: 'not looked at yet');
    expect(epubLine(const ZimSubIndex(state: 'none', needsBuild: true), null), 'Waiting to make EPUBs searchable');
    expect(epubLine(const ZimSubIndex(state: 'ready', needsBuild: false), null), 'EPUBs: searching ready');
  });

  test("the fetch list takes the saved videos' captions", () {
    expect(indexesFetchOnly(const [], savedVideos: ['peertube.example/v1']), ['captions/peertube.example%2Fv1', 'places-index', 'region-index']);
  });
}

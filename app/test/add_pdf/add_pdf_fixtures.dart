import 'dart:async';
import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_calls.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/settings/space.dart';
import 'package:cache_search/cache_search.dart';

/// The core's ingest calls, answered by the test: each call is recorded, and [on] gives the answer for an op (an exception
/// thrown there is the core's error).
class FakeIngestCalls implements IngestCalls {
  FakeIngestCalls([Map<String, FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> args)>? on]) : on = on ?? {};

  final Map<String, FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> args)> on;
  final List<(String, Map<String, dynamic>)> made = [];

  List<Map<String, dynamic>> argsOf(String op) => [for (final m in made) if (m.$1 == op) m.$2];

  @override
  Future<Map<String, dynamic>> call(String op, Map<String, dynamic> args, {bool pdfium = true}) async {
    made.add((op, args));
    // a real turn of the event loop, as a call on another isolate takes: timers (a Pause, a test's wait) get their turn
    await Future<void>.delayed(Duration.zero);
    final f = on[op];
    if (f == null) {
      return switch (op) {
        'start' => {'job': 1, 'resumed': false, 'copy': 'c' * 64, 'pages': 3},
        'cancel' => {'cancelled': true},
        'ocr' => {'accepted': ((args['pages'] as List?) ?? const []).length, 'remaining': 0},
        _ => throw CacheSearchException('not_found', 'no answer for $op'),
      };
    }
    return f(args);
  }
}

/// A step script: the statuses the core gives, one per step (the last repeats).
FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>) steps(List<Object> script) {
  var i = 0;
  return (_) {
    final s = script[i < script.length ? i : script.length - 1];
    i++;
    if (s is Exception) throw s;
    return s as Map<String, dynamic>;
  };
}

Map<String, dynamic> progress(String state, {int pages = 3, int pagesDone = 0, int pieces = 0, int piecesDone = 0, List<Map<String, dynamic>>? needsOcr, Map<String, dynamic>? result, Map<String, dynamic>? error}) => {
  'state': state,
  'progress': {'pages': pages, 'pages_done': pagesDone, 'pieces': pieces, 'pieces_done': piecesDone},
  'needs_ocr': ?needsOcr,
  'result': ?result,
  'error': ?error,
};

/// A scheduler whose answers are set by the test (the holds the progress page shows), never running anything.
class FakeScheduler extends IndexScheduler {
  FakeScheduler({this.fixed = const {}, this.runningKey, this.done = 0, this.total = 0, this.share = 0.14, BatteryReading? battery})
    : super(sources: const [], space: () => const Space(free: 100 << 30, reserve: 1 << 30)) {
    reading = battery;
  }

  Map<String, IndexItem> fixed;
  String? runningKey;
  int done;
  int total;
  double share;

  @override
  IndexItem? statusOf(String key) => fixed[key];
  @override
  List<IndexItem> get items => fixed.values.toList();
  @override
  String? get running => runningKey;
  @override
  bool get busy => total > done;
  @override
  int get doneCount => done;
  @override
  int get totalCount => total;
  @override
  double get fraction => share;
  @override
  IndexWait get reason => runningKey == null ? IndexWait.none : (fixed[runningKey]?.why ?? IndexWait.none);
}

/// A state over [dir] with [calls], no throttle and no scheduler (the test drives runs itself).
AddPdfState testAddPdfState(Directory dir, {IngestCalls? calls, Future<void> Function(AddPdfJob)? onDone}) => AddPdfState(
  calls: calls ?? FakeIngestCalls(),
  dir: () async => dir,
  engines: () async => {'pdfium_version': 'chromium/7811'},
  permit: (_) async {},
  busyWait: const Duration(milliseconds: 1),
  onDone: onDone,
);

/// A job as the progress page shows it, in whatever state the test sets.
AddPdfJob sampleJob(
  String id, {
  String title = 'Water purification manual',
  int bytes = 43 << 20,
  String state = 'reading',
  AddPdfStatus status = AddPdfStatus.active,
  int pages = 310,
  int pagesDone = 0,
  int pieces = 0,
  int piecesDone = 0,
  int scans = 0,
  int scansDone = 0,
  int scanInBatch = 0,
  String libraryTitle = 'My books',
  String libraryPath = '/tmp/my-books',
  Map<String, dynamic>? result,
  String? error,
  int? needed,
  String ocr = 'host',
  bool paused = false,
  bool busy = false,
}) {
  final j = AddPdfJob(
    id: id,
    pdfPath: '/tmp/$id.pdf',
    fileName: '$title.pdf',
    title: title,
    bytes: bytes,
    libraryPath: libraryPath,
    libraryTitle: libraryTitle,
    jobDir: '/tmp/ingest/$id',
    added: DateTime(2026, 11, 9),
    ocr: ocr,
  );
  j
    ..state = state
    ..status = status
    ..pages = pages
    ..pagesDone = pagesDone
    ..pieces = pieces
    ..piecesDone = piecesDone
    ..scans = scans
    ..scansDone = scansDone
    ..scanInBatch = scanInBatch
    ..result = result
    ..errorCode = error
    ..needed = needed
    ..pausedByPerson = paused
    ..busy = busy
    ..worked = const Duration(minutes: 1);
  return j;
}

IndexItem runningItem(AddPdfJob j, {IndexWait why = IndexWait.none, bool slowed = false}) =>
    IndexItem(key: j.key, state: IndexState.running, title: j.title, why: why, slowed: slowed, step: j.stepWords, progress: ((j.fraction * 1000).round(), 1000));

IndexItem heldItem(AddPdfJob j, IndexWait why, {int position = 1}) => IndexItem(key: j.key, state: IndexState.held, title: j.title, why: why, position: position);

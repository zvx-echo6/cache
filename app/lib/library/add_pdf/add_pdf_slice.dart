import 'dart:async';

import '../../search/index_throttle.dart';
import 'add_pdf_state.dart';

/// How long one background slice of adding PDFs runs (WorkManager stops a worker after about 10 minutes).
const Duration kAddPdfSliceBudget = Duration(minutes: 8);

/// How a slice ended.
class AddPdfSliceResult {
  const AddPdfSliceResult({required this.added, required this.stopped, required this.more, required this.why});

  /// PDFs added, and PDFs that stopped (could not be added), in this slice.
  final int added;
  final int stopped;

  /// There is more to do: the next slice carries on (a job paused mid-PDF resumes from its job folder).
  final bool more;

  /// Why it ended: "done", "time", "app" (Cache came to the front or asked), "heat", "battery", "unplugged".
  final String why;

  String get words => 'added $added${stopped > 0 ? ', $stopped could not be added' : ''}${more ? ', more to do ($why)' : ''}';
}

/// Why background work must stop now, or null: unplugged (the slice runs only while charging), else the app's own indexing
/// rules through its throttle ([IndexThrottle]: the thermal headroom forecast and status, and the battery), the same rules as
/// adding a PDF in the app.
String? addPdfHeld(IndexThrottle t) {
  final r = t.reading;
  if (r != null && !r.charging) return 'unplugged';
  final d = t.duty;
  if (!d.paused) return null;
  return switch (d.hold) {
    IndexHold.heat => 'heat',
    IndexHold.battery => 'battery',
    _ => 'busy',
  };
}

/// [addPdfHeld] for a reading on its own (the throttle reads it first).
Future<String?> addPdfHeldNow(IndexThrottle t) async {
  await t.read(fresh: true);
  return addPdfHeld(t);
}

/// One background slice of Add PDF's jobs: each job in turn through the same runs the app's index scheduler starts (the core's
/// ingest job, checkpointed in its job folder), until all are done or the slice must stop: its [budget] is used up, [stopAsked]
/// says so (Cache came to the front), or [held] gives a reason (heat, the battery). A job stopped mid-PDF is paused the way
/// Pause pauses it: the core keeps what is done, nothing is visible in the library until its journaled commit, and the next run
/// resumes it from the same job folder.
class AddPdfSlice {
  AddPdfSlice(this.state, {this.budget = kAddPdfSliceBudget, this.stopAsked, this.held, this.only, this.throttle, this.lookEvery = const Duration(seconds: 15), DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AddPdfState state;
  final Duration budget;
  final bool Function()? stopAsked;
  final Future<String?> Function()? held;

  /// Only these jobs (the watched folders'); all when null.
  final bool Function(AddPdfJob job)? only;

  /// The app's indexing throttle, read while the slice runs (the scheduler does the same for the app's index work); the jobs
  /// follow its duty through [indexThrottleShared].
  final IndexThrottle? throttle;
  final Duration lookEvery;
  final DateTime Function() _clock;

  bool _wanted(String key) {
    final o = only;
    if (o == null) return true;
    final j = state.byId(key.substring(key.indexOf('/') + 1));
    return j != null && o(j);
  }

  Future<AddPdfSliceResult> run() async {
    // read once now, so the first job starts with the duty (and thread count) the device calls for
    await throttle?.read(fresh: true);
    throttle?.watch(true);
    try {
      return await _run();
    } finally {
      throttle?.watch(false);
    }
  }

  Future<AddPdfSliceResult> _run() async {
    final end = _clock().add(budget);
    var added = 0, stopped = 0;
    Future<String?> why() async {
      if (stopAsked?.call() ?? false) return 'app';
      if (!_clock().isBefore(end)) return 'time';
      return held == null ? null : await held!();
    }

    while (true) {
      final before = await why();
      final tasks = [
        for (final t in await state.pending())
          if (_wanted(t.key)) t,
      ];
      if (tasks.isEmpty) return AddPdfSliceResult(added: added, stopped: stopped, more: false, why: 'done');
      if (before != null) return AddPdfSliceResult(added: added, stopped: stopped, more: true, why: before);
      final task = tasks.first;
      final job = state.byId(task.key.substring(task.key.indexOf('/') + 1));
      final run = await task.start();
      String? stopWhy;
      var looking = false;
      final timer = Timer.periodic(lookEvery, (_) async {
        if (looking || stopWhy != null) return;
        looking = true;
        try {
          final w = await why();
          if (w != null && stopWhy == null) {
            stopWhy = w;
            await run.pause();
          }
        } finally {
          looking = false;
        }
      });
      final ok = await run.finished;
      timer.cancel();
      if (ok) {
        added++;
      } else if (job?.status == AddPdfStatus.failed) {
        stopped++;
      }
      if (stopWhy != null) return AddPdfSliceResult(added: added, stopped: stopped, more: true, why: stopWhy!);
      // it ended without finishing or failing and nothing asked it to: left for the next run, never tried again in a loop
      if (!ok && job?.status == AddPdfStatus.active) return AddPdfSliceResult(added: added, stopped: stopped, more: true, why: 'stopped');
    }
  }
}

import 'dart:async';

import '../../platform/battery.dart';
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

/// Why background work must stop now by the indexing rules, or null: unplugged (the slice runs only while charging), a low
/// battery, or the phone warm (the thermal status moderate or warmer, as the app's index work pauses at).
String? addPdfHeld(BatteryReading? b) {
  if (b == null) return null;
  if (!b.charging) return 'unplugged';
  if (b.low) return 'battery';
  if (b.thermal.hot) return 'heat';
  return null;
}

/// One background slice of Add PDF's jobs: each job in turn through the same runs the app's index scheduler starts (the core's
/// ingest job, checkpointed in its job folder), until all are done or the slice must stop: its [budget] is used up, [stopAsked]
/// says so (Cache came to the front), or [held] gives a reason (heat, the battery). A job stopped mid-PDF is paused the way
/// Pause pauses it: the core keeps what is done, nothing is visible in the library until its journaled commit, and the next run
/// resumes it from the same job folder.
class AddPdfSlice {
  AddPdfSlice(this.state, {this.budget = kAddPdfSliceBudget, this.stopAsked, this.held, this.only, this.lookEvery = const Duration(seconds: 15), DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AddPdfState state;
  final Duration budget;
  final bool Function()? stopAsked;
  final Future<String?> Function()? held;

  /// Only these jobs (the watched folders'); all when null.
  final bool Function(AddPdfJob job)? only;
  final Duration lookEvery;
  final DateTime Function() _clock;

  Future<AddPdfSliceResult> run() async {
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
          if (only == null || (state.byId(t.key.substring(t.key.indexOf('/') + 1)) case final j? when only!(j))) t,
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

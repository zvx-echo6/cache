import 'dart:async';

import '../pdf/index/pdf_index_state.dart';
import 'index_scheduler.dart';
import 'index_throttle.dart' show IndexDuty, IndexHold;
import 'indexes_share.dart' show encodeSourceId;

/// Making ZIMs' PDFs searchable, as work for the [IndexScheduler]: the scheduler decides when (the PDF state then queues
/// nothing by itself: its autoStart is null), starts a ZIM with [PdfIndexState.start] and pauses it with
/// [PdfIndexState.hold]. A ZIM is listed while [PdfIndexState.needsIndex] says so: it has PDFs, no snapshot for its edition
/// (one that came from a linked device counts), and the person has not paused it.
class PdfIndexWork implements IndexWorkSource {
  PdfIndexWork(this.state, this.zims);

  final PdfIndexState state;
  final List<PdfZimRef> Function() zims;

  @override
  Future<List<IndexTask>> pending() async => [
        for (final z in zims())
          if (z.uuid != null && state.needsIndex(z) == true)
            IndexTask(
              key: 'zim-pdf/${encodeSourceId(z.uuid!)}',
              size: state.partOf(z)?.total ?? 0,
              // Long until measured: a run measured short goes on any battery that is not low.
              long: state.estimateOf(z)?.long ?? true,
              bytesNeeded: state.estimateOf(z)?.needBytes ?? 0,
              title: z.title,
              progress: () => switch (state.partOf(z)) {
                final p? when p.total > 0 => (p.handled, p.total),
                _ => null,
              },
              pulse: () => (state.beats, state.stepsOf(z), state.partOf(z)?.phase, state.partOf(z)?.finishFraction),
              step: () => state.stepOf(z),
              start: () async {
                await state.start(z);
                return PdfIndexRun(state, z);
              },
            ),
      ];
}

/// The scheduler's reason as the PDF status says it.
PdfHold pdfHoldOf(IndexWait why) => switch (why) {
      IndexWait.charging => PdfHold.charging,
      IndexWait.heat => PdfHold.warm,
      IndexWait.battery => PdfHold.battery,
      IndexWait.storage => PdfHold.storage,
      IndexWait.closed => PdfHold.closed,
      IndexWait.model => PdfHold.model,
      IndexWait.person => PdfHold.person,
      IndexWait.stuck => PdfHold.stuck,
      IndexWait.none => PdfHold.waiting,
    };

/// One ZIM's PDF run as the scheduler sees it: finished when its PDFs are searchable (true) or the run stopped (paused, failed,
/// no room: false).
class PdfIndexRun implements IndexRun {
  PdfIndexRun(this.state, this.zim) {
    state.addListener(_check);
    _check();
  }

  final PdfIndexState state;
  final PdfZimRef zim;
  final Completer<bool> _done = Completer<bool>();

  void _check() {
    if (_done.isCompleted) return;
    final p = state.partOf(zim);
    final bool? end = switch (p?.phase) {
      PdfPartPhase.done => true,
      PdfPartPhase.paused || PdfPartPhase.failed || PdfPartPhase.needsSpace || null => false,
      _ => null,
    };
    if (end == null) return;
    state.removeListener(_check);
    _done.complete(end);
  }

  @override
  Future<bool> get finished => _done.future;

  /// Held by the scheduler, with its reason for the status (never "low battery" unless it is the battery).
  @override
  Future<void> pause([IndexWait why = IndexWait.none]) => state.hold(zim, pdfHoldOf(why));

  /// The PDF loop follows the throttle itself (it awaits [indexPermit] between PDFs and between pages); the duty only tells the
  /// status why it goes slower or waits.
  @override
  void setDuty(IndexDuty duty) => state.slowed(zim, switch (duty.hold) {
        IndexHold.heat => PdfHold.warm,
        IndexHold.battery => PdfHold.battery,
        IndexHold.model => PdfHold.model,
        IndexHold.none => null,
      });
}

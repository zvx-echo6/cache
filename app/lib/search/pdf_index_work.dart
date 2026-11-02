import 'dart:async';

import '../pdf/index/pdf_index_state.dart';
import 'index_scheduler.dart';
import 'index_throttle.dart' show IndexDuty;
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
              start: () async {
                await state.start(z);
                return PdfIndexRun(state, z);
              },
            ),
      ];
}

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

  @override
  Future<void> pause() => state.hold(zim);

  /// The PDF loop follows the throttle itself: it awaits [indexPermit] between PDFs and between pages.
  @override
  void setDuty(IndexDuty duty) {}
}

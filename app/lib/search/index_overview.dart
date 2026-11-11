import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/app_log.dart' show appLog;
import '../screens/download_confirm.dart' show openStorageForSpace;
import '../theme.dart';
import '../library/add_pdf/add_pdf_pages.dart' show addPdfDoneLine, openAddPdfProgress;
import '../library/add_pdf/add_pdf_state.dart' show AddPdfJob, AddPdfState, addPdfShared, addPdfErrorWords;
import 'index_scheduler.dart';
import 'index_status.dart';

/// The overall search index progress, at the top of the Library and in the Settings line's place (one component): a bar for
/// all the work ([IndexScheduler.fraction]: each source an equal share, filled inside by its PDFs, caption files or EPUBs read),
/// the headline "Getting search ready · 3 of 9 done" with the reason when it waits ("· Paused · battery low (12%) · plug in to
/// continue"), and under it the work running now ("Army Publishing · PDFs 340 of 5,768"). Tapping it opens the queue
/// ([showIndexQueueSheet]). When everything is done it says "Search ready · 9 of 9" for a moment ([doneFor]), then goes.
class IndexOverviewLine extends StatefulWidget {
  const IndexOverviewLine({super.key, required this.scheduler, this.doneFor = const Duration(seconds: 4), this.queueOnTap = false, this.clock = DateTime.now});

  final IndexScheduler scheduler;

  /// A tap always opens the queue (on Add PDF's progress page, which a PDF's work otherwise opens).
  final bool queueOnTap;
  final Duration doneFor;

  /// The time now (a test sets its own): a PDF that was just added is said for a while.
  final DateTime Function() clock;

  @override
  State<IndexOverviewLine> createState() => _IndexOverviewLineState();
}

class _IndexOverviewLineState extends State<IndexOverviewLine> {
  /// The total of the work last seen running, to say "Search ready · 9 of 9" when it is all done.
  int _lastTotal = 0;
  int? _doneTotal;
  Timer? _hide;
  Timer? _doneLine;

  @override
  void initState() {
    super.initState();
    widget.scheduler.addListener(_changed);
    addPdfShared?.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.scheduler.removeListener(_changed);
    addPdfShared?.removeListener(_changed);
    _hide?.cancel();
    _doneLine?.cancel();
    super.dispose();
  }

  void _changed() {
    final s = widget.scheduler;
    if (s.busy) {
      _lastTotal = s.totalCount;
      _hide?.cancel();
      _doneTotal = null;
    } else if (_lastTotal > 0) {
      // everything is done: "Search ready · 9 of 9" for a moment
      _doneTotal = _lastTotal;
      _lastTotal = 0;
      _hide?.cancel();
      _hide = Timer(widget.doneFor, () {
        if (mounted) setState(() => _doneTotal = null);
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scheduler;
    final k = context.t;
    // a PDF whose adding stopped: the card stays, its line in the danger color ("Water purification manual · Stopped: no readable
    // text"), until it is tried again or put away on the progress page
    final stopped = addPdfShared?.failed.firstOrNull;
    // a PDF paused by the person is not index work, so the scheduler does not list it: the card stays, so its Resume can be
    // reached, with the same words as its own card ("Paused by you · Resume")
    final paused = stopped == null && !s.busy ? addPdfShared?.active.where((j) => j.pausedByPerson).toList() ?? const [] : const <AddPdfJob>[];
    // a PDF that was just added: what it did ("Added to My books · 9 pieces searchable") comes before a paused one waiting beside it
    // (the person must see the book went in), for a short while; the paused line is back after that
    final now = widget.clock();
    final added = stopped == null && !s.busy ? addPdfShared?.justFinished(now) : null;
    _doneLine?.cancel();
    if (added != null) {
      final left = AddPdfState.kDoneLineFor - now.difference(added.finishedAt!);
      _doneLine = Timer(left + const Duration(milliseconds: 50), () {
        if (mounted) setState(() {});
      });
    }
    final line = stopped != null
        ? 'Getting search ready · ${s.busy ? s.doneCount : 0} of ${(s.busy ? s.totalCount : 0) + addPdfShared!.failed.length} done'
        : (added != null
            ? addPdfDoneLine(addPdfShared!, added)
            : (paused.isNotEmpty ? (paused.length == 1 ? 'Paused · 1 PDF waiting' : 'Paused · ${paused.length} PDFs waiting') : s.line));
    final done = _doneTotal;
    if (line == null && done == null) return const SizedBox.shrink();
    // everything paused by the person: said plainly, in the normal text color (nothing is wrong)
    final held = line != null && s.reason != IndexWait.none && stopped == null && added == null && paused.isEmpty;
    var current = stopped != null
        ? '${stopped.title} · Stopped: ${addPdfErrorWords(stopped).stopped}'
        : (added != null ? added.title : (paused.isNotEmpty ? '${paused.first.title} · Paused by you · Resume' : (line == null ? null : indexCurrentWords(s))));
    // a PDF a watched folder found: the folder and how many its check found come first ("Manuals: 2 new PDFs · ...")
    final run = s.running;
    if (stopped == null && current != null && run != null && run.startsWith('pdf-add/')) {
      final j = addPdfShared?.byId(run.substring('pdf-add/'.length));
      final check = j?.checkId;
      if (j != null && j.watchName != null && check != null) {
        final n = addPdfShared!.jobs.where((o) => o.checkId == check).length;
        current = '${j.watchName}: ${n == 1 ? '1 new PDF' : '$n new PDFs'} · $current';
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('index-overview'),
          onTap: line == null
              ? null
              : (!widget.queueOnTap && (stopped != null || added != null || paused.isNotEmpty || (s.running?.startsWith('pdf-add/') ?? false)) ? () => openAddPdfProgress(context) : () => showIndexQueueSheet(context, s)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        line ?? 'Search ready · $done of $done',
                        key: const ValueKey('index-overview-line'),
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: held ? k.warning : k.text),
                      ),
                      if (current != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(current, key: const ValueKey('index-overview-current'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: stopped != null ? k.emergency : k.secondary)),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            key: const ValueKey('index-overview-bar'),
                            // full when it is all done (a book added whose words are in); empty while the book's words are still being added
                            value: line == null || (added != null && !addPdfShared!.wordsPendingFor(added)) ? 1 : (s.busy ? s.fraction : 0),
                            minHeight: 6,
                            color: held ? k.secondary : k.accent,
                            backgroundColor: k.secondary.withValues(alpha: 0.15),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (line != null) Icon(Icons.chevron_right, color: k.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The queue of search index work: what runs now (with progress), what is next in order (and why anything is held), what is
/// done; Pause all or Resume.
Future<void> showIndexQueueSheet(BuildContext context, IndexScheduler scheduler) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => IndexQueueSheet(scheduler: scheduler),
);

class IndexQueueSheet extends StatelessWidget {
  const IndexQueueSheet({super.key, required this.scheduler});

  final IndexScheduler scheduler;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scheduler,
    builder: (context, _) {
      final k = context.t;
      final items = scheduler.items;
      final running = [for (final i in items) if (i.state == IndexState.running) i];
      final next = [for (final i in items) if (i.state == IndexState.queued || i.state == IndexState.held) i];
      final done = [for (final i in items) if (i.state == IndexState.done) i];
      Widget label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: k.secondary)),
      );
      Widget row(IndexItem i) {
        final words = indexQueueWords(i, battery: scheduler.reading);
        final p = i.progress;
        final storage = i.why == IndexWait.storage && openStorageForSpace != null;
        final stuck = i.why == IndexWait.stuck;
        return ListTile(
          key: ValueKey('index-item-${i.key}'),
          title: Text(indexItemTitle(i, items), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(words ?? 'Searching ready', style: TextStyle(color: i.state == IndexState.held ? k.warning : k.secondary)),
              // its own bar: done full, else the items it reports (empty when it cannot say yet)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    // running and not able to say how far yet: the moving bar, never an empty one
                    value: i.state == IndexState.done
                        ? 1
                        : (p != null && p.$2 > 0 ? (p.$1 / p.$2).clamp(0.0, 1.0) : (i.state == IndexState.running ? null : 0)),
                    minHeight: 4,
                    color: i.state == IndexState.held ? k.secondary : k.accent,
                    backgroundColor: k.secondary.withValues(alpha: 0.15),
                  ),
                ),
              ),
            ],
          ),
          onTap: storage ? () => openStorageForSpace!(context) : (stuck ? () => scheduler.retry(i.key) : (i.kind == 'pdf-add' ? () => openAddPdfProgress(context) : null)),
          // what the log says of this piece of work lately
          trailing: i.state == IndexState.done
              ? null
              : TextButton(key: ValueKey('index-details-${i.key}'), onPressed: () => showIndexJobDetails(context, i, items), child: const Text('Details')),
        );
      }

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                child: Row(
                  children: [
                    Expanded(child: Text('Search indexes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text))),
                    if (scheduler.busy)
                      scheduler.pausedAll
                          ? FilledButton(key: const ValueKey('index-resume-all'), onPressed: scheduler.resumeAll, child: const Text('Resume'))
                          : OutlinedButton(key: const ValueKey('index-pause-all'), onPressed: scheduler.pauseAll, child: const Text('Pause all')),
                  ],
                ),
              ),
              if (scheduler.line case final line?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(line, key: const ValueKey('index-queue-line'), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              if (running.isNotEmpty) ...[label('Running now'), for (final i in running) row(i)],
              if (next.isNotEmpty) ...[label('Next'), for (final i in next) row(i)],
              if (done.isNotEmpty) ...[label('Done'), for (final i in done) row(i)],
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Everything is searchable.', style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
}

/// A piece of work's Details: its last log lines (kept in memory, at any log level, for the screen only), newest last.
Future<void> showIndexJobDetails(BuildContext context, IndexItem i, List<IndexItem> all) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) {
    final k = ctx.t;
    final lines = appLog.jobLines(i.key);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: ListView(
          key: ValueKey('index-details-sheet-${i.key}'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          children: [
            Text(indexItemTitle(i, all), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 4),
            Text(indexQueueWords(i) ?? 'Searching ready', style: TextStyle(color: k.secondary)),
            const SizedBox(height: 12),
            if (lines.isEmpty)
              Text('Nothing logged for this yet.', style: TextStyle(color: k.secondary))
            else
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SelectableText(l, style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: k.text)),
                ),
          ],
        ),
      ),
    );
  },
);

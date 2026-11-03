import 'dart:async';

import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import '../../maps/ui/format.dart' show formatBytes, formatCount;
import '../../screens/download_confirm.dart' show openStorageForSpace;
import '../../theme.dart';
import 'pdf_index_run.dart';
import 'pdf_index_state.dart';

/// "340 of 5,768".
String _of(PdfPart p) => '${formatCount(p.handled)} of ${formatCount(p.total)}';

/// " · 22 new PDFs" for a new edition reusing its older one; nothing otherwise.
String _new(PdfPart p) => p.newCount > 0 ? ' · ${formatCount(p.newCount)} new PDF${p.newCount == 1 ? '' : 's'}' : '';

/// The status line of a library's PDFs (always on: a status, not an action), in the words of the Library rows, the Library's
/// overview and the Settings line (search/index_status.dart). Only a run says "Making": waiting says so, and a pause says why
/// and what makes it go on.
String pdfPartLine(PdfPart p) => switch (p.phase) {
  PdfPartPhase.done => 'PDFs: searching ready',
  PdfPartPhase.waiting => 'Waiting to make PDFs searchable${_new(p)}',
  PdfPartPhase.starting => 'Making PDFs searchable…${_new(p)}',
  PdfPartPhase.running when p.hold != null && p.hold != PdfHold.waiting => '${pdfHoldWords(p.hold!)} · ${_of(p)}',
  PdfPartPhase.running => 'Making PDFs searchable · ${_of(p)}${_new(p)}',
  PdfPartPhase.pausing => 'Pausing…',
  PdfPartPhase.finishing => 'Making PDFs searchable · finishing',
  PdfPartPhase.paused => switch (p.pause) {
    PdfPause.battery => 'Paused · battery low · plug in to continue · ${_of(p)}',
    PdfPause.held => '${pdfHoldWords(p.hold ?? PdfHold.waiting)} · ${_of(p)}',
    PdfPause.closed => 'Paused · Cache is in the background · ${_of(p)}',
    _ => 'Paused by you · Resume · ${_of(p)}',
  },
  PdfPartPhase.needsSpace => p.needBytes > 0 ? 'Needs ${formatBytes(p.needBytes)} free · Free space' : 'Needs more free space · Free space',
  PdfPartPhase.failed => 'Stopped: the library could not be read',
};

/// The index scheduler's reason, in the Settings line's words (search/index_status.dart's indexWaitWords).
String pdfHoldWords(PdfHold h) => switch (h) {
  PdfHold.waiting => 'Waiting to make PDFs searchable',
  PdfHold.charging => 'Waits for charging (long job)',
  PdfHold.warm => 'Slowed down · device is warm',
  PdfHold.battery => 'Paused · battery low · plug in to continue',
  PdfHold.storage => 'Needs more free space · Free space',
  PdfHold.closed => 'Paused · Cache is in the background',
  PdfHold.model => 'Paused · while Ask answers',
  PdfHold.person => 'Paused by you · Resume',
};

/// Why a run stopped, in plain words.
String pdfStopWords(PdfRunFailure f) => switch (f.kind) {
  PdfRunFailureKind.full => 'this device is full',
  PdfRunFailureKind.other => 'the library could not be read',
};

/// The few words the Library list adds to a ZIM's detail line when there is no index scheduler to ask; null adds none
/// (searchable PDFs are the normal case). The same words as the status line: only a run says "Making".
String? pdfRowNote(PdfPart? p) => switch (p?.phase) {
  null || PdfPartPhase.done => null,
  PdfPartPhase.failed => 'PDFs stopped',
  _ => pdfPartLine(p!),
};

/// The part as the one download pattern draws its control and bar.
DlState pdfDlState(PdfPart p) => switch (p.phase) {
  PdfPartPhase.waiting || PdfPartPhase.done => DlState(DlPhase.done, done: p.total, total: p.total),
  PdfPartPhase.starting => const DlState(DlPhase.starting),
  PdfPartPhase.running => DlState(DlPhase.running, done: p.handled, total: p.total),
  PdfPartPhase.pausing => DlState(DlPhase.pausing, done: p.handled, total: p.total),
  PdfPartPhase.finishing => DlState(DlPhase.verifying, done: p.handled, total: p.total),
  PdfPartPhase.paused => DlState(DlPhase.paused, done: p.handled, total: p.total),
  PdfPartPhase.needsSpace => DlState(DlPhase.failed, done: p.handled, total: p.total, reason: DlReason.full),
  PdfPartPhase.failed => DlState(DlPhase.failed, done: p.handled, total: p.total),
};

/// The library's PDFs status: one line (with the bar while it runs) and one control: Pause while running, Resume when paused or
/// stopped, Free space when there is not enough room; none when searchable or waiting. Nothing when the library has no PDFs or
/// this device cannot index them.
class PdfIndexPartRow extends StatelessWidget {
  const PdfIndexPartRow({super.key, required this.state, required this.zim, this.schedulerLine, this.changes});

  final PdfIndexState state;
  final PdfZimRef zim;

  /// What the index scheduler says of this library's PDFs (running with progress, queued, or held with its reason), when it
  /// has them; null leaves the part's own line.
  final String? Function(PdfPart part)? schedulerLine;

  /// The scheduler, so the line follows it too.
  final Listenable? changes;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([state, ?changes]),
    builder: (context, _) {
      final p = state.partOf(zim);
      if (p == null) return const SizedBox.shrink();
      return PdfPartView(
        part: p,
        line: schedulerLine?.call(p),
        onPause: () => state.pause(zim),
        onResume: () => state.resume(zim),
        onFreeSpace: openStorageForSpace == null ? null : () => openStorageForSpace!(context),
      );
    },
  );
}

/// The part drawn from a [PdfPart] (the renders draw it straight from a state).
class PdfPartView extends StatelessWidget {
  const PdfPartView({super.key, required this.part, this.onPause, this.onResume, this.onFreeSpace, this.line});

  final PdfPart part;

  /// The line to show instead of [pdfPartLine] (the index scheduler's words).
  final String? line;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onFreeSpace;

  static const _key = 'pdfindex';

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = part;
    final s = pdfDlState(p);
    final red = p.phase == PdfPartPhase.failed || p.phase == PdfPartPhase.needsSpace;
    final bar = switch (p.phase) {
      PdfPartPhase.starting => const _Bar(value: null),
      PdfPartPhase.running || PdfPartPhase.pausing => _Bar(value: p.fraction),
      PdfPartPhase.finishing => _Bar(value: p.finishFraction),
      PdfPartPhase.paused when p.handled > 0 => _Bar(value: p.fraction, color: k.secondary),
      _ => null,
    };
    final actions = DlActions(pause: onPause, resume: onResume, freeSpace: onFreeSpace);
    return Padding(
      key: const ValueKey('$_key-part'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      line ?? pdfPartLine(p),
                      key: const ValueKey('$_key-line'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: red ? k.emergency : k.text),
                    ),
                    if (p.phase == PdfPartPhase.done && p.unreadable > 0)
                      Text('${formatCount(p.unreadable)} could not be read', key: const ValueKey('$_key-unreadable'), style: TextStyle(fontSize: 12, color: k.secondary)),
                    if (bar != null) Padding(padding: const EdgeInsets.only(top: 6), child: bar),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              dlControl(context, s, actions, keyBase: _key),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, this.color});

  final double? value;
  final Color? color;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: LinearProgressIndicator(value: value, minHeight: value == null ? 2 : 4, color: color, backgroundColor: context.t.secondary.withValues(alpha: 0.15)),
  );
}

/// The PDFs status on a sheet of its own (where the line under search results leads).
Future<void> showPdfPartSheet(BuildContext context, PdfIndexState state, PdfZimRef zim) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (ctx) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(zim.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ctx.t.text)),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: PdfIndexPartRow(state: state, zim: zim)),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// The quiet line at the very bottom of search results, one per library whose PDFs are still being made searchable: "Still
/// making Where There Is No Doctor's PDFs searchable (340 of 5,768)". Small grey text with a close mark; never a banner.
class PdfSearchNote extends StatelessWidget {
  const PdfSearchNote({super.key, required this.state, required this.open});

  final PdfIndexState state;

  /// Opens the library's PDFs status.
  final void Function(PdfZimRef zim) open;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => PdfSearchNoteView(pending: state.pending(), open: open, hide: (libs) => unawaited(state.hideNote(libs))),
  );
}

/// The line itself: "Still making Where There Is No Doctor's PDFs searchable (340 of 5,768)".
String pdfStillLine(PdfZimRef z, PdfPart p) => "Still making ${z.title}'s PDFs searchable (${_of(p)})";

class PdfSearchNoteView extends StatelessWidget {
  const PdfSearchNoteView({super.key, required this.pending, required this.open, required this.hide});

  final List<(PdfZimRef, PdfPart)> pending;
  final void Function(PdfZimRef zim) open;
  final void Function(List<PdfZimRef> libs) hide;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    if (pending.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('pdfindex-note'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (z, p) in pending)
          Padding(
            key: ValueKey('pdfindex-note-${z.fileName}'),
            padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => open(z),
                    child: Text(pdfStillLine(z, p), style: TextStyle(fontSize: 12, color: k.secondary)),
                  ),
                ),
                IconButton(
                  key: ValueKey('pdfindex-note-close-${z.fileName}'),
                  tooltip: 'Hide',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: Icon(Icons.close, color: k.secondary),
                  onPressed: () => hide([z]),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

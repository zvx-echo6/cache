import 'dart:async';

import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import '../../maps/ui/format.dart' show formatBytes, formatCount;
import '../../screens/download_confirm.dart' show openStorageForSpace;
import '../../theme.dart';
import 'pdf_index_run.dart';
import 'pdf_index_state.dart';

/// "about 5 hr", "about 5 to 8 hr", "about 40 min to 2 hr", "less than a minute": a range the way the download rows round.
String pdfRange(Duration low, Duration high) {
  if (high.inSeconds < 60) return 'less than a minute';
  final b = dlTimeLeft(high);
  final bare = b.replaceFirst('about ', '');
  if (low.inSeconds < 60) return 'less than a minute to $bare';
  final a = dlTimeLeft(low);
  if (a == b) return a;
  final ua = a.split(' ').last, ub = b.split(' ').last;
  if (ua == ub) return '${a.substring(0, a.length - ua.length - 1)} to $bare';
  return '$a to $bare';
}

String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// "1,204 of 5,768 PDFs".
String _of(PdfPart p, {bool unit = true}) => '${formatCount(p.handled)} of ${formatCount(p.total)}${unit ? ' PDFs' : ''}';

/// Why a run stopped, in the plain words after "Stopped: ".
String pdfStopWords(PdfRunFailure f) => switch (f.kind) {
  PdfRunFailureKind.full => 'this device is full',
  PdfRunFailureKind.other => 'the library could not be read',
};

/// The status line of the PDFs part.
String pdfPartLine(PdfPart p) {
  final n = formatCount(p.total);
  return switch (p.phase) {
    PdfPartPhase.idle => '$n PDFs · not searchable yet',
    PdfPartPhase.measuring => 'Timing a few PDFs on this device…',
    PdfPartPhase.waiting => 'Waiting for another library to finish',
    PdfPartPhase.starting => 'Starting…',
    PdfPartPhase.running => [
      _of(p),
      if (p.timeLeft != null) '${dlTimeLeft(p.timeLeft!)} left' else if (p.range != null) '${pdfRange(p.range!.$1, p.range!.$2)} left',
    ].join(' · '),
    PdfPartPhase.pausing => 'Pausing…',
    PdfPartPhase.finishing => 'Finishing · $n PDFs',
    PdfPartPhase.paused => switch (p.pause) {
      PdfPause.battery => 'Paused: battery low · ${_of(p, unit: false)}',
      PdfPause.closed => 'Paused: Cache was closed · ${_of(p, unit: false)}',
      _ => 'Paused · ${_of(p)}',
    },
    PdfPartPhase.failed => 'Stopped: ${pdfStopWords(p.failure!)} · ${_of(p, unit: false)}',
    PdfPartPhase.done when p.fromOtherDevice => 'Searchable · came from another device',
    PdfPartPhase.done when p.unreadable > 0 => 'Searchable · ${formatCount(p.total - p.unreadable)} of $n PDFs',
    PdfPartPhase.done => 'Searchable · $n PDFs',
    PdfPartPhase.newVersion => p.newCount > 0 ? '$n PDFs · ${formatCount(p.newCount)} new, not searchable yet' : '$n PDFs · new version, not searchable yet',
  };
}

/// The few words the Library list adds to a ZIM's detail line; null adds none.
String? pdfRowNote(PdfPart? p) => switch (p?.phase) {
  null => null,
  PdfPartPhase.idle || PdfPartPhase.newVersion || PdfPartPhase.measuring => 'PDFs not searchable yet',
  PdfPartPhase.done => 'PDFs searchable',
  PdfPartPhase.paused || PdfPartPhase.failed || PdfPartPhase.waiting => 'PDFs ${((p!.fraction ?? 0) * 100).floor()}% searchable · paused',
  _ => 'PDFs ${((p!.fraction ?? 0) * 100).floor()}% searchable',
};

/// The part as the one download pattern draws it: the phase, the bar's fill and the stop reason.
DlState pdfDlState(PdfPart p) => switch (p.phase) {
  PdfPartPhase.idle || PdfPartPhase.newVersion => DlState.idle,
  PdfPartPhase.measuring || PdfPartPhase.starting => const DlState(DlPhase.starting),
  PdfPartPhase.waiting => const DlState(DlPhase.waiting),
  PdfPartPhase.running => DlState(DlPhase.running, done: p.handled, total: p.total),
  PdfPartPhase.pausing => DlState(DlPhase.pausing, done: p.handled, total: p.total),
  PdfPartPhase.finishing => DlState(DlPhase.verifying, done: p.handled, total: p.total),
  PdfPartPhase.paused => DlState(DlPhase.paused, done: p.handled, total: p.total),
  PdfPartPhase.failed => DlState(DlPhase.failed, done: p.handled, total: p.total, reason: p.failure?.kind == PdfRunFailureKind.full ? DlReason.full : null),
  PdfPartPhase.done => DlState(DlPhase.done, done: p.total, total: p.total),
};

/// What the start pop-up's button does.
enum PdfConfirmChoice { start, freeSpace }

/// "Make 5,768 PDFs searchable?": what it does, the range measured on this device and the space, the advice to plug in, and
/// that it is a guess. Not enough room: Start becomes "Free space" with what it needs and what is free.
Future<PdfConfirmChoice?> confirmPdfIndex(BuildContext context, PdfEstimate e) => showDialog<PdfConfirmChoice>(
  context: context,
  builder: (ctx) => PdfIndexConfirm(estimate: e),
);

class PdfIndexConfirm extends StatelessWidget {
  const PdfIndexConfirm({super.key, required this.estimate});

  final PdfEstimate estimate;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final e = estimate;
    final body = TextStyle(fontSize: 15, height: 1.4, color: k.text);
    final small = TextStyle(fontSize: 13, height: 1.35, color: k.secondary);
    final n = formatCount(e.pdfs);
    final long = e.high > const Duration(hours: 2);
    final Widget button;
    if (!e.fits) {
      button = FilledButton(key: const ValueKey('pdfindex-free-space'), onPressed: () => Navigator.pop(context, PdfConfirmChoice.freeSpace), child: const Text('Free space'));
    } else {
      button = FilledButton(key: const ValueKey('pdfindex-start'), onPressed: () => Navigator.pop(context, PdfConfirmChoice.start), child: const Text('Start'));
    }
    return AlertDialog(
      key: const ValueKey('pdfindex-confirm'),
      title: Text('Make $n PDFs searchable?', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Cache reads every PDF on this device.', style: body),
          const SizedBox(height: 6),
          Text('${_cap(pdfRange(e.low, e.high))}. Uses about ${formatBytes(e.indexBytes)}.', key: const ValueKey('pdfindex-estimate'), style: body),
          if (!e.fits) ...[
            const SizedBox(height: 6),
            Text(
              'Needs ${formatBytes(e.needBytes)}. ${formatBytes(e.usable ?? 0)} free.',
              key: const ValueKey('pdfindex-short'),
              style: TextStyle(fontSize: 15, height: 1.4, color: k.emergency),
            ),
          ],
          const SizedBox(height: 6),
          Text('Best while charging. You can pause any time.', style: body),
          if (long) ...[const SizedBox(height: 6), Text('Plug in to go faster and save battery.', style: body)],
          const SizedBox(height: 6),
          Text('Keeps going while Cache is open.', style: body),
          const SizedBox(height: 10),
          Text('This is a guess until it has run a few minutes.', style: small),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        button,
      ],
    );
  }
}

/// "Remove the 1,204 PDFs already done?" [Keep] [Remove].
Future<bool> confirmPdfRemove(BuildContext context, int done) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('pdfindex-remove-confirm'),
      content: Text('Remove the ${formatCount(done)} PDFs already done?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        TextButton(
          key: const ValueKey('pdfindex-remove-yes'),
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: ctx.t.emergency),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// The snackbar when a small library starts by itself (only when the start-by-itself hook is on): "Making 140 PDFs searchable."
/// with Stop.
void showPdfAutoStartSnack(ScaffoldMessengerState messenger, int pdfs, VoidCallback stop) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text('Making ${formatCount(pdfs)} PDFs searchable.'), action: SnackBarAction(label: 'Stop', onPressed: stop)));

/// Makes [z]'s PDFs searchable: times a sample, asks with the start pop-up, then starts.
Future<void> startPdfIndex(BuildContext context, PdfIndexState state, PdfZimRef z) async {
  final e = await state.measure(z);
  if (e == null || !context.mounted) return;
  final choice = await confirmPdfIndex(context, e);
  if (!context.mounted) return;
  switch (choice) {
    case PdfConfirmChoice.start:
      await state.start(z);
    case PdfConfirmChoice.freeSpace:
      openStorageForSpace?.call(context);
    case null:
      break;
  }
}

/// The library's "PDFs" part: the title, the status line, the bar while it runs, a small "Remove" under a paused or stopped
/// line, and one control (Make searchable, Pause, Resume, Free space, Update search; none when done). Nothing when the library
/// has no PDFs or this device cannot index them.
class PdfIndexPartRow extends StatelessWidget {
  const PdfIndexPartRow({super.key, required this.state, required this.zim});

  final PdfIndexState state;
  final PdfZimRef zim;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final p = state.partOf(zim);
      if (p == null) return const SizedBox.shrink();
      return PdfPartView(
        part: p,
        onStart: () => startPdfIndex(context, state, zim),
        onPause: () => state.pause(zim),
        onResume: () => state.start(zim),
        onRemove: () => state.remove(zim),
        onFreeSpace: openStorageForSpace == null ? null : () => openStorageForSpace!(context),
      );
    },
  );
}

/// The part drawn from a [PdfPart] (the renders draw it straight from a state).
class PdfPartView extends StatelessWidget {
  const PdfPartView({super.key, required this.part, this.onStart, this.onPause, this.onResume, this.onRemove, this.onFreeSpace});

  final PdfPart part;
  final VoidCallback? onStart;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final Future<void> Function()? onRemove;
  final VoidCallback? onFreeSpace;

  static const _key = 'pdfindex';

  Future<void> _remove(BuildContext context) async {
    final r = onRemove;
    if (r == null) return;
    if (part.handled > 0 && !await confirmPdfRemove(context, part.handled)) return;
    await r();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = part;
    final s = pdfDlState(p);
    final failed = p.phase == PdfPartPhase.failed;
    final line = pdfPartLine(p);
    final bar = switch (p.phase) {
      PdfPartPhase.starting || PdfPartPhase.measuring => const _Bar(value: null),
      PdfPartPhase.running || PdfPartPhase.pausing => _Bar(value: p.fraction),
      PdfPartPhase.finishing => _Bar(value: p.finishFraction),
      PdfPartPhase.paused => _Bar(value: p.fraction, color: k.secondary),
      PdfPartPhase.failed => _Bar(value: p.fraction, color: k.emergency),
      _ => null,
    };
    final removable = p.phase == PdfPartPhase.paused || p.phase == PdfPartPhase.failed;
    final actions = DlActions(
      download: onStart,
      downloadLabel: p.phase == PdfPartPhase.newVersion ? 'Update search' : 'Make searchable',
      pause: onPause,
      resume: onResume,
      freeSpace: onFreeSpace,
      remove: onRemove == null ? null : () => _remove(context),
      removeAsks: true,
    );
    return Padding(
      key: const ValueKey('$_key-part'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('PDFs', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                    Text(line, key: const ValueKey('$_key-line'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: failed ? k.emergency : k.secondary)),
                    if (p.phase == PdfPartPhase.done && p.unreadable > 0 && !p.fromOtherDevice)
                      Text('${formatCount(p.unreadable)} could not be read', key: const ValueKey('$_key-unreadable'), style: TextStyle(fontSize: 12, color: k.secondary)),
                    if (bar != null) Padding(padding: const EdgeInsets.only(top: 6), child: bar),
                    if (removable && onRemove != null)
                      InkWell(
                        key: const ValueKey('$_key-remove'),
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _remove(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                          child: Text('Remove', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.accent)),
                        ),
                      ),
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

/// The PDFs part on a sheet of its own (where the line under search results leads).
Future<void> showPdfPartSheet(BuildContext context, PdfIndexState state, PdfZimRef zim) =>
    showModalBottomSheet<void>(
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

/// The one quiet line at the very bottom of search results for libraries whose PDFs are not searchable yet: "PDFs in Where There
/// Is No Doctor are not searchable yet. Make them searchable", or "PDFs in 3 libraries are not searchable yet."; while one is
/// running, "PDFs in Where There Is No Doctor: 40% searchable" (no link). Small grey text with a close mark; never a banner.
class PdfSearchNote extends StatelessWidget {
  const PdfSearchNote({super.key, required this.state, required this.open});

  final PdfIndexState state;

  /// Opens the library's PDFs part (one library), or the Library (several: null).
  final void Function(PdfZimRef? zim) open;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => PdfSearchNoteView(
      pending: state.pending(),
      open: open,
      hide: (libs) => unawaited(state.hideNote(libs)),
    ),
  );
}

class PdfSearchNoteView extends StatelessWidget {
  const PdfSearchNoteView({super.key, required this.pending, required this.open, required this.hide});

  final List<(PdfZimRef, PdfPart)> pending;
  final void Function(PdfZimRef? zim) open;
  final void Function(List<PdfZimRef> libs) hide;

  static bool _running(PdfPart p) => const {PdfPartPhase.starting, PdfPartPhase.running, PdfPartPhase.pausing, PdfPartPhase.finishing}.contains(p.phase);

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final running = [for (final e in pending) if (_running(e.$2)) e];
    final waiting = [for (final e in pending) if (!_running(e.$2)) e];
    if (running.isEmpty && waiting.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(fontSize: 12, color: k.secondary);
    final link = TextStyle(fontSize: 12, color: k.accent, fontWeight: FontWeight.w600);
    Widget line(Key key, InlineSpan text, {List<PdfZimRef>? closes}) => Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Text.rich(text, style: style)),
          if (closes != null)
            IconButton(
              key: const ValueKey('pdfindex-note-close'),
              tooltip: 'Hide',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: Icon(Icons.close, color: k.secondary),
              onPressed: () => hide(closes),
            ),
        ],
      ),
    );
    return Column(
      key: const ValueKey('pdfindex-note'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (z, p) in running)
          line(ValueKey('pdfindex-note-running-${z.fileName}'), TextSpan(text: 'PDFs in ${z.title}: ${((p.fraction ?? 0) * 100).floor()}% searchable')),
        if (waiting.length == 1)
          line(
            const ValueKey('pdfindex-note-one'),
            TextSpan(children: [
              TextSpan(text: 'PDFs in ${waiting.single.$1.title} are not searchable yet. '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: InkWell(key: const ValueKey('pdfindex-note-link'), onTap: () => open(waiting.single.$1), child: Text('Make them searchable', style: link)),
              ),
            ]),
            closes: [waiting.single.$1],
          )
        else if (waiting.length > 1)
          line(
            const ValueKey('pdfindex-note-many'),
            TextSpan(children: [
              TextSpan(text: 'PDFs in ${waiting.length} libraries are not searchable yet. '),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: InkWell(key: const ValueKey('pdfindex-note-link'), onTap: () => open(null), child: Text('Make them searchable', style: link)),
              ),
            ]),
            closes: [for (final e in waiting) e.$1],
          ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../platform/app_log.dart' show logError;
import '../../platform/battery.dart';
import '../../screens/download_confirm.dart' show openStorageForSpace;
import '../../screens/settings/widgets.dart' show GroupLabel, say;
import '../../search/index_overview.dart';
import '../../search/index_scheduler.dart';
import '../../search/index_status.dart' show indexSlowedWords, indexWaitWords;
import '../../sources/libraries_state.dart';
import '../../theme.dart';
import '../../video/format.dart' show formatBytes;
import '../book_pages.dart' show openPlace, PlaceChip;
import '../cds.dart';
import '../library_pages.dart';
import '../library_panes.dart';
import '../shelf_source.dart';
import 'add_pdf_state.dart';

/// The Library's pages and states, for Add PDF's result actions (Move, Undo, Place, Open book): set by the Library screen.
LibraryDeps? addPdfLibraryDeps;

/// A PDF the person chose: its path (the picker's own copy on a phone), its name and size.
typedef PickedPdf = ({String path, String name, int bytes});

/// Chooses a PDF with the system's file picker (the app's file_picker, PDFs only); null when nothing was chosen.
Future<PickedPdf?> pickPdfWithPicker() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf']);
  final path = f?.path;
  if (f == null || path == null) return null;
  return (path: path, name: f.name, bytes: await f.length() ?? await File(path).length());
}

/// What the tests and renders use in place of the system picker.
Future<PickedPdf?> Function() addPdfPicker = pickPdfWithPicker;

/// Add a PDF: the file picker, then the confirm screen. The way in from Add to Library (under Your own) and from Bookshelves.
Future<void> startAddPdf(BuildContext context) => startAddPdfOn(Navigator.of(context));

/// [startAddPdf] on [nav] (from a card that goes away meanwhile).
Future<void> startAddPdfOn(NavigatorState nav) async {
  final state = addPdfShared;
  if (state == null) return;
  final PickedPdf? picked;
  try {
    picked = await addPdfPicker();
  } catch (e) {
    logError('Add PDF: the file picker failed', error: e);
    return;
  }
  final pdf = picked;
  if (pdf == null || !nav.mounted) return;
  await nav.push(MaterialPageRoute<void>(builder: (_) => AddPdfConfirmPage(state: state, pdf: pdf)));
}

/// The libraries a PDF may go to: My books (made on first use) and the other libraries the person made.
List<AddPdfTarget> addPdfTargets(LibrariesState? libs) {
  final own = libs?.ownLibraries ?? const <LibraryItem>[];
  final def = libs?.defaultOwnLibrary;
  return [
    def == null ? const AddPdfTarget(title: 'My books', isDefault: true) : AddPdfTarget(title: libs!.titleOf(def), path: def.path, isDefault: true),
    for (final l in own)
      if (l != def) AddPdfTarget(title: libs!.titleOf(l), path: l.path),
  ];
}

String _titleFromName(String name) => name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');

/// The time a PDF takes, as the confirm screen says it: "About 4 min while charging", with what the phone will do.
({String time, String note}) addPdfTimeWords(int bytes, BatteryReading? b) {
  final time = '${aboutMinutes(addPdfEstimate(bytes))} while charging';
  if (b == null || b.charging) return (time: time, note: 'On battery it waits for charging. You can use Cache meanwhile.');
  if (b.percent <= 50) return (time: time, note: 'Longer if pages are scans. This phone is at ${b.percent}%, so it starts when plugged in.');
  return (time: time, note: 'Longer if pages are scans. You can use Cache meanwhile.');
}

// ---- small pieces in the mockups' style

/// A file's tile: the PDF icon on a tinted square.
class _FileTile extends StatelessWidget {
  const _FileTile();

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.12), k.surface), borderRadius: BorderRadius.circular(9)),
      child: Icon(Icons.description_outlined, size: 21, color: k.accent),
    );
  }
}

/// A white card.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: context.t.surface, borderRadius: BorderRadius.circular(16)),
    child: child,
  );
}

/// Rows stacked tight, round on the outer corners.
class _Stack extends StatelessWidget {
  const _Stack({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: k.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(i == 0 ? 16 : 4), bottom: Radius.circular(i == rows.length - 1 ? 16 : 4)),
            ),
            child: rows[i],
          ),
        ],
      ],
    );
  }
}

/// A fact: its small label, the value, an optional line under it, and a button at the end.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.note, this.trailing, this.valueKey});

  final String label;
  final String value;
  final String? note;
  final Widget? trailing;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(fontSize: 13, color: k.secondary)),
              Text(value, key: valueKey, style: TextStyle(fontSize: 16, color: k.text)),
              if (note != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(note!, style: TextStyle(fontSize: 13, height: 1.35, color: k.secondary))),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    );
  }
}

/// An outlined pill in the accent ("Change", "Move", "Pause").
class _Ghost extends StatelessWidget {
  const _Ghost({required this.label, required this.onPressed, this.icon, super.key});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final style = OutlinedButton.styleFrom(
      foregroundColor: k.accent,
      side: BorderSide(color: k.accent, width: 1.5),
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: const StadiumBorder(),
    );
    // the size and weight on the text itself: the button keeps the theme's font
    final text = Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500));
    return icon == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: text)
        : OutlinedButton.icon(onPressed: onPressed, style: style, icon: Icon(icon, size: 16), label: text);
  }
}

/// A text button in the accent ("Cancel"), or the danger color.
class _Txt extends StatelessWidget {
  const _Txt({required this.label, required this.onPressed, this.danger = false, super.key});

  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: danger ? k.emergency : k.accent),
      child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}

/// The big filled button ("Add PDF", "Open book"), or outlined.
class _Big extends StatelessWidget {
  const _Big({required this.label, required this.onPressed, this.outlined = false, this.busy = false, super.key});

  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    const text = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
    final child = busy ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: k.onPrimary)) : Text(label, style: text);
    if (outlined) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: shape, foregroundColor: k.accent, side: BorderSide(color: k.accent, width: 1.5)),
        child: child,
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: shape, backgroundColor: k.primary, foregroundColor: k.onPrimary),
      child: child,
    );
  }
}

/// A note inside a card: a stripe down its left side in its tone, a heading, a line, and its buttons.
class _Note extends StatelessWidget {
  const _Note({required this.tone, required this.title, this.body, this.actions = const [], this.leading, this.trailing, this.plain = false, super.key});

  /// On the page itself (an error or a wait), white like a card; inside a card the note is tinted.
  final bool plain;

  final Color tone;
  final String title;
  final String? body;
  final List<Widget> actions;
  final Widget? leading;

  /// Buttons at the end of the heading's line (the book page's one-line note).
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
        if (body != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(body!, style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary))),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: plain ? k.surface : Color.alphaBlend(k.secondary.withValues(alpha: 0.08), k.surface),
        borderRadius: BorderRadius.circular(plain ? 16 : 12),
        border: Border(left: BorderSide(color: tone, width: 4)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(child: text),
              ...?trailing,
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
          ],
        ],
      ),
    );
  }
}

/// The error's icon on a tinted square.
class _ErrIcon extends StatelessWidget {
  const _ErrIcon(this.icon, this.color);

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.12), k.surface), borderRadius: BorderRadius.circular(9)),
      child: Icon(icon, size: 21, color: color),
    );
  }
}

/// The green check.
class _DoneDot extends StatelessWidget {
  const _DoneDot();

  static const double size = 24;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: k.ok, shape: BoxShape.circle),
      child: Icon(Icons.check, size: size * 0.66, color: k.surface),
    );
  }
}

Widget _bar(BuildContext context, double? value, {bool warn = false}) {
  final k = context.t;
  return ClipRRect(
    borderRadius: BorderRadius.circular(3),
    child: LinearProgressIndicator(value: value, minHeight: 5, color: warn ? k.warning : k.accent, backgroundColor: k.secondary.withValues(alpha: 0.15)),
  );
}

// ---- the confirm screen

/// After picking a file: one screen, one decision. The title (filled from the file), its size, the library (Change), the time,
/// and Add PDF. The file is not copied or changed here; Cancel leaves nothing behind.
class AddPdfConfirmPage extends StatefulWidget {
  const AddPdfConfirmPage({super.key, required this.state, required this.pdf, this.battery});

  final AddPdfState state;
  final PickedPdf pdf;

  /// The battery now (for the time's line); the device's own when null.
  final BatteryReading? battery;

  @override
  State<AddPdfConfirmPage> createState() => _AddPdfConfirmPageState();
}

class _AddPdfConfirmPageState extends State<AddPdfConfirmPage> {
  late final TextEditingController _title = TextEditingController(text: _titleFromName(widget.pdf.name));
  late AddPdfTarget _target = addPdfTargets(widget.state.libraries).first;
  BatteryReading? _battery;
  bool _adding = false;
  bool _added = false;

  @override
  void initState() {
    super.initState();
    _battery = widget.battery;
    if (_battery == null) {
      unawaited((widget.state.battery ?? readBattery)().then((b) {
        if (mounted) setState(() => _battery = b);
      }).catchError((_) {}));
    }
  }

  @override
  void dispose() {
    _title.dispose();
    // Cancel (or back) leaves nothing behind: the picker's copy goes
    if (!_added) {
      try {
        final f = File(widget.pdf.path);
        if (f.existsSync() && f.path.contains('file_picker')) f.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _change() async {
    final t = await showAddPdfLibrarySheet(context, targets: addPdfTargets(widget.state.libraries), current: _target, fileName: widget.pdf.name);
    if (t != null && mounted) setState(() => _target = t);
  }

  Future<void> _add() async {
    setState(() => _adding = true);
    try {
      final title = _title.text.trim().isEmpty ? _titleFromName(widget.pdf.name) : _title.text.trim();
      await widget.state.add(pdfPath: widget.pdf.path, fileName: widget.pdf.name, bytes: widget.pdf.bytes, title: title, target: _target, ownsFile: Platform.isAndroid || Platform.isIOS);
      _added = true;
      if (!mounted) return;
      // the confirm screen gives way to the progress page
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => AddPdfProgressPage(state: widget.state, deps: addPdfLibraryDeps)));
    } catch (e) {
      if (mounted) say(context, 'The PDF could not be added: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final pdf = widget.pdf;
    final time = addPdfTimeWords(pdf.bytes, _battery);
    return Scaffold(
      appBar: AppBar(title: const Text('Add PDF')),
      body: LayoutBuilder(
        builder: (context, c) => ListView(
          padding: EdgeInsets.fromLTRB(c.maxWidth > 600 ? (c.maxWidth - 560) / 2 : 12, 4, c.maxWidth > 600 ? (c.maxWidth - 560) / 2 : 12, 24),
          children: [
            _Card(
              child: Row(
                children: [
                  const _FileTile(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pdf.name, key: const ValueKey('add-pdf-file'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text('From this phone', style: TextStyle(fontSize: 13, color: k.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('add-pdf-title'),
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(fontSize: 16, color: k.text),
              decoration: InputDecoration(
                labelText: 'Title',
                filled: true,
                fillColor: k.surface,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.2)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 2)),
              ),
            ),
            const SizedBox(height: 10),
            _Stack(rows: [
              _Fact(label: 'Size', value: formatBytes(pdf.bytes), valueKey: const ValueKey('add-pdf-size')),
              _Fact(
                label: 'Library',
                value: _target.title,
                valueKey: const ValueKey('add-pdf-library'),
                note: _target.isNew ? 'New. Your own PDFs go here. It syncs like any library.' : null,
                trailing: _Ghost(key: const ValueKey('add-pdf-change'), label: 'Change', onPressed: _adding ? null : _change),
              ),
              _Fact(label: 'Time', value: time.time, note: time.note, valueKey: const ValueKey('add-pdf-time')),
            ]),
            const SizedBox(height: 14),
            _Big(key: const ValueKey('add-pdf-add'), label: 'Add PDF', busy: _adding, onPressed: _adding ? null : _add),
            const SizedBox(height: 6),
            Center(child: _Txt(key: const ValueKey('add-pdf-cancel'), label: 'Cancel', onPressed: _adding ? null : () => Navigator.of(context).maybePop())),
          ],
        ),
      ),
    );
  }
}

/// "Which library?": the libraries the person made, in the Place it sheet's pill style (the one in use filled), and Cancel.
/// Ready-made libraries are never listed.
Future<AddPdfTarget?> showAddPdfLibrarySheet(BuildContext context, {required List<AddPdfTarget> targets, required AddPdfTarget current, required String fileName}) =>
    showModalBottomSheet<AddPdfTarget>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => AddPdfLibrarySheet(targets: targets, current: current, fileName: fileName),
    );

class AddPdfLibrarySheet extends StatelessWidget {
  const AddPdfLibrarySheet({super.key, required this.targets, required this.current, required this.fileName});

  final List<AddPdfTarget> targets;
  final AddPdfTarget current;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Which library?', style: TextStyle(fontSize: 20, color: k.text)),
            const SizedBox(height: 6),
            Text(fileName, style: TextStyle(fontSize: 15, color: k.text)),
            const SizedBox(height: 4),
            Text('Only libraries you made. Search covers all of them.', style: TextStyle(fontSize: 14, color: k.secondary)),
            const SizedBox(height: 12),
            for (final t in targets)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: PlaceChip(
                  key: ValueKey('add-pdf-lib-${t.title}'),
                  label: t.isDefault ? '${t.title} · Default' : t.title,
                  best: t.path == current.path && t.title == current.title,
                  onPressed: () => Navigator.of(context).pop(t),
                ),
              ),
            const SizedBox(height: 4),
            _Txt(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ],
        ),
      ),
    );
  }
}

// ---- the progress page

/// Opens the progress page: on a phone a page of its own ("Progress"); in the Library's panes beside the list ("Adding a PDF").
void openAddPdfProgress(BuildContext context) {
  final state = addPdfShared;
  if (state == null) return;
  final nav = LibraryNav.of(context);
  final spec = LibraryPageSpec('add-pdf', (_) => AddPdfProgressPage(state: state, deps: addPdfLibraryDeps), leaf: true);
  if (!nav.compact) {
    nav.open(context, spec);
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: spec.builder));
}

/// The progress page: the search progress card the Library shows, then "Adding a PDF": each PDF with its phases (the one
/// running), its hold and the indexing rules' words (the ones waiting), its result (added: where it was filed, Move and Undo; in
/// Unsorted: Place; a spare copy), or what stopped it.
class AddPdfProgressPage extends StatelessWidget {
  const AddPdfProgressPage({super.key, required this.state, this.deps, this.scheduler});

  final AddPdfState state;
  final LibraryDeps? deps;

  /// The scheduler whose words and holds it shows; the app's when null.
  final IndexScheduler? scheduler;

  @override
  Widget build(BuildContext context) {
    final nav = LibraryNav.of(context);
    final s = scheduler ?? indexSchedulerShared;
    final compact = nav.compact;
    return Scaffold(
      appBar: compact ? AppBar(title: const Text('Progress')) : libraryAppBar(context, title: 'Adding a PDF'),
      body: ListenableBuilder(
        listenable: Listenable.merge([state, ?s, ?deps?.shelves]),
        builder: (context, _) {
          final jobs = state.jobs;
          return LayoutBuilder(
            builder: (context, c) {
              final side = c.maxWidth > 680 ? (c.maxWidth - 640) / 2 : 12.0;
              return ListView(
                key: const ValueKey('add-pdf-progress'),
                // a reading width on a wide window; in the panes it starts at the pane's edge
                padding: EdgeInsets.fromLTRB(compact ? side : 12, 4, compact ? side : side.clamp(12.0, 400.0), 24),
                children: [
                  if (compact && s != null) IndexOverviewLine(scheduler: s, queueOnTap: true),
                  if (compact) const GroupLabel('Adding a PDF'),
                  if (jobs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('No PDFs are being added.', style: TextStyle(fontSize: 14, color: context.t.secondary)),
                    ),
                  for (final j in jobs) ...[
                    AddPdfJobCard(state: state, job: j, scheduler: s, deps: deps, full: !compact),
                    const SizedBox(height: 10),
                  ],
                  if (jobs.any((j) => j.status == AddPdfStatus.active))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                      child: Text('You can leave this screen. It keeps going.', style: TextStyle(fontSize: 14, color: context.t.secondary)),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Stop adding this PDF? Asked once; nothing has been added yet.
Future<bool> confirmStopAdding(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop adding this PDF?'),
        content: const Text('Nothing has been added to your library. Your PDF is not changed.'),
        actions: [
          _Txt(key: const ValueKey('add-pdf-keep-going'), label: 'Keep going', onPressed: () => Navigator.of(ctx).pop(false)),
          _Txt(key: const ValueKey('add-pdf-stop'), label: 'Stop adding', danger: true, onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      ),
    ) ==
    true;

/// One PDF on the progress page, in whatever state it is.
class AddPdfJobCard extends StatelessWidget {
  const AddPdfJobCard({super.key, required this.state, required this.job, this.scheduler, this.deps, this.full = false});

  final AddPdfState state;
  final AddPdfJob job;
  final IndexScheduler? scheduler;
  final LibraryDeps? deps;

  /// In the panes: the book card above the phases (the number comes when it is saved).
  final bool full;

  @override
  Widget build(BuildContext context) => switch (job.status) {
    AddPdfStatus.done => _ResultCard(state: state, job: job, deps: deps),
    AddPdfStatus.failed => _ErrorCard(state: state, job: job),
    AddPdfStatus.active => _active(context),
  };

  Widget _active(BuildContext context) {
    final item = scheduler?.statusOf(job.key);
    final running = item?.state == IndexState.running && item?.why == IndexWait.none;
    if (job.busy) return _BusyCard(state: state, job: job);
    if (job.pausedByPerson) return _HeldCard(state: state, job: job, words: 'Paused by you · Resume', action: ('Resume', Icons.play_arrow_outlined, () => state.resume(job)));
    // slowed for heat: the short card, in the indexing rules' words, with Pause
    if (running && item!.slowed) {
      return _HeldCard(state: state, job: job, words: indexSlowedWords(item.warm), action: ('Pause', Icons.pause, () => state.pause(job)));
    }
    if (running || item == null || item.state == IndexState.queued) return _PhaseCard(state: state, job: job, full: full);
    final why = item.why;
    final words = indexWaitWords(why, battery: scheduler?.reading, bytesNeeded: item.bytesNeeded, warm: item.warm) ?? 'Waiting';
    final (String, IconData, VoidCallback) action = switch (why) {
      IndexWait.charging => ('Start now', Icons.play_arrow_outlined, () => state.startNow(job)),
      IndexWait.battery => ('Resume anyway', Icons.play_arrow_outlined, () => state.resumeAnyway(job)),
      IndexWait.person => ('Resume', Icons.play_arrow_outlined, () => scheduler?.resumeAll()),
      IndexWait.stuck => ('Retry', Icons.refresh, () => scheduler?.retry(job.key)),
      IndexWait.storage => ('Free space', Icons.storage_outlined, () => openStorageForSpace?.call(context)),
      _ => ('Pause', Icons.pause, () => state.pause(job)),
    };
    return _HeldCard(state: state, job: job, words: words, action: action);
  }
}

Future<void> _cancel(BuildContext context, AddPdfState state, AddPdfJob job) async {
  if (job.status == AddPdfStatus.active && !await confirmStopAdding(context)) return;
  await state.cancel(job);
}

/// The PDF running now: its phases in order (done, running, to come), the time left, Pause and Cancel.
class _PhaseCard extends StatelessWidget {
  const _PhaseCard({required this.state, required this.job, this.full = false});

  final AddPdfState state;
  final AddPdfJob job;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final now = job.phase;
    final phases = [AddPdfPhase.reading, if (job.sawOcr || now == AddPdfPhase.ocr) AddPdfPhase.ocr, AddPdfPhase.searchable, AddPdfPhase.saving];
    final left = addPdfTimeLeft(job);
    final leftWords = '${aboutMinutes(left)} left${(indexSchedulerShared?.reading?.charging ?? true) ? ' while charging' : ''}';
    Widget phase(AddPdfPhase p) {
      final i = phases.indexOf(p), at = phases.indexOf(now);
      final done = i < at;
      final running = i == at;
      final (String? sub, double? bar) = switch (p) {
        AddPdfPhase.reading => (done ? '${job.pages} pages' : (running && job.pages > 0 ? 'Page ${job.pagesDone} of ${job.pages}' : null), null),
        AddPdfPhase.ocr => (
            running || done ? 'Page ${job.scansDone + job.scanInBatch} of ${job.scans} scans' : null,
            running && job.scans > 0 ? (job.scansDone + job.scanInBatch) / job.scans : null,
          ),
        AddPdfPhase.searchable => (running && job.pieces > 0 ? '${job.searchablePercent}%' : null, running && job.pieces > 0 ? job.piecesDone / job.pieces : null),
        AddPdfPhase.saving => (null, null),
      };
      final lead = done
          ? const _DoneDot()
          : running
              ? SizedBox(width: 24, height: 24, child: Padding(padding: const EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2.4, color: k.accent, value: null)))
              : Container(width: 24, height: 24, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.secondary.withValues(alpha: 0.6), width: 1.5)));
      return Padding(
        key: ValueKey('add-pdf-phase-${p.name}'),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            lead,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(addPdfPhaseWords(p), style: TextStyle(fontSize: 15, color: done || running ? k.text : k.secondary)),
                  if (sub != null) Text(sub, style: TextStyle(fontSize: 13, color: k.secondary)),
                  if (bar != null) Padding(padding: const EdgeInsets.only(top: 6), child: _bar(context, bar.clamp(0.0, 1.0))),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (full) ...[_BookCard(title: job.title), const SizedBox(height: 10)],
        _Card(
          child: Column(
            key: ValueKey('add-pdf-job-${job.id}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (full)
                Text('${formatBytes(job.bytes)} · ${job.libraryTitle}', style: TextStyle(fontSize: 15, color: k.text))
              else ...[
                Text(job.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                Text('${formatBytes(job.bytes)} · ${job.libraryTitle}', style: TextStyle(fontSize: 13, color: k.secondary)),
              ],
              const SizedBox(height: 6),
              for (final p in phases) phase(p),
              Text(leftWords, key: const ValueKey('add-pdf-left'), style: TextStyle(fontSize: 13, color: k.secondary)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _Ghost(key: const ValueKey('add-pdf-pause'), label: 'Pause', icon: Icons.pause, onPressed: () => state.pause(job)),
                _Txt(key: const ValueKey('add-pdf-cancel-job'), label: 'Cancel', onPressed: () => _cancel(context, state, job)),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// A PDF waiting or held: its phase, its bar, the indexing rules' words in the warning color, and the one thing to do.
class _HeldCard extends StatelessWidget {
  const _HeldCard({required this.state, required this.job, required this.words, required this.action});

  final AddPdfState state;
  final AddPdfJob job;
  final String words;
  final (String, IconData, VoidCallback) action;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return _Card(
      child: Column(
        key: ValueKey('add-pdf-job-${job.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(job.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
          Text(job.stepWords, style: TextStyle(fontSize: 13, color: k.secondary)),
          const SizedBox(height: 8),
          _bar(context, job.fraction, warn: true),
          const SizedBox(height: 8),
          Text(words, key: ValueKey('add-pdf-held-${job.id}'), style: TextStyle(fontSize: 13, color: k.warning)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _Ghost(key: ValueKey('add-pdf-act-${job.id}'), label: action.$1, icon: action.$2, onPressed: action.$3),
            _Txt(label: 'Cancel', onPressed: () => _cancel(context, state, job)),
          ]),
        ],
      ),
    );
  }
}

/// Another PDF is being saved into the same library: a calm wait, not an error. The job tries again by itself.
class _BusyCard extends StatelessWidget {
  const _BusyCard({required this.state, required this.job});

  final AddPdfState state;
  final AddPdfJob job;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return _Note(
      key: ValueKey('add-pdf-busy-${job.id}'),
      plain: true,
      tone: k.warning,
      leading: _ErrIcon(Icons.schedule, k.warning),
      title: 'Waiting for another PDF',
      body: 'One is being saved. This one goes next.',
      actions: [_Txt(label: 'Cancel', onPressed: () => _cancel(context, state, job))],
    );
  }
}

/// What stopped a PDF, in plain words: what happened, what is safe, and one next step.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.state, required this.job});

  final AddPdfState state;
  final AddPdfJob job;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final w = addPdfErrorWords(job);
    final code = job.errorCode;
    final icon = switch (code) {
      'locked' => Icons.lock_outline,
      'no_space' => Icons.storage_outlined,
      _ => Icons.warning_amber_rounded,
    };
    Future<void> another() async {
      final nav = Navigator.of(context);
      await state.cancel(job);
      await startAddPdfOn(nav);
    }

    final actions = <Widget>[
      if (code == 'no_text' && job.ocr == 'off') _Ghost(label: 'Turn on scanned pages', onPressed: () => state.turnOnScans(job)),
      if (code == 'not_pdf' || code == 'damaged' || code == 'locked') _Ghost(label: 'Choose another file', onPressed: another),
      if (code == 'no_space' && openStorageForSpace != null) _Ghost(label: 'Free space', onPressed: () => openStorageForSpace!(context)),
      if (!(code == 'no_text' && job.ocr == 'off') && code != 'not_pdf' && code != 'damaged' && code != 'locked') _Ghost(label: 'Try again', onPressed: () => state.retry(job)),
      _Txt(label: 'Cancel', onPressed: () => state.cancel(job)),
    ];
    return _Note(
      key: ValueKey('add-pdf-error-${job.id}'),
      plain: true,
      tone: k.emergency,
      leading: _ErrIcon(icon, k.emergency),
      title: w.title,
      body: w.body,
      actions: actions,
    );
  }
}

/// The book card above the phases in the panes: "Number comes when it is saved", the title in the catalogue card's serif.
class _BookCard extends StatelessWidget {
  const _BookCard({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(6), border: Border.all(color: k.secondary.withValues(alpha: 0.35))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.25)))),
            child: Row(
              children: [
                Expanded(child: Text('Number comes when it is saved', style: TextStyle(fontSize: 14, color: k.secondary))),
                Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.secondary.withValues(alpha: 0.5), width: 1.5))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(title, style: TextStyle(fontFamily: kCdsSerif, fontVariations: serifWeight(FontWeight.w700), fontWeight: FontWeight.w700, fontSize: 21, height: 1.3, color: k.text)),
        ],
      ),
    );
  }
}

/// The book [job] made, as Bookshelves has it now (found by its copy key), or null while Bookshelves have not read it yet.
ShelfBook? addPdfBook(LibraryDeps? d, AddPdfJob job) {
  final copy = job.result?['copy'] as String?;
  return copy == null || d == null ? null : d.shelves.book(copy);
}

/// A finished PDF: a green check, where it went, and what can be done about it.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.state, required this.job, this.deps});

  final AddPdfState state;
  final AddPdfJob job;
  final LibraryDeps? deps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final r = job.result ?? const {};
    final pieces = (r['pieces'] as num?)?.toInt();
    final same = (r['same'] as List?) ?? const [];
    final shelf = (r['shelf'] as Map?)?.cast<String, dynamic>();
    final suggested = (r['suggested'] as Map?)?.cast<String, dynamic>();
    final d = deps;
    final book = addPdfBook(d, job);
    final note = job.noteDone ? null : addPdfResultNote(context, state, job, book: book, deps: d, same: same, shelf: shelf, suggested: suggested);
    final unsure = same.isEmpty && shelf == null;
    return _Card(
      child: Column(
        key: ValueKey('add-pdf-result-${job.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _DoneDot(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                    Text(
                      same.isNotEmpty
                          ? 'Added to ${job.libraryTitle}'
                          : (shelf != null && pieces != null ? 'Added to ${job.libraryTitle} · $pieces pieces searchable' : 'Added to ${job.libraryTitle} · searchable'),
                      style: TextStyle(fontSize: 13, color: k.secondary),
                    ),
                  ],
                ),
              ),
              IconButton(key: ValueKey('add-pdf-dismiss-${job.id}'), tooltip: 'Hide', icon: Icon(Icons.close, size: 18, color: k.secondary), onPressed: () => state.dismiss(job)),
            ],
          ),
          if (note != null) ...[const SizedBox(height: 12), note],
          const SizedBox(height: 12),
          _Big(
            key: ValueKey('add-pdf-open-${job.id}'),
            label: 'Open book',
            outlined: unsure && !job.noteDone && suggested != null,
            onPressed: book == null || d == null ? null : () => LibraryNav.of(context).open(context, bookSpec(d, book.id)),
          ),
        ],
      ),
    );
  }
}

/// The note under a finished PDF (and once on its book page): filed (Move, Undo), in Unsorted with the sorter's guess (Place,
/// Other, Leave), or a spare copy of a book already on the shelves (Not the same book). Null when there is nothing to say.
Widget? addPdfResultNote(
  BuildContext context,
  AddPdfState state,
  AddPdfJob job, {
  ShelfBook? book,
  LibraryDeps? deps,
  List<Object?>? same,
  Map<String, dynamic>? shelf,
  Map<String, dynamic>? suggested,
  bool oneLine = false,
}) {
  final k = context.t;
  final r = job.result ?? const {};
  same ??= (r['same'] as List?) ?? const [];
  shelf ??= (r['shelf'] as Map?)?.cast<String, dynamic>();
  suggested ??= (r['suggested'] as Map?)?.cast<String, dynamic>();
  final d = deps;
  final placer = d?.shelves.placer;
  final copies = d?.shelves.copies;
  if (same.isNotEmpty) {
    final m = (same.first as Map).cast<String, dynamic>();
    final other = d?.shelves.book((m['with'] ?? '') as String);
    final name = other == null ? 'a book you have' : (other.callNumber == null ? other.title : '${other.title}, ${other.callNumber}');
    final exact = m['how'] == 'blake3';
    return _Note(
      key: ValueKey('add-pdf-note-${job.id}'),
      tone: k.accent,
      title: 'A spare copy of an existing book',
      body: exact ? 'Same file as $name. It shares that number.' : 'Looks like another copy of $name.',
      actions: [
        _Ghost(
          label: 'Not the same book',
          onPressed: copies == null || book == null
              ? null
              : () async {
                  await copies.notSame(book, (r['copy'] ?? '') as String);
                  state.noteHandled(job);
                },
        ),
      ],
    );
  }
  if (shelf != null) {
    final div = (shelf['div'] ?? '') as String;
    final undo = placer is ShelfUnsorter && book != null
        ? () async {
            await (placer as ShelfUnsorter).unsort(book);
            state.noteHandled(job);
          }
        : null;
    final move = d == null || book == null ? null : () => openPlace(context, d, book);
    if (oneLine) {
      return _Note(
        key: ValueKey('add-pdf-note-${job.id}'),
        tone: k.ok,
        title: 'Filed in ${cdsChipLabel(div)}',
        trailing: [_Txt(label: 'Move', onPressed: move), _Txt(label: 'Undo', onPressed: undo)],
      );
    }
    return _Note(
      key: ValueKey('add-pdf-note-${job.id}'),
      tone: k.ok,
      title: 'Filed in ${cdsChipLabel(div)}',
      body: book?.callNumber,
      actions: [
        _Ghost(key: ValueKey('add-pdf-move-${job.id}'), label: 'Move', onPressed: move),
        _Ghost(key: ValueKey('add-pdf-undo-${job.id}'), label: 'Undo', icon: Icons.undo, onPressed: undo),
      ],
    );
  }
  final guess = suggested?['div'] as String?;
  final other = d == null || book == null ? null : () => openPlace(context, d, book);
  return _Note(
    key: ValueKey('add-pdf-note-${job.id}'),
    tone: k.warning,
    title: 'In Unsorted',
    body: guess == null ? "Cache wasn't sure where it goes. Pick a subject for it." : 'Looks like ${cdsChipLabel(guess)}. Place it there?',
    actions: [
      if (guess != null)
        FilledButton(
          key: ValueKey('add-pdf-place-${job.id}'),
          style: FilledButton.styleFrom(backgroundColor: k.primary, foregroundColor: k.onPrimary, minimumSize: const Size(0, 40), shape: const StadiumBorder()),
          onPressed: placer == null || book == null
              ? null
              : () async {
                  await placer.place([(book, guess)]);
                  state.noteHandled(job);
                },
          child: const Text('Place'),
        ),
      _Ghost(label: guess == null ? 'Place it' : 'Other', onPressed: other),
      _Txt(label: 'Leave', onPressed: () => state.noteHandled(job)),
    ],
  );
}

/// The one-line note on the book's page, shown once after the book was filed: "Filed in 530 Water treatment", Move, Undo.
class AddPdfBookNote extends StatefulWidget {
  const AddPdfBookNote({super.key, required this.book, required this.deps});

  final ShelfBook book;
  final LibraryDeps deps;

  @override
  State<AddPdfBookNote> createState() => _AddPdfBookNoteState();
}

class _AddPdfBookNoteState extends State<AddPdfBookNote> {
  AddPdfJob? _job;

  @override
  void initState() {
    super.initState();
    final s = addPdfShared;
    final job = s?.freshNoteFor(widget.book.reading ?? widget.book.id);
    if (job != null && job.result?['shelf'] is Map) {
      _job = job;
      // it shows this once: the next time the page opens it is gone
      WidgetsBinding.instance.addPostFrameCallback((_) => s!.noteShown(job));
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final s = addPdfShared;
    if (job == null || s == null || job.noteDone) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: addPdfResultNote(context, s, job, book: widget.book, deps: widget.deps, oneLine: true),
    );
  }
}

/// "Add a PDF" in Add to Library, under Your own, beside Your own library.
class AddPdfRow extends StatelessWidget {
  const AddPdfRow({super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    const radius = BorderRadius.vertical(top: Radius.circular(4), bottom: Radius.circular(14));
    return Material(
      color: k.surface,
      borderRadius: radius,
      child: InkWell(
        key: const ValueKey('add-pdf'),
        borderRadius: radius,
        onTap: () => startAddPdf(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const _FileTile(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Add a PDF', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      Text('A manual or a scanned book', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: k.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The outlined Add PDF button on Bookshelves.
class AddPdfShelvesButton extends StatelessWidget {
  const AddPdfShelvesButton({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: _Ghost(key: const ValueKey('shelves-add-pdf'), label: 'Add PDF', icon: Icons.add, onPressed: () => startAddPdf(context)),
  );
}

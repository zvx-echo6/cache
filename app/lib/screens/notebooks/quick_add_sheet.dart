import 'package:flutter/material.dart';

import '../../notebook/markdown_text.dart';
import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/places.dart';
import '../../theme.dart';
import 'field_inputs.dart';

/// The quick add sheet of a Log notebook (UX 3.3): When (now), one control per field, Notes, Save. Numbers, choices and Yes/No
/// start from the last entry's values; text, notes and photos start empty; a place field starts at Here. "Tap +, tap Save" logs.
/// With [entry] the sheet edits that entry and its menu has Delete.
Future<void> showQuickAdd(
  BuildContext context, {
  required NotebookState notebook,
  required Notebook log,
  required PlaceChoices places,
  NbEntry? entry,
  DateTime Function()? now,
}) {
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => QuickAddSheet(notebook: notebook, log: log, places: places, entry: entry, now: now ?? DateTime.now, messenger: messenger),
  );
}

class QuickAddSheet extends StatefulWidget {
  const QuickAddSheet({super.key, required this.notebook, required this.log, required this.places, this.entry, required this.now, this.messenger});

  final NotebookState notebook;
  final Notebook log;
  final PlaceChoices places;
  final NbEntry? entry;
  final DateTime Function() now;

  /// Where "Saved to ... · Undo" shows once the sheet is closed.
  final ScaffoldMessengerState? messenger;

  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  late DateTime? _when = widget.entry?.when;
  late final Map<String, Object?> _values = {};
  late final MarkdownController _notes = MarkdownController(text: widget.entry?.body ?? '');
  bool _saving = false;
  String? _error;

  NotebookDef get def => widget.log.def;
  NbEntry? get _last => widget.log.lastEntry;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    if (e != null) {
      _values.addAll(e.values);
    } else {
      for (final f in def.visible) {
        final v = _last?.values[f.fid];
        if (v != null && (f.type == FieldType.number || f.type == FieldType.choice || f.type == FieldType.yesNo)) _values[f.fid!] = v;
      }
      final placeFields = [for (final f in def.visible) if (f.type == FieldType.place) f];
      if (placeFields.isNotEmpty) {
        widget.places.herePlace().then((p) {
          if (p != null && mounted) setState(() => _values.putIfAbsent(placeFields.first.fid!, () => p.toJson()));
        }).catchError((_) {});
      }
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickWhen() async {
    final base = _when ?? widget.now();
    final d = await showDatePicker(context: context, initialDate: base, firstDate: DateTime(1900), lastDate: DateTime(2200));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (!mounted) return;
    setState(() => _when = DateTime(d.year, d.month, d.day, t?.hour ?? base.hour, t?.minute ?? base.minute));
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final when = _when ?? widget.now();
    try {
      final saved = await widget.notebook.saveEntry(
        id: widget.entry?.id,
        notebookId: widget.log.id,
        occurredAt: widget.entry != null && _when == widget.entry!.when ? widget.entry!.occurredAt : isoLocal(when),
        values: {for (final e in _values.entries) if (e.value != null) e.key: e.value},
        body: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        place: widget.entry?.place,
        photos: widget.entry?.photos ?? const [],
        files: widget.entry?.files ?? const [],
      );
      if (!mounted) return;
      Navigator.pop(context);
      if (widget.entry == null) {
        final m = widget.messenger;
        m?.hideCurrentSnackBar();
        m?.showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          persist: false, // a snack bar with an action would otherwise stay until dismissed
          content: Text('Saved to ${widget.log.name}'),
          action: SnackBarAction(label: 'Undo', onPressed: () => widget.notebook.deleteEntry(saved.id)),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Not saved. Your phone may be out of space.';
        });
      }
    }
  }

  Future<void> _delete() async {
    final e = widget.entry;
    if (e == null) return;
    Navigator.pop(context);
    await deleteWithUndo(widget.messenger, widget.notebook, e, 'Entry deleted');
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final now = widget.now();
    final when = _when;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(widget.log.name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text))),
                  if (widget.entry != null)
                    IconButton(key: const ValueKey('quick-delete'), tooltip: 'Delete', icon: Icon(Icons.delete_outline, color: k.emergency), onPressed: _delete),
                ],
              ),
              InkWell(
                key: const ValueKey('quick-when'),
                onTap: _pickWhen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Text('When', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          when == null ? 'Now · ${dayTimeText(now, now: now)}' : dayTimeText(when, now: now),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: TextStyle(fontSize: 15, color: k.secondary),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: k.secondary),
                    ],
                  ),
                ),
              ),
              for (final f in def.visible)
                if (f.fid != null)
                  FieldInput(
                    field: f,
                    value: _values[f.fid],
                    last: widget.entry == null ? _last?.values[f.fid] : null,
                    notebook: widget.notebook,
                    places: widget.places,
                    onChanged: (v) => setState(() => _values[f.fid!] = v),
                  ),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('quick-notes'),
                controller: _notes,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Notes', hintText: 'optional', suffixIcon: MarkdownHelpButton()),
              ),
              if (_error != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: k.emergency))),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('quick-save'),
                onPressed: _saving ? null : _save,
                child: Text(_error == null ? 'Save' : 'Try again'),
              ),
              if (widget.entry == null && _last != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Values start from your last entry. Change nothing and tap Save.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: k.secondary)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deletes [e] after the 6 seconds of its "Undo" snackbar (UX: reversible beats a dialog); Undo keeps it. The entry leaves the
/// lists at once through [NotebookState.hide].
Future<void> deleteWithUndo(ScaffoldMessengerState? messenger, NotebookState nb, NbEntry e, String text) async {
  nb.hide(e.id);
  if (messenger == null) {
    await nb.deleteEntry(e.id);
    return;
  }
  messenger.hideCurrentSnackBar();
  final reason = await messenger
      .showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        persist: false, // a snack bar with an action would otherwise stay until dismissed
        content: Text(text),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ))
      .closed;
  if (reason == SnackBarClosedReason.action) {
    nb.unhide(e.id);
  } else {
    await nb.deleteEntry(e.id);
    nb.unhide(e.id);
  }
}

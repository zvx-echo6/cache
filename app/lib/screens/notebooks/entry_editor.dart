import 'dart:async';

import 'package:flutter/material.dart';

import '../../notebook/media.dart';
import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/places.dart';
import '../../theme.dart';
import 'field_inputs.dart';
import 'quick_add_sheet.dart' show deleteWithUndo;

/// The entry editor, the same for every notebook (UX 2.2): [x] the date (tap to change) [Done]; a title; the text; then only
/// what applies: the notebook's fields when it has some, the checklist once the entry has one, photos, the documents once
/// something is attached, the place, Private. Saves as you type: a new entry is an unfinished draft until Done; [x] keeps it.
class EntryEditor extends StatefulWidget {
  const EntryEditor({super.key, required this.notebook, required this.book, required this.places, this.entry, this.now = DateTime.now});

  final NotebookState notebook;
  final Notebook book;
  final PlaceChoices places;

  /// The entry to edit (a draft is continued); null makes a new one.
  final NbEntry? entry;
  final DateTime Function() now;

  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  late String? _id = widget.entry?.id;
  late bool _draft = widget.entry?.draft ?? true;
  late DateTime _when = widget.entry?.when ?? widget.now();
  late String? _occurredAt = widget.entry?.occurredAt;
  late final TextEditingController _title = TextEditingController(text: widget.entry?.title ?? '');
  late final TextEditingController _text;
  late List<CheckItem> _checks;
  late final Map<String, Object?> _values = {...?widget.entry?.values};
  late List<NbPhoto> _photos = [...?widget.entry?.photos];
  late List<NbFile> _files = [...?widget.entry?.files];
  late NbPlace? _place = widget.entry?.place;
  late bool _private = widget.entry?.private ?? false;
  bool _placePending = false;
  final List<NbPhoto> _addedPhotos = [];
  final List<NbFile> _addedFiles = [];
  Timer? _debounce;
  Future<void>? _saving;
  bool _failed = false;
  bool _dirty = false;

  bool get _isNew => widget.entry == null;

  @override
  void initState() {
    super.initState();
    final (text, checks) = splitChecklist(widget.entry?.body);
    _text = TextEditingController(text: text);
    _checks = checks;
    if (_isNew && widget.book.map) {
      _placePending = true;
      widget.places.herePlace().then((p) {
        if (!mounted) return;
        setState(() {
          _placePending = false;
          if (_place == null && p != null) _place = p;
        });
      }).catchError((_) {
        if (mounted) setState(() => _placePending = false);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  bool get _empty => _title.text.trim().isEmpty && _text.text.trim().isEmpty && _checks.isEmpty && _photos.isEmpty && _files.isEmpty && _values.values.every((v) => v == null);

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () => _save());
    setState(() {});
  }

  /// Saves what is on screen; [done] finishes a draft.
  Future<void> _save({bool done = false}) async {
    _debounce?.cancel();
    await _saving;
    if (_empty && _id == null) return;
    final run = () async {
      try {
        final body = joinChecklist(_text.text, _checks);
        final saved = await widget.notebook.saveEntry(
          id: _id,
          notebookId: widget.book.id,
          occurredAt: _occurredAt ?? isoLocal(_when),
          title: _title.text.trim().isEmpty ? null : _title.text.trim(),
          body: body.isEmpty ? null : body,
          values: {for (final e in _values.entries) if (e.value != null) e.key: e.value},
          place: _place,
          photos: _photos,
          files: _files,
          draft: _draft && !done,
          private: _private,
        );
        _id = saved.id;
        _occurredAt = saved.occurredAt;
        if (done) _draft = false;
        _dirty = false;
        _addedPhotos.clear();
        _addedFiles.clear();
        if (_failed && mounted) setState(() => _failed = false);
      } catch (e) {
        if (mounted) setState(() => _failed = true);
      }
    }();
    _saving = run;
    await run;
  }

  Future<void> _close({required bool done}) async {
    if (_dirty || done) await _save(done: done);
    if (_failed) return;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickWhen() async {
    final d = await showDatePicker(context: context, initialDate: _when, firstDate: DateTime(1900), lastDate: DateTime(2200));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (!mounted) return;
    _when = DateTime(d.year, d.month, d.day, t?.hour ?? _when.hour, t?.minute ?? _when.minute);
    _occurredAt = null;
    _changed();
  }

  Future<void> _delete() async {
    final id = _id;
    _debounce?.cancel();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    if (id == null) {
      await discardUnsaved(widget.notebook, photos: _addedPhotos, files: _addedFiles);
      return;
    }
    final e = await widget.notebook.entry(id);
    if (e != null) await deleteWithUndo(messenger, widget.notebook, e, 'Entry deleted');
  }

  Future<void> _attach() async {
    try {
      final f = await addFile(widget.notebook);
      if (f == null) return;
      _addedFiles.add(f);
      _files = [..._files, f];
      _changed();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not attach the file: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final fields = [for (final f in widget.book.def.visible) if (f.fid != null) f];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close(done: false);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(key: const ValueKey('editor-close'), tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => _close(done: false)),
          title: InkWell(
            key: const ValueKey('editor-when'),
            onTap: _pickWhen,
            child: Text(dayTimeText(_when, now: widget.now()), style: const TextStyle(fontSize: 17)),
          ),
          actions: [
            TextButton(key: const ValueKey('editor-done'), onPressed: () => _close(done: true), child: const Text('Done', style: TextStyle(fontSize: 17))),
            if (!_isNew)
              PopupMenuButton<String>(
                key: const ValueKey('editor-menu'),
                onSelected: (_) => _delete(),
                itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (_failed)
              MaterialBanner(
                content: const Text('Not saved. Your phone may be out of space.'),
                actions: [TextButton(onPressed: () => _save(), child: const Text('Try again'))],
              ),
            TextField(
              key: const ValueKey('editor-title'),
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text),
              decoration: const InputDecoration(hintText: 'Title (optional)', border: InputBorder.none),
              onChanged: (_) => _changed(),
            ),
            TextField(
              key: const ValueKey('editor-text'),
              controller: _text,
              autofocus: _isNew && fields.isEmpty,
              minLines: 4,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(fontSize: 17, height: 1.4, color: k.text),
              decoration: const InputDecoration(hintText: 'What happened? Where is it? What did you do?', border: InputBorder.none),
              onChanged: (_) => _changed(),
            ),
            for (final f in fields)
              FieldInput(
                field: f,
                value: _values[f.fid],
                notebook: widget.notebook,
                places: widget.places,
                onChanged: (v) {
                  _values[f.fid!] = v;
                  _changed();
                },
              ),
            if (_checks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Checklist', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
              for (var i = 0; i < _checks.length; i++) _checkRow(i),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('check-add'),
                  onPressed: () => setState(() => _checks = [..._checks, const CheckItem('')]),
                  icon: const Icon(Icons.add),
                  label: const Text('Add item'),
                ),
              ),
            ],
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 12),
              PhotoStrip(
                notebook: widget.notebook,
                ids: [for (final p in _photos) p.id],
                onAdded: _addedPhotos.add,
                onChanged: (ids) {
                  final known = {for (final p in [..._photos, ..._addedPhotos]) p.id: p};
                  final gone = [for (final p in _addedPhotos) if (!ids.contains(p.id)) p];
                  discardUnsaved(widget.notebook, photos: gone);
                  _addedPhotos.removeWhere(gone.contains);
                  _photos = [for (final id in ids) ?known[id]];
                  _changed();
                },
              ),
            ],
            if (_files.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Documents', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
              for (final f in _files)
                ListTile(
                  key: ValueKey('file-${f.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.description_outlined, color: k.secondary),
                  title: Text(f.name),
                  onTap: () => openFile(widget.notebook, f),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      if (_addedFiles.remove(f)) discardUnsaved(widget.notebook, files: [f]);
                      _files = [for (final x in _files) if (x.id != f.id) x];
                      _changed();
                    },
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_photos.isEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('add-photo'),
                    onPressed: () async {
                      final p = await choosePhoto(context, widget.notebook);
                      if (p == null) return;
                      _addedPhotos.add(p);
                      _photos = [..._photos, p];
                      _changed();
                    },
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: const Text('Add photo'),
                  ),
                OutlinedButton.icon(key: const ValueKey('attach-file'), onPressed: _attach, icon: const Icon(Icons.attach_file), label: const Text('Attach file')),
                if (_checks.isEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('add-checklist'),
                    onPressed: () => setState(() => _checks = [const CheckItem('')]),
                    icon: const Icon(Icons.checklist),
                    label: const Text('Add checklist'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            PlaceRow(
              place: _place,
              pending: _placePending,
              places: widget.places,
              onChanged: (p) {
                _place = p;
                _placePending = false;
                _changed();
              },
            ),
            if (!widget.book.private)
              SwitchListTile(
                key: const ValueKey('editor-private'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Private', style: TextStyle(fontSize: 17)),
                subtitle: Text('Left out of sharing and sync unless you choose to include it.', style: TextStyle(fontSize: 14, color: k.secondary)),
                value: _private,
                onChanged: (v) {
                  _private = v;
                  _changed();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _checkRow(int i) {
    final c = _checks[i];
    return Row(
      key: ValueKey('check-$i'),
      children: [
        Checkbox(
          value: c.done,
          onChanged: (v) {
            _checks = [..._checks]..[i] = CheckItem(c.text, done: v == true);
            _changed();
          },
        ),
        Expanded(
          child: TextFormField(
            initialValue: c.text,
            autofocus: c.text.isEmpty,
            decoration: const InputDecoration(border: InputBorder.none, hintText: 'Item'),
            onChanged: (v) {
              _checks = [..._checks]..[i] = CheckItem(v, done: c.done);
              _changed();
            },
          ),
        ),
        IconButton(
          tooltip: 'Remove item',
          icon: const Icon(Icons.close, size: 20),
          onPressed: () {
            _checks = [..._checks]..removeAt(i);
            _changed();
          },
        ),
      ],
    );
  }
}

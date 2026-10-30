import 'package:flutter/material.dart';

import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/templates.dart';
import '../../theme.dart';

/// Making a notebook from a template, or editing one (UX 3.4): Name; FIELDS with Add field (each: label, type, unit for a number,
/// choices for a choice); "Due again" for a log; Private; "Show on map" once entries have places. Create is off until there is a
/// name; a name another notebook has says so. Once there are entries a field's type is fixed, and taking out a field that holds
/// values hides it (the store keeps them).
class NotebookEditor extends StatefulWidget {
  const NotebookEditor({super.key, required this.notebook, this.existing, this.template}) : assert(existing != null || template != null);

  final NotebookState notebook;
  final Notebook? existing;
  final NotebookTemplate? template;

  @override
  State<NotebookEditor> createState() => _NotebookEditorState();
}

class _NotebookEditorState extends State<NotebookEditor> {
  late final NotebookDef _start = widget.existing?.def ?? widget.template!.def;
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? _freeName(widget.template!.name));
  late List<LogField> _fields = [for (final f in _start.fields) if (!f.hidden) f];
  late String? _due = _start.dueEvery;
  late bool _private = widget.existing?.private ?? widget.template!.private;
  late bool _map = widget.existing?.map ?? widget.template!.map;
  bool _saving = false;
  String? _error;

  bool get _hasEntries => (widget.existing?.entryCount ?? 0) > 0;

  /// "Journal", or "Journal 2" when that name is taken.
  String _freeName(String base) {
    if (!widget.notebook.nameTaken(base)) return base;
    for (var i = 2;; i++) {
      if (!widget.notebook.nameTaken('$base $i')) return '$base $i';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _taken => widget.notebook.nameTaken(_name.text, exceptId: widget.existing?.id);

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    // Fields taken out are left out; the store keeps those with values, hidden.
    final def = _start.copyWith(name: _name.text.trim(), fields: _fields, dueEvery: _due, clearDue: _due == null);
    try {
      final e = widget.existing;
      await widget.notebook.saveNotebook(
        id: e?.id,
        template: e == null ? widget.template!.template : null,
        def: def,
        private: _private,
        map: _map,
        templateRef: e == null ? widget.template!.ref : null,
      );
      if (mounted) Navigator.of(context).maybePop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceFirst(RegExp(r'^[a-z_]+: '), '');
        });
      }
    }
  }

  Future<void> _editField(int? index) async {
    final f = index == null ? null : _fields[index];
    final out = await showModalBottomSheet<_FieldEdit>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _FieldSheet(field: f, typeFixed: f?.fid != null && _hasEntries),
    );
    if (out == null) return;
    setState(() {
      if (out.remove) {
        _fields = [..._fields]..removeAt(index!);
      } else if (index == null) {
        _fields = [..._fields, out.field!];
      } else {
        _fields = [..._fields]..[index] = out.field!;
      }
    });
  }

  Future<void> _pickDue() async {
    const options = ['day', 'week', 'month', '3 months', '6 months', 'year'];
    final out = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: const Text('Not set'), onTap: () => Navigator.pop(ctx, '')),
            for (final o in options) ListTile(title: Text('Every ${everyText(o).substring(6)}'), onTap: () => Navigator.pop(ctx, o)),
            ListTile(title: const Text('Custom'), onTap: () => Navigator.pop(ctx, 'custom')),
          ],
        ),
      ),
    );
    if (out == null || !mounted) return;
    if (out == 'custom') {
      final custom = await _customDue();
      if (custom != null) setState(() => _due = custom);
      return;
    }
    setState(() => _due = out.isEmpty ? null : out);
  }

  Future<String?> _customDue() async {
    final n = TextEditingController(text: '2');
    var unit = 'weeks';
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Due again every'),
          content: Row(
            children: [
              SizedBox(width: 64, child: TextField(controller: n, keyboardType: TextInputType.number)),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: unit,
                items: [for (final u in const ['days', 'weeks', 'months', 'years']) DropdownMenuItem(value: u, child: Text(u))],
                onChanged: (u) => set(() => unit = u ?? unit),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final v = int.tryParse(n.text.trim());
                if (v == null || v < 1 || v > 999) return;
                Navigator.pop(ctx, v == 1 ? unit.substring(0, unit.length - 1) : '$v $unit');
              },
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    n.dispose();
    return r;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final isNew = widget.existing == null;
    final quickAdd = _start.quickAdd;
    final canSave = _name.text.trim().isNotEmpty && !_taken && !_saving;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        title: Text(isNew ? 'New notebook' : 'Edit notebook'),
        actions: [
          TextButton(
            key: const ValueKey('notebook-save'),
            onPressed: canSave ? _save : null,
            child: Text(isNew ? 'Create' : 'Save', style: const TextStyle(fontSize: 17)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const ValueKey('notebook-name'),
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: 'Name', errorText: _taken ? 'You already have a notebook with this name.' : null),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: k.emergency))),
          const SizedBox(height: 20),
          Text('FIELDS', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
          Text('When, text, place and photos are always there.', style: TextStyle(fontSize: 14, color: k.secondary)),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => setState(() {
              final f = [..._fields];
              f.insert(to.clamp(0, f.length - 1), f.removeAt(from));
              _fields = f;
            }),
            children: [
              for (var i = 0; i < _fields.length; i++)
                ListTile(
                  key: ValueKey('field-row-$i-${_fields[i].fid ?? _fields[i].label}'),
                  contentPadding: EdgeInsets.zero,
                  leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                  title: Text(_fields[i].label),
                  subtitle: Text([_fields[i].type.label, ?_fields[i].unit].join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editField(i),
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(key: const ValueKey('add-field'), onPressed: () => _editField(null), icon: const Icon(Icons.add), label: const Text('Add field')),
          ),
          if (quickAdd)
            ListTile(
              key: const ValueKey('due-again-row'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Due again'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_due == null ? 'Not set' : 'Every ${everyText(_due!).substring(6)}', style: TextStyle(color: k.secondary)),
                const Icon(Icons.chevron_right),
              ]),
              onTap: _pickDue,
            ),
          SwitchListTile(
            key: const ValueKey('notebook-private'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Private'),
            subtitle: Text('Left out of sharing and sync unless you choose to include it.', style: TextStyle(fontSize: 14, color: k.secondary)),
            value: _private,
            onChanged: (v) => setState(() => _private = v),
          ),
          if ((widget.existing?.placeCount ?? 0) > 0)
            SwitchListTile(
              key: const ValueKey('notebook-map'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Show on map'),
              subtitle: Text('In Maps, under My layers.', style: TextStyle(fontSize: 14, color: k.secondary)),
              value: _map,
              onChanged: (v) => setState(() => _map = v),
            ),
        ],
      ),
    );
  }
}

class _FieldEdit {
  const _FieldEdit(this.field, {this.remove = false});

  final LogField? field;
  final bool remove;
}

/// The field editor: Label, Type (six), Unit (number), Choices (choice, one per line), and Remove (Hide field once entries hold
/// values: the store keeps them).
class _FieldSheet extends StatefulWidget {
  const _FieldSheet({this.field, this.typeFixed = false});

  final LogField? field;
  final bool typeFixed;

  @override
  State<_FieldSheet> createState() => _FieldSheetState();
}

class _FieldSheetState extends State<_FieldSheet> {
  late final TextEditingController _label = TextEditingController(text: widget.field?.label ?? '');
  late final TextEditingController _unit = TextEditingController(text: widget.field?.unit ?? '');
  late final TextEditingController _choices = TextEditingController(text: (widget.field?.choices ?? const []).join('\n'));
  late FieldType _type = widget.field?.type ?? FieldType.text;

  @override
  void dispose() {
    _label.dispose();
    _unit.dispose();
    _choices.dispose();
    super.dispose();
  }

  List<String> get _choiceList {
    final out = <String>[];
    for (final l in _choices.text.split('\n')) {
      final t = l.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  bool get _ok => _label.text.trim().isNotEmpty && (_type != FieldType.choice || _choiceList.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final f = widget.field;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('field-label'),
                controller: _label,
                autofocus: f == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Label'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text('Type', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in FieldType.values)
                    ChoiceChip(label: Text(t.label), selected: _type == t, onSelected: widget.typeFixed ? null : (_) => setState(() => _type = t)),
                ],
              ),
              if (widget.typeFixed) Text("Can't change once entries exist. Add a new field instead.", style: TextStyle(fontSize: 14, color: k.secondary)),
              if (_type == FieldType.number)
                TextField(key: const ValueKey('field-unit'), controller: _unit, decoration: const InputDecoration(labelText: 'Unit', hintText: 'min, gal, jugs')),
              if (_type == FieldType.choice)
                TextField(
                  key: const ValueKey('field-choices'),
                  controller: _choices,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(labelText: 'Choices', hintText: 'One per line. The first is the default.'),
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('field-done'),
                onPressed: _ok
                    ? () => Navigator.pop(
                          context,
                          _FieldEdit(LogField(
                            fid: f?.fid,
                            label: _label.text.trim(),
                            type: _type,
                            unit: _type == FieldType.number && _unit.text.trim().isNotEmpty ? _unit.text.trim() : null,
                            choices: _type == FieldType.choice ? _choiceList : null,
                          )),
                        )
                    : null,
                child: const Text('Done'),
              ),
              if (f != null)
                TextButton(
                  key: const ValueKey('field-remove'),
                  onPressed: () => Navigator.pop(context, const _FieldEdit(null, remove: true)),
                  child: Text(widget.typeFixed ? 'Hide field' : 'Remove field', style: TextStyle(color: k.emergency)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

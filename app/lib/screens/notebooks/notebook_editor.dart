import 'package:flutter/material.dart';

import '../../notebook/map_icons.dart';
import '../../notebook/notebook_model.dart';
import '../../notebook/place_style.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/templates.dart';
import '../../theme.dart';
import '../../layout/adaptive.dart' show showFittedSheet;
import 'icon_picker.dart';

/// Making a notebook from a template, or editing one (UX 3.4): Name; its FIELDS, shown read only; "Due again" for a log; Private;
/// "Show on map" once entries have places. Create is off until there is a name; a name another notebook has says so.
///
/// A notebook keeps the fields it was made with (1.1, 2026-11-13: the field editor is gone, so a shared notebook's fields can no
/// longer drift apart between devices). Fields taken out by an earlier build stay hidden, with their values.
class NotebookEditor extends StatefulWidget {
  const NotebookEditor({super.key, required this.notebook, this.existing, this.template, this.icons}) : assert(existing != null || template != null);

  final NotebookState notebook;
  final Notebook? existing;
  final NotebookTemplate? template;

  /// Map icons: the "Map icon" row under the name. Null leaves it out.
  final MapIconSetup? icons;

  @override
  State<NotebookEditor> createState() => _NotebookEditorState();
}

class _NotebookEditorState extends State<NotebookEditor> {
  late final NotebookDef _start = widget.existing?.def ?? widget.template!.def;
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? _freeName(widget.template!.name));
  late String? _due = _start.dueEvery;
  late String? _icon = _start.icon;
  late String? _color = _start.color;
  late bool _private = widget.existing?.private ?? widget.template!.private;
  late bool _map = widget.existing?.map ?? widget.template!.map;
  late bool _shared = widget.existing == null ? false : widget.notebook.privateSharing?.included(widget.existing!.id) ?? false;
  bool _saving = false;
  String? _error;

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

  /// The places of this notebook that hold a color of their own, when the color was changed (else none): the question is asked
  /// about them.
  Future<List<NbEntry>> _ownColored() async {
    final e = widget.existing;
    if (e == null || widget.icons == null || _color == null || _color == _start.color) return const [];
    try {
      return [for (final x in await widget.notebook.entries(e.id)) if (x.color != null) x];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save() async {
    final own = await _ownColored();
    if (!mounted) return;
    // Asked once, before anything is saved: Change all lets those places follow the notebook again; anything else leaves them.
    final changeAll = own.isNotEmpty && await askChangeAllPlaces(context, color: markerColor(_color).spoken, notebook: _name.text.trim(), places: own.length) == true;
    if (!mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // The fields go back as they are, hidden ones included (the store also keeps an existing notebook's fields).
    final def = _start.copyWith(name: _name.text.trim(), dueEvery: _due, clearDue: _due == null, icon: widget.icons == null ? null : _icon, clearIcon: widget.icons != null && _icon == null, color: widget.icons == null ? null : _color);
    try {
      final e = widget.existing;
      final saved = await widget.notebook.saveNotebook(
        id: e?.id,
        template: e == null ? widget.template!.template : null,
        def: def,
        private: _private,
        map: _map,
        templateRef: e == null ? widget.template!.ref : null,
      );
      if (changeAll) {
        for (final x in own) {
          await widget.notebook.saveEntry(
            id: x.id,
            notebookId: x.notebookId,
            occurredAt: x.occurredAt,
            title: x.title,
            body: x.body,
            values: x.values,
            place: x.place,
            photos: x.photos,
            files: x.files,
            private: x.private,
            props: {...x.props}..remove('color'),
          );
        }
      }
      final ps = widget.notebook.privateSharing;
      if (ps != null && ps.included(saved.id) != (_private && _shared)) await ps.setIncluded(saved.id, _private && _shared);
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

  Future<void> _pickDue() async {
    const options = ['day', 'week', 'month', '3 months', '6 months', 'year'];
    final out = await showFittedSheet<String>(
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
          if (widget.icons != null) ...[
            const SizedBox(height: 8),
            MapIconRow(
              iconId: _icon,
              defaultId: widget.existing != null ? defaultNotebookIcon(widget.existing!) : defaultIconFor(widget.template!.template, log: _start.quickAdd),
              tint: iconTint(context, markerColor(_color).color),
              recent: widget.icons!.recent(),
              pinStyle: widget.icons!.pinStyle(),
              onChanged: (id) => setState(() => _icon = id),
            ),
            NotebookColorRow(colorId: _color, onChanged: (c) => setState(() => _color = c)),
          ],
          if (_start.visible.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('FIELDS', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
            Text('When, text, place and photos are always there.', style: TextStyle(fontSize: 14, color: k.secondary)),
            // Read only: a notebook keeps the fields it was made with.
            for (final f in _start.visible)
              ListTile(
                key: ValueKey('field-row-${f.fid ?? f.label}'),
                contentPadding: EdgeInsets.zero,
                title: Text(f.label),
                subtitle: Text([f.type.label, ?f.unit].join(' · ')),
              ),
          ],
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
          if (_private && widget.notebook.privateSharing != null)
            SwitchListTile(
              key: const ValueKey('notebook-include'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Include in sync and sharing'),
              subtitle: Text('Its entries go to your linked devices too.', style: TextStyle(fontSize: 14, color: k.secondary)),
              value: _shared,
              onChanged: (v) => setState(() => _shared = v),
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

/// Asked when a notebook's color is changed and some of its places hold a color of their own: true for Change all (they follow the
/// notebook again), false or dismissed for Keep their colors (only the notebook changes).
Future<bool?> askChangeAllPlaces(BuildContext context, {required String color, required String notebook, required int places}) => showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Change all its places to $color?'),
        content: Text(places == 1 ? '1 place in $notebook has its own color.' : '$places places in $notebook have their own color.'),
        actions: [
          TextButton(key: const ValueKey('colour-ask-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep their colors')),
          TextButton(key: const ValueKey('colour-ask-change'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Change all')),
        ],
      ),
    );

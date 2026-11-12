import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../weather/catalogue.dart';
import '../../weather/catalogue_store.dart';
import '../../weather/connector.dart';
import '../../weather/own_source.dart';
import '../../weather/weather_state.dart';
import 'deps.dart';
import 'widgets.dart';

/// Reads the text of a file the person chooses; null when nothing was chosen.
typedef PickText = Future<String?> Function();

/// The phone's file chooser: one file, read as text (a source file is small; one over 4 MB is refused).
Future<String?> pickTextFile() async {
  final picked = await FilePicker.pickFile();
  if (picked == null || picked.path == null) return null;
  try {
    final f = File(picked.path!);
    if (await f.length() > 4 * 1024 * 1024) throw const CatalogueException('That file is too large to be a source file.');
    return utf8.decode(await f.readAsBytes(), allowMalformed: true);
  } finally {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
  }
}

/// More sources > Add your own source: the row that opens the form.
class AddOwnSourceRow extends StatelessWidget {
  const AddOwnSourceRow({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Material(
      color: k.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: k.accent, width: 2)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('add-own-source'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OwnSourceFormPage(deps: deps))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.add, size: 22, color: k.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Add your own source', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                    const SizedBox(height: 2),
                    Text('Any web service that gives data', style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8)),
            ],
          ),
        ),
      ),
    );
  }
}

/// On a source of your own's page: Edit (for one the form made) and Remove this source.
class OwnSourceActions extends StatelessWidget {
  const OwnSourceActions({super.key, required this.deps, required this.source});

  final SettingsDeps deps;
  final Connector source;

  Future<void> _remove(BuildContext context) async {
    final w = deps.hub.weather;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${source.title}?'),
        content: const Text('It is taken off this device, with its key. You can add it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('confirm-remove-own'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final nav = Navigator.of(context);
    await w.removeOwnSource(source.id);
    if (context.mounted) say(context, 'Removed');
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final editable = readOwnDefinition(source.def) != null;
    return SettingsGroup(
      rows: [
        if (editable)
          SettingsRow(
            key: const ValueKey('edit-own'),
            icon: Icons.edit_outlined,
            title: 'Edit',
            status: const [Part('Name, address, key and what it shows')],
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OwnSourceFormPage(deps: deps, editing: source))),
          ),
        SettingsRow(key: const ValueKey('remove-own'), icon: Icons.delete_outline, title: 'Remove this source', danger: true, chevron: false, onTap: () => _remove(context)),
      ],
    );
  }
}

InputDecoration _box(CacheTokens k, {String? hint}) => InputDecoration(
  hintText: hint,
  hintStyle: TextStyle(color: k.secondary),
  isDense: true,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.secondary.withValues(alpha: 0.6))),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.secondary.withValues(alpha: 0.6), width: 1.5)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.accent, width: 2)),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
);

Widget _label(CacheTokens k, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(text, style: TextStyle(fontSize: 14, color: k.secondary)),
);

Widget _bigButton({Key? key, required String label, required VoidCallback? onPressed, bool busy = false}) => FilledButton(
  key: key,
  onPressed: busy ? null : onPressed,
  style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  child: busy
      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
      : Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
);

/// Add your own source: Name, Web address (with Latitude and Longitude, which put the place in it), Key and Check every. Try it
/// calls the address once and goes on to Pick what to show; nothing is saved before that. Under it, Or import a source file.
/// [editing] opens a source the form made, filled in.
class OwnSourceFormPage extends StatefulWidget {
  const OwnSourceFormPage({super.key, required this.deps, this.editing, this.pickText = pickTextFile});

  final SettingsDeps deps;
  final Connector? editing;
  final PickText pickText;

  @override
  State<OwnSourceFormPage> createState() => _OwnSourceFormPageState();
}

class _OwnSourceFormPageState extends State<OwnSourceFormPage> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  final _key = TextEditingController();
  int _every = kOwnRefreshDefault;
  String? _error;
  bool _busy = false;
  List<OwnPick>? _picks;
  bool _savedKey = false;

  WeatherState get w => widget.deps.hub.weather;

  @override
  void initState() {
    super.initState();
    final c = widget.editing;
    final read = c == null ? null : readOwnDefinition(c.def);
    if (read != null) {
      _name.text = read.draft.name;
      _address.text = read.draft.address;
      _every = kOwnRefreshChoices.contains(read.draft.refreshMinutes) ? read.draft.refreshMinutes : kOwnRefreshDefault;
      _picks = read.picks;
      _savedKey = read.draft.needsKey && w.hasKey(c!.id);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _addressFocus.dispose();
    _key.dispose();
    super.dispose();
  }

  OwnDraft get _draft => OwnDraft(name: _name.text, address: _address.text, key: _key.text, refreshMinutes: _every, id: widget.editing?.id, savedKey: _savedKey);

  void _insert(String placeholder) => setState(() => _address.value = insertPlaceholder(_address.value, placeholder));

  Future<void> _try() async {
    final d = _draft;
    final p = d.problem();
    setState(() => _error = p);
    if (p != null) return;
    setState(() => _busy = true);
    final t = await w.tryOwnSource(d);
    if (!mounted) return;
    setState(() => _busy = false);
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => OwnSourcePickPage(deps: widget.deps, draft: d, first: t, earlier: _picks)));
    if (saved == true && mounted) {
      say(context, widget.editing == null ? '${d.name.trim()} is on' : 'Saved');
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _import() async {
    final added = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => OwnImportPage(deps: widget.deps, pickText: widget.pickText)));
    if (added == true && mounted) Navigator.of(context).pop(true);
  }

  // ExcludeFocus: tapping an insert button never takes the keyboard's focus from the address, so the cursor stays where it is.
  Widget _placeButton(CacheTokens k, String key, String label, String placeholder) => ExcludeFocus(child: OutlinedButton(
    key: ValueKey(key),
    onPressed: () => _insert(placeholder),
    style: OutlinedButton.styleFrom(
      foregroundColor: k.accent,
      side: BorderSide(color: k.accent, width: 1.5),
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: const StadiumBorder(),
    ),
    child: Text(label, style: const TextStyle(fontSize: 14)),
  ));

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final editing = widget.editing != null;
    return SettingsPage(
      title: editing ? 'Edit source' : 'Add your own source',
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(k, 'Name'),
              TextField(key: const ValueKey('own-name'), controller: _name, textCapitalization: TextCapitalization.sentences, style: TextStyle(fontSize: 15, color: k.text), decoration: _box(k, hint: 'Creek level at the bridge')),
              const SizedBox(height: 14),
              _label(k, 'Web address'),
              TextField(
                key: const ValueKey('own-address'),
                controller: _address,
                focusNode: _addressFocus,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 1,
                maxLines: 4,
                style: TextStyle(fontSize: 15, color: k.text, fontFamily: 'monospace'),
                decoration: _box(k, hint: 'https://example.org/api/data'),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Insert the place:', style: TextStyle(fontSize: 13, color: k.secondary)),
                  _placeButton(k, 'insert-lat', 'Latitude', kLatPlaceholder),
                  _placeButton(k, 'insert-lon', 'Longitude', kLonPlaceholder),
                ],
              ),
              const SizedBox(height: 6),
              Text('Only for services that answer for a location. Then it works for every place weather watches.', style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary)),
              const SizedBox(height: 14),
              _label(k, 'Key (if the service needs one)'),
              TextField(
                key: const ValueKey('own-key'),
                controller: _key,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(fontSize: 15, color: k.text),
                decoration: _box(k, hint: _savedKey ? 'Saved. Type a new one to replace it.' : null),
              ),
              const SizedBox(height: 14),
              _label(k, 'Check every'),
              DropdownButtonFormField<int>(
                key: const ValueKey('own-every'),
                initialValue: _every,
                decoration: _box(k),
                dropdownColor: k.surface,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15, color: k.text),
                items: [for (final m in kOwnRefreshChoices) DropdownMenuItem(value: m, child: Text(ownRefreshWords(m)))],
                onChanged: (v) => setState(() => _every = v ?? kOwnRefreshDefault),
              ),
            ],
          ),
        ),
        if (_error != null) Text(_error!, key: const ValueKey('own-error'), style: TextStyle(fontSize: 14, height: 1.4, color: k.emergency)),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _bigButton(key: const ValueKey('own-try'), label: 'Try it', onPressed: _try, busy: _busy),
            const SizedBox(height: 8),
            Text('Cache calls it once and shows what came back. Nothing is saved yet.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: k.secondary)),
          ],
        ),
        if (!editing)
          SettingsGroup(
            rows: [
              SettingsRow(key: const ValueKey('own-import'), icon: Icons.download_outlined, title: 'Or import a source file', status: const [Part('One source, or a list of them, from a file or a link')], onTap: _import),
            ],
          ),
      ],
    );
  }
}

/// How a source of your own will look in Weather and alerts: its name over the line the Weather screen shows (the first ticked
/// value, then the next two).
class OwnPreview extends StatelessWidget {
  const OwnPreview({super.key, required this.name, required this.lines});

  final String name;

  /// "Label value", in the order ticked.
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      key: const ValueKey('own-preview'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How it will look in Weather and alerts', style: TextStyle(fontSize: 13, color: k.secondary)),
          const SizedBox(height: 6),
          Text(name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
          const SizedBox(height: 2),
          Text(lines.isEmpty ? 'Tick a value to show it' : lines.first, style: TextStyle(fontSize: 16, color: lines.isEmpty ? k.secondary : k.text)),
          if (lines.length > 1) Text(lines.skip(1).take(2).join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
        ],
      ),
    );
  }
}

/// Pick what to show: what the address answered, each value with a tick box and a name made from its key (tap to rename), a
/// preview, and Save source. When it did not answer with values: why, and Try again.
class OwnSourcePickPage extends StatefulWidget {
  const OwnSourcePickPage({super.key, required this.deps, required this.draft, required this.first, this.earlier});

  final SettingsDeps deps;
  final OwnDraft draft;
  final OwnTry first;

  /// The values ticked before (editing a source): ticked again, with their names.
  final List<OwnPick>? earlier;

  @override
  State<OwnSourcePickPage> createState() => _OwnSourcePickPageState();
}

class _OwnSourcePickPageState extends State<OwnSourcePickPage> {
  late OwnTry _t = widget.first;
  final Map<String, bool> _on = {};
  final Map<String, String> _names = {};
  bool _busy = false;
  String? _error;

  WeatherState get w => widget.deps.hub.weather;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  /// Ticks and names for the values of [_t]: kept from before where the value is the same; the first three ticked on a new source.
  void _seed() {
    final earlier = {for (final p in widget.earlier ?? const <OwnPick>[]) p.path: p.label};
    for (var i = 0; i < _t.values.length; i++) {
      final v = _t.values[i];
      _names.putIfAbsent(v.path, () => earlier[v.path] ?? v.label);
      _on.putIfAbsent(v.path, () => widget.earlier == null ? i < 3 : earlier.containsKey(v.path));
    }
  }

  List<OwnPick> get _picks {
    final order = [for (final p in widget.earlier ?? const <OwnPick>[]) p.path];
    final ticked = [for (final v in _t.values) if (_on[v.path] == true) OwnPick(v.path, _names[v.path] ?? v.label)];
    // the order ticked before first (the first is the line's lead), then the answer's order
    ticked.sort((a, b) {
      final ia = order.indexOf(a.path), ib = order.indexOf(b.path);
      if (ia == ib) return 0;
      if (ia < 0) return 1;
      if (ib < 0) return -1;
      return ia.compareTo(ib);
    });
    return ticked;
  }

  Future<void> _again() async {
    setState(() => _busy = true);
    final t = await w.tryOwnSource(widget.draft);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _t = t;
      _seed();
    });
  }

  Future<void> _rename(OwnValue v) async {
    final name = await showDialog<String>(context: context, builder: (_) => _RenameDialog(initial: _names[v.path] ?? v.label));
    if (name != null && name.isNotEmpty && mounted) setState(() => _names[v.path] = name);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await w.saveOwnSource(widget.draft, _picks, point: findPoint(_t.values));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) Navigator.of(context).pop(true);
  }

  Widget _banner(CacheTokens k) {
    final ok = _t.ok;
    final color = ok ? k.ok : k.warning;
    return Container(
      key: const ValueKey('own-answer'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: Color.alphaBlend(color.withValues(alpha: 0.16), k.surface), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(ok ? Icons.check : Icons.warning_amber_rounded, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(_t.words, style: TextStyle(fontSize: 15, height: 1.35, color: k.text))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final picks = tidyPicks(_picks);
    final lines = [
      for (final p in picks) '${p.label} ${_t.values.firstWhere((v) => v.path == p.path).value}',
    ];
    return SettingsPage(
      title: 'Pick what to show',
      // the preview and Save source stay in sight under the list, however long it is
      bottom: !_t.ok
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OwnPreview(name: widget.draft.name.trim(), lines: lines),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, key: const ValueKey('own-save-error'), style: TextStyle(fontSize: 14, height: 1.4, color: k.emergency)),
                  ],
                  const SizedBox(height: 10),
                  _bigButton(key: const ValueKey('own-save'), label: 'Save source', onPressed: picks.isEmpty ? null : _save, busy: _busy),
                ],
              ),
            ),
      children: [
        _banner(k),
        if (!_t.ok)
          _bigButton(key: const ValueKey('own-again'), label: 'Try again', onPressed: _again, busy: _busy)
        else ...[
          SettingsGroup(
            label: 'Tick what Cache should show',
            rows: [
              for (final v in _t.values)
                SettingsRow(
                  key: ValueKey('own-value-${v.path}'),
                  leading: Checkbox(value: _on[v.path] == true, onChanged: (x) => setState(() => _on[v.path] = x == true)),
                  title: _names[v.path] ?? v.label,
                  status: [Part(v.value)],
                  trailing: Icon(Icons.edit_outlined, size: 18, color: k.secondary),
                  onTap: () => _rename(v),
                ),
            ],
          ),
          const NoteText('Tap a name to rename it. Ask can read what you tick, so it can answer questions about it.'),
        ],
      ],
    );
  }
}

/// Or import a source file: one source definition, or a list of sources (the format the main source list is published in, so a
/// link to such a list still works), from a file or a link. Every source is checked and shown before anything is kept.
class OwnImportPage extends StatefulWidget {
  const OwnImportPage({super.key, required this.deps, this.pickText = pickTextFile});

  final SettingsDeps deps;
  final PickText pickText;

  @override
  State<OwnImportPage> createState() => _OwnImportPageState();
}

class _OwnImportPageState extends State<OwnImportPage> {
  final _link = TextEditingController();
  LoadedCatalogue? _preview;
  String? _error;
  bool _busy = false;

  WeatherState get w => widget.deps.hub.weather;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _read({String? text, String? link}) async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final p = await w.previewImport(text: text, link: link);
      if (mounted) setState(() => _preview = p);
    } on CatalogueException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't read that. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _file() async {
    final String? text;
    try {
      text = await widget.pickText();
    } on CatalogueException catch (e) {
      setState(() => _error = e.message);
      return;
    } catch (_) {
      setState(() => _error = "Couldn't read that file.");
      return;
    }
    if (text != null) await _read(text: text);
  }

  Future<void> _add() async {
    final p = _preview;
    if (p == null) return;
    setState(() => _busy = true);
    await w.addImported(p);
    if (!mounted) return;
    final n = p.definitions.length;
    say(context, n == 1 ? 'Added 1 source' : 'Added $n sources');
    Navigator.of(context).pop(true);
  }

  Widget _previewCard(CacheTokens k, LoadedCatalogue p) {
    final list = [for (final e in p.catalogue.entries) if (p.definitions[e.id] != null) e];
    return Container(
      key: const ValueKey('import-preview'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This adds ${list.length} ${list.length == 1 ? 'source' : 'sources'} to Your own. They stay off until you switch them on.',
            style: TextStyle(fontSize: 15, height: 1.4, color: k.text),
          ),
          const SizedBox(height: 6),
          for (final e in list)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                [e.title, if (e.provider.isNotEmpty) e.provider, if (e.coverage.isNotEmpty) e.coverage, if (e.needsKey) 'needs your own key'].join(' · '),
                style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary),
              ),
            ),
          if (p.skipped.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Left out (${p.skipped.length})', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.warning)),
            for (final e in p.skipped.entries)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('${e.key}: ${e.value}', style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary))),
          ],
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _preview = null),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder(), foregroundColor: k.text, side: BorderSide(color: k.secondary.withValues(alpha: 0.6), width: 1.5)),
                child: const Text('Cancel', style: TextStyle(fontSize: 16)),
              ),
              FilledButton(
                key: const ValueKey('import-add'),
                onPressed: _busy ? null : _add,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                child: const Text('Add these sources', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SettingsPage(
      title: 'Import a source file',
      children: [
        const NoteText('A source file describes one source, or a list of them. Cache checks every source and shows what it adds. Nothing is added until you say so.'),
        SettingsGroup(
          rows: [
            SettingsRow(key: const ValueKey('import-file'), icon: Icons.insert_drive_file_outlined, title: 'Choose a file', onTap: _busy ? null : _file),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label(k, 'Or the link to one'),
            TextField(
              key: const ValueKey('import-link'),
              controller: _link,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(fontSize: 15, color: k.text, fontFamily: 'monospace'),
              decoration: _box(k, hint: 'https://example.org/sources.json'),
            ),
            const SizedBox(height: 10),
            _bigButton(key: const ValueKey('import-check'), label: 'Check this link', onPressed: () => _read(link: _link.text), busy: _busy),
          ],
        ),
        if (_error != null) Text(_error!, key: const ValueKey('import-error'), style: TextStyle(fontSize: 14, height: 1.4, color: k.emergency)),
        if (_preview != null) _previewCard(k, _preview!),
      ],
    );
  }
}

/// Asks for a value's name. Answers the name, or nothing when cancelled. It owns its text field, which lives as long as the dialog.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Name'),
    content: TextField(key: const ValueKey('own-rename'), controller: _ctl, autofocus: true, textCapitalization: TextCapitalization.sentences),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(key: const ValueKey('own-rename-save'), onPressed: () => Navigator.pop(context, _ctl.text.trim()), child: const Text('Save')),
    ],
  );
}

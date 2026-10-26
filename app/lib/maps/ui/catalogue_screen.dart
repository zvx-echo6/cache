import 'package:flutter/material.dart';

import '../../settings/data_policy.dart';
import '../../theme.dart';
import '../layers/layer_def.dart';
import '../layers/layer_engine.dart';
import '../maps_state.dart';
import 'download_sheet.dart';
import 'format.dart';

/// "Get more layers": every layer in the catalogue with what it is, its licence, where it covers, and a
/// Download button. Downloads show progress, can be cancelled, updated and deleted, and the screen says how
/// much space layers use. An Advanced section (closed) edits layer definitions and source addresses.
class CatalogueScreen extends StatelessWidget {
  const CatalogueScreen({super.key, required this.maps});

  final MapsState maps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final engine = maps.engine;
    return Scaffold(
      appBar: AppBar(title: const Text('Layers')),
      body: ListenableBuilder(
        listenable: maps,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Layers use ${formatBytes(engine.storageTotal)} on this phone.',
                style: TextStyle(fontSize: 15, color: k.secondary),
              ),
            ),
            for (final l in maps.catalogueLayers) _LayerCard(key: ValueKey(l.id), maps: maps, def: l),
            const SizedBox(height: 8),
            _Advanced(key: const ValueKey('advanced'), maps: maps),
          ],
        ),
      ),
    );
  }
}

class _LayerCard extends StatelessWidget {
  const _LayerCard({super.key, required this.maps, required this.def});

  final MapsState maps;
  final LayerDef def;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final engine = maps.engine;
    final areas = maps.areasOfCard(def);
    final stored = maps.storageOfCard(def);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(def.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 4),
            Text(def.description, style: TextStyle(fontSize: 15, color: k.text, height: 1.35)),
            const SizedBox(height: 8),
            _fact(context, Icons.public, def.coverage),
            _fact(context, Icons.gavel, def.licence),
            if (def.onlineOnly) _fact(context, Icons.cloud_outlined, 'Online only'),
            if (stored > 0) _fact(context, Icons.sd_storage_outlined, '${formatBytes(stored)} on this phone'),
            for (final a in areas) _AreaRow(engine: engine, area: a),
            const SizedBox(height: 8),
            if (!def.onlineOnly)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: Key('download-${def.id}'),
                  onPressed: () => showAreaChoice(context, maps, def),
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fact(BuildContext context, IconData icon, String text) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: k.secondary)),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: k.secondary))),
        ],
      ),
    );
  }
}

class _AreaRow extends StatelessWidget {
  const _AreaRow({required this.engine, required this.area});

  final LayerEngine engine;
  final DownloadedArea area;

  Future<void> _confirmDelete(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${area.label}?'),
        content: const Text('The downloaded tiles are removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) await engine.delete(area.id);
  }

  Future<void> _update(BuildContext context, {bool anyway = false}) async {
    try {
      await engine.update(area.id, anyway: anyway);
    } on MobileDataBlocked catch (e) {
      if (!context.mounted) return;
      final m = ScaffoldMessenger.of(context);
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(
        content: Text(e.message),
        action: SnackBarAction(label: 'Download anyway', onPressed: () => _update(context, anyway: true)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final running = area.phase == AreaPhase.running;
    final updating = running && area.fetchedAt != null;
    final String status;
    Color color = k.secondary;
    switch (area.phase) {
      case AreaPhase.running:
        status = '${updating ? 'Updating' : 'Downloading'} ${(area.fraction * 100).toStringAsFixed(0)}%';
      case AreaPhase.done:
        status = '${formatBytes(area.bytes)} · ${area.fetchedAt == null ? '' : formatDate(area.fetchedAt!)}';
      case AreaPhase.failed:
        status = area.error ?? 'Could not be downloaded';
        color = k.emergency;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(border: Border.all(color: k.secondary.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(area.label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                  Text(status, style: TextStyle(fontSize: 14, color: color)),
                  if (area.error != null && area.phase == AreaPhase.done)
                    Text(area.error!, style: TextStyle(fontSize: 14, color: k.warning)),
                  if (running) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: area.fraction),
                  ],
                ],
              ),
            ),
            if (running)
              TextButton(onPressed: () => engine.cancel(area.id), child: const Text('Cancel'))
            else ...[
              IconButton(
                tooltip: 'Update',
                icon: Icon(Icons.refresh, color: k.secondary),
                onPressed: () => _update(context),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: Icon(Icons.delete_outline, color: k.secondary),
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Closed by default: the few levers stay out of the way. Layer definitions are data; editing one changes
/// where the layer comes from (its source address) and how it is described.
class _Advanced extends StatelessWidget {
  const _Advanced({super.key, required this.maps});

  final MapsState maps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text('Advanced', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [LayerDefinitions(maps: maps)],
        ),
      ),
    );
  }
}

/// The layer definitions: a switch and an edit button for each, and a way to add one. The Advanced section of the layers screen and
/// Settings > Maps > Advanced both show it.
class LayerDefinitions extends StatelessWidget {
  const LayerDefinitions({super.key, required this.maps});

  final MapsState maps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Each layer is a definition: what it is, its licence, and the address of its original source. '
          'Switch one off to leave it out, edit one to point Cache at your own server, or add a new one.',
          style: TextStyle(fontSize: 14, color: k.secondary),
        ),
        const SizedBox(height: 8),
        for (final l in maps.engine.layers)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.title),
            subtitle: Text(
              '${l.id} · ${l.sourceUrl.isEmpty ? 'no source address' : l.sourceUrl}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            secondary: IconButton(
              tooltip: 'Edit the definition of ${l.title}',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(context, l),
            ),
            value: maps.isDefinitionEnabled(l),
            onChanged: (v) => maps.setDefinitionEnabled(l.id, v),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _edit(context, null),
          icon: const Icon(Icons.add),
          label: const Text('Add a layer definition'),
        ),
      ],
    );
  }

  void _edit(BuildContext context, LayerDef? def) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DefinitionEditor(maps: maps, def: def)));
  }
}

/// Edits one layer definition as JSON. Saved only when it parses as a layer.
class DefinitionEditor extends StatefulWidget {
  const DefinitionEditor({super.key, required this.maps, this.def});

  final MapsState maps;
  final LayerDef? def;

  @override
  State<DefinitionEditor> createState() => _DefinitionEditorState();
}

const String _newDefinition = '''{
  "id": "my_layer",
  "title": "My layer",
  "description": "What this layer shows.",
  "licence": "",
  "attribution": "",
  "coverage": "Worldwide",
  "kind": "raster",
  "min_zoom": 0,
  "max_zoom": 14,
  "source": { "url": "https://example.com/tiles/{z}/{x}/{y}.png" }
}''';

class _DefinitionEditorState extends State<DefinitionEditor> {
  late final TextEditingController _text = TextEditingController(text: widget.def?.prettyJson() ?? _newDefinition);
  String? _error;

  Future<void> _save() async {
    try {
      await widget.maps.engine.saveDefinition(_text.text);
      if (mounted) Navigator.pop(context);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _remove() async {
    await widget.maps.engine.removeDefinition(widget.def!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.def?.title ?? 'New layer'),
        actions: [
          if (widget.def != null && widget.maps.engine.canRemove(widget.def!.id))
            IconButton(tooltip: 'Remove my version of this definition', icon: const Icon(Icons.delete_outline), onPressed: _remove),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(fontSize: 15, color: k.emergency)),
                ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}

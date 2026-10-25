import 'package:flutter/material.dart';

import '../../theme.dart';
import '../geo.dart';
import '../layers/layer_def.dart';
import '../maps_state.dart';
import 'format.dart';

/// The two ways to pick an area.
enum AreaChoice { thisRegion, drawArea }

/// Step one of a download: which area. "This region" is what the map shows now; "Draw an area" sends the user
/// to the map to draw a rectangle (the map screen then calls [showDownloadConfirm]).
Future<void> showAreaChoice(BuildContext context, MapsState maps, LayerDef def) async {
  final view = maps.viewBounds;
  final choice = await showModalBottomSheet<AreaChoice>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Download ${def.title}', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Which area?', style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: view == null ? null : () => Navigator.pop(ctx, AreaChoice.thisRegion),
              icon: const Icon(Icons.crop_free),
              label: const Text('This region'),
            ),
            const SizedBox(height: 4),
            Text(view == null ? 'Open the map first.' : 'What the map shows now.',
                textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(ctx, AreaChoice.drawArea),
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Draw an area'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case AreaChoice.thisRegion:
      await showDownloadConfirm(context, maps, def, view!, 'This region');
    case AreaChoice.drawArea:
      // Back to the map, which draws and then asks to confirm.
      maps.requestDraw(def.id);
      Navigator.of(context).popUntil((r) => r.isFirst);
  }
}

/// Step two: what the download costs, shown before anything is downloaded. Download starts it.
Future<void> showDownloadConfirm(BuildContext context, MapsState maps, LayerDef def, GeoBounds area, String label) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _Confirm(maps: maps, def: def, area: area, label: label),
  );
}

class _Confirm extends StatefulWidget {
  const _Confirm({required this.maps, required this.def, required this.area, required this.label});

  final MapsState maps;
  final LayerDef def;
  final GeoBounds area;
  final String label;

  @override
  State<_Confirm> createState() => _ConfirmState();
}

class _ConfirmState extends State<_Confirm> {
  AreaEstimate? _est;
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    widget.maps.engine.estimate(widget.def.id, widget.area).then((e) {
      if (mounted) setState(() => _est = e);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'Could not work out the size');
    });
    widget.maps.engine.refreshOnline();
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      await widget.maps.engine.download(widget.def.id, widget.area, label: widget.label);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final est = _est;
    final online = widget.maps.engine.online;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Download ${widget.def.title}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            if (est == null && _error == null)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (est != null && est.allowed) ...[
              Text('${formatCount(est.tiles)} tiles', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
              Text('About ${formatBytes(est.bytes)} · detail down to zoom ${est.maxZoom}',
                  style: TextStyle(fontSize: 16, color: k.secondary)),
            ] else if (est != null)
              Text(est.problem ?? 'This area cannot be downloaded.', style: TextStyle(fontSize: 16, color: k.warning)),
            if (_error != null) Text(_error!, style: TextStyle(fontSize: 16, color: k.emergency)),
            if (est != null && est.allowed && !online) ...[
              const SizedBox(height: 8),
              Text('Downloading needs a connection.', style: TextStyle(fontSize: 15, color: k.warning)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: (est != null && est.allowed && online && !_starting) ? _start : null,
                    child: const Text('Download'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

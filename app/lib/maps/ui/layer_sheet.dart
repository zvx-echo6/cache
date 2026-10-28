import 'package:flutter/material.dart';

import '../../location/location_service.dart';
import '../../regions/regions_state.dart';
import '../../regions/ui/regions_screen.dart';
import '../../theme.dart';
import '../layers/layer_def.dart';
import '../maps_state.dart';
import 'catalogue_screen.dart';

/// The layer button's sheet: every layer on or off, opacity for overlays, and "Get more layers".
Future<void> showLayerSheet(BuildContext context, MapsState maps, LocationService location, {RegionsState? regions}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
    builder: (ctx) => LayerSheet(maps: maps, location: location, regions: regions),
  );
}

class LayerSheet extends StatelessWidget {
  const LayerSheet({super.key, required this.maps, required this.location, this.regions});

  final MapsState maps;
  final LocationService location;

  /// Regions and downloads; the sheet offers "Download a region" when it is there.
  final RegionsState? regions;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: Listenable.merge([maps, location]),
      builder: (context, _) {
        final base = [for (final l in maps.catalogueLayers) if (l.isBase) l];
        final overlays = [for (final l in maps.catalogueLayers) if (!l.isBase) l];
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shrinkWrap: true,
            children: [
              Text('Layers', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final l in base) _row(context, l),
              if (overlays.isNotEmpty) const Divider(height: 24),
              for (final l in overlays) _row(context, l),
              const Divider(height: 24),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show my position', style: TextStyle(fontSize: 17)),
                value: location.enabled,
                onChanged: (v) => location.setEnabled(v),
              ),
              const SizedBox(height: 8),
              if (regions != null) ...[
                FilledButton.icon(
                  key: const ValueKey('download-region'),
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionsScreen(regions: regions!)));
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('Download a region'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CatalogueScreen(maps: maps)));
                },
                icon: const Icon(Icons.add),
                label: const Text('Get more layers'),
              ),
              if (maps.engine.problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(maps.engine.problem!, style: TextStyle(fontSize: 15, color: k.emergency)),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, LayerDef l) {
    final k = context.t;
    final on = maps.isOn(l.id);
    final held = maps.areasOfCard(l).where((a) => a.phase == AreaPhase.done).isNotEmpty;
    final status = l.onlineOnly ? 'Needs a connection' : (held ? 'Downloaded for offline' : 'Streams when online');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.title, style: const TextStyle(fontSize: 17)),
          subtitle: Text(status, style: TextStyle(fontSize: 14, color: k.secondary)),
          value: on,
          onChanged: (v) => maps.setOn(l.id, v),
        ),
        if (on && !l.isBase)
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
            child: Row(
              children: [
                Text('Opacity', style: TextStyle(fontSize: 14, color: k.secondary)),
                Expanded(
                  child: Slider(
                    value: maps.opacityOf(l.id),
                    min: 0.1,
                    max: 1,
                    label: '${(maps.opacityOf(l.id) * 100).round()}%',
                    semanticFormatterCallback: (v) => '${(v * 100).round()} percent',
                    onChanged: (v) => maps.setOpacity(l.id, v),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${(maps.opacityOf(l.id) * 100).round()}%',
                      textAlign: TextAlign.end, style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

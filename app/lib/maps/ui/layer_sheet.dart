import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter/material.dart';

import '../../location/location_service.dart';
import '../../notebook/notebook_map.dart';
import '../../notebook/media.dart';
import '../../notebook/notebook_state.dart';
import '../../screens/notebooks/places_screen.dart' show importPlacesInto;
import '../../regions/regions_state.dart';
import '../../regions/ui/regions_list_sheet.dart';
import '../../regions/ui/regions_screen.dart';
import '../../theme.dart';
import '../layers/layer_def.dart';
import '../maps_state.dart';
import '../user_layers.dart';
import 'catalogue_screen.dart';

/// The layer button's sheet: every layer on or off, opacity for overlays, and "Get more layers".
Future<void> showLayerSheet(BuildContext context, MapsState maps, LocationService location, {RegionsState? regions, NotebookState? notebooks, UserLayersState? userLayers}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
    builder: (ctx) => LayerSheet(maps: maps, location: location, regions: regions, notebooks: notebooks, userLayers: userLayers),
  );
}

class LayerSheet extends StatelessWidget {
  const LayerSheet({super.key, required this.maps, required this.location, this.regions, this.notebooks, this.userLayers});

  final MapsState maps;
  final LocationService location;

  /// Regions and downloads; the sheet offers "Download a region" when it is there.
  final RegionsState? regions;

  /// The notebooks with places, listed under "My layers" by their own names, each with its map switch.
  final NotebookState? notebooks;

  /// The repeater lists, also under "My layers", and "Add from a file".
  final UserLayersState? userLayers;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: Listenable.merge([maps, location, ?notebooks, ?userLayers]),
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
              if (notebooks != null || userLayers != null) ...[
                const Divider(height: 24),
                Text('MY LAYERS', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: k.secondary)),
                if (notebooks case final nb?)
                  for (final n in myLayers(nb.notebooks))
                    SwitchListTile(
                      key: ValueKey('my-layer-${n.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                      value: n.map,
                      onChanged: (v) => nb.setOnMap(n, v),
                    ),
                if (userLayers case final u?)
                  for (final l in u.repeaterLists)
                    SwitchListTile(
                      key: ValueKey('my-layer-${l.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                      subtitle: Text(l.count == 1 ? '1 repeater' : '${l.count} repeaters', style: TextStyle(fontSize: 14, color: k.secondary)),
                      secondary: IconButton(
                        key: ValueKey('remove-${l.id}'),
                        tooltip: 'Delete ${l.name}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteList(context, u, l),
                      ),
                      value: l.visible,
                      onChanged: (v) => u.setVisible(l, v),
                    ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('my-layers-add'),
                    onPressed: () => addMapFile(context, notebooks: notebooks, userLayers: userLayers),
                    icon: const Icon(Icons.add),
                    label: const Text('Add from a file'),
                  ),
                ),
              ],
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
                    // The regions at the middle of the map, in the Regions sheet; with no map view yet, the list to search.
                    final v = maps.viewBounds;
                    if (v == null) {
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionsScreen(regions: regions!)));
                    } else {
                      Navigator.pop(context);
                      showRegionsSheet(context, regions!, lat: (v.south + v.north) / 2, lon: (v.west + v.east) / 2);
                    }
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

  Future<void> _deleteList(BuildContext context, UserLayersState u, UserLayer l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${l.name}?'),
        content: const Text('Its repeaters are taken off the map and Cache no longer knows them. You can add the file again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('confirm-delete-list'), onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: TextStyle(color: ctx.t.emergency))),
        ],
      ),
    );
    if (yes == true) await u.delete(l);
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

/// "Add from a file": places (a KML, KMZ, GPX or GeoJSON file, into a new Places notebook) or a repeater list (a
/// RepeaterBook-style KML and/or a CHIRP CSV of the same export).
Future<void> addMapFile(BuildContext context, {NotebookState? notebooks, UserLayersState? userLayers}) async {
  final kind = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (notebooks != null)
            ListTile(
              key: const ValueKey('add-file-places'),
              minTileHeight: 56,
              leading: const Icon(Icons.place_outlined),
              title: const Text('Places'),
              subtitle: const Text('KML, KMZ, GPX or GeoJSON. They become a Places notebook.'),
              onTap: () => Navigator.pop(ctx, 'places'),
            ),
          if (userLayers != null)
            ListTile(
              key: const ValueKey('add-file-repeaters'),
              minTileHeight: 56,
              leading: const Icon(Icons.cell_tower),
              title: const Text('Repeater list'),
              subtitle: const Text('A RepeaterBook KML, a CHIRP CSV, or both from the same export.'),
              onTap: () => Navigator.pop(ctx, 'repeaters'),
            ),
        ],
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  if (kind == 'places') {
    await importPlacesInto(context, notebooks!, now: DateTime.now);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    final r = await withPickedFiles((paths) => userLayers!.importRepeaters(paths));
    if (r == null) return;
    final n = (r['repeaters'] as num?)?.toInt() ?? 0;
    final noPos = (r['without_position'] as num?)?.toInt() ?? 0;
    messenger.showSnackBar(SnackBar(content: Text('${n == 1 ? '1 repeater' : '$n repeaters'} added${noPos > 0 ? ', $noPos without a position (not on the map)' : ''}')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not read the file: ${e is CacheSearchException ? e.message : e}')));
  }
}

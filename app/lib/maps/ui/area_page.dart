import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import '../../layout/adaptive.dart';
import '../../screens/settings/widgets.dart';
import '../../theme.dart';
import '../geo.dart';
import '../layers/layer_def.dart';
import '../maps_state.dart';
import 'catalogue_screen.dart' show areaDl, areaDlActions, askDeleteArea, updateArea;
import 'format.dart';
import 'place_map.dart';

/// Draws a downloaded area's small map, fitted to [extent].
typedef AreaMapBuilder = Widget Function(BuildContext context, GeoBounds extent);

/// What tests draw in place of the platform map on an area's page; null draws the real one ([PlaceMap] with the area's extent).
@visibleForTesting
AreaMapBuilder? areaMapForTests;

/// Opens the page of downloaded map area [id]: beside the list on a tablet, else as a page of its own (as a region's page opens).
Future<void> openAreaPage(BuildContext context, MapsState maps, String id) =>
    openDetail(context, key: 'area-$id', builder: (_) => AreaPage(maps: maps, id: id));

/// One downloaded map area (a map download from the layers screen, before regions), laid out as a region's page: a small map of
/// its extent, its size, its Map part with the date it was fetched (or where its download stands, with its fix), the map layers it
/// holds, Show on map, Update and Delete. An area holds the tiles of one layer only: directions, places and off-road come with a
/// region, so they are never listed here.
class AreaPage extends StatelessWidget {
  const AreaPage({super.key, required this.maps, required this.id});

  final MapsState maps;
  final String id;

  DownloadedArea? _area() => maps.engine.allAreas.where((a) => a.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: maps,
      builder: (context, _) {
        final a = _area();
        if (a == null) {
          return Scaffold(
            appBar: AppBar(leading: paneShowButton(context), title: const Text('Area')),
            body: const Padding(padding: EdgeInsets.all(18), child: NoteText('This area is no longer on this device.')),
          );
        }
        final k = context.t;
        final done = a.phase == AreaPhase.done;
        final layers = _layersOf(a);
        return Scaffold(
          appBar: AppBar(
            leading: paneShowButton(context),
            title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(formatBytes(a.bytes), key: const ValueKey('area-size'), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(builder: (context, cts) => ListView(
              padding: ContentWidth.padFor(cts.maxWidth, min: 12).copyWith(top: 8, bottom: 24),
              children: [
                // The area on a small map, the saved place page's; it is a view (the page's scroll keeps the drags) and a tap shows
                // the area on the Maps tab.
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    key: const ValueKey('area-map'),
                    height: (MediaQuery.sizeOf(context).height * 0.35).clamp(120.0, 200.0),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        (areaMapForTests ?? _placeMap)(context, a.bounds),
                        Semantics(
                          button: true,
                          label: 'Show on map',
                          child: GestureDetector(
                            key: const ValueKey('area-map-open'),
                            behavior: HitTestBehavior.translucent,
                            onTap: () => maps.showAreaOnMap(a.bounds),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SettingsGroup(
                  rows: [
                    if (done)
                      SettingsRow(
                        key: const ValueKey('part-map'),
                        title: 'Map',
                        statusLines: 2,
                        status: joinParts([
                          [Part('Ready · ${formatBytes(a.bytes)}')],
                          if (a.fetchedAt != null) [Part(formatDate(a.fetchedAt!))],
                          // A done area can carry a note from its last update (the layers screen shows it the same way).
                          if (a.error != null) [Part(a.error!, Tone.warn)],
                        ]),
                        trailing: Icon(Icons.check_circle, color: k.ok, semanticLabel: 'Ready'),
                      )
                    else
                      _MapPartRow(key: const ValueKey('part-map'), maps: maps, area: a),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('area-show-on-map'),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Show on map'),
                      onPressed: () => maps.showAreaOnMap(a.bounds),
                    ),
                    // While it downloads or stopped, its fix is on the Map row (Pause, Resume, Remove).
                    if (done)
                      OutlinedButton.icon(
                        key: const ValueKey('area-update'),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Update'),
                        onPressed: () => updateArea(context, maps.engine, a),
                      ),
                  ],
                ),
                if (layers.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  SettingsGroup(
                    label: 'Map layers in this area',
                    rows: [
                      // Each opens the layer sheet at its switch on the Maps tab, as its card on the layers screen does.
                      for (final l in layers)
                        SettingsRow(
                          key: ValueKey('area-layer-${l.id ?? l.title}'),
                          title: l.title,
                          onTap: l.id == null ? null : () => maps.showLayerOnMap(l.id!),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 22),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const ValueKey('area-delete'),
                    style: OutlinedButton.styleFrom(foregroundColor: k.emergency, side: BorderSide(color: k.emergency)),
                    icon: const Icon(Icons.delete_outline),
                    label: Text('Delete ${a.label}'),
                    onPressed: () async {
                      if (await askDeleteArea(context, maps.engine, a) && context.mounted) Navigator.of(context).maybePop();
                    },
                  ),
                ),
              ],
            )),
          ),
        );
      },
    );
  }

  Widget _placeMap(BuildContext context, GeoBounds extent) => PlaceMap(maps: maps, themeId: _themeOf(context), pin: null, extent: extent);

  /// The layers drawn from this area's tiles, by the catalogue's cards (as a region's page lists its map layers): hillshade and
  /// contour lines from an elevation area, the base map from a base map area. The layer itself when no card draws from it.
  List<({String? id, String title})> _layersOf(DownloadedArea a) {
    final engine = maps.engine;
    final kept = engine.downloadLayerOf(a.layerId);
    final out = <({String? id, String title})>[
      for (final c in maps.catalogueLayers)
        if (engine.downloadLayerOf(maps.downloadDefFor(c, a.bounds).id) == kept) (id: c.id, title: c.title),
    ];
    if (out.isNotEmpty) return out;
    final own = engine.layer(a.layerId);
    return own == null ? const [] : [(id: null, title: own.title)];
  }
}

/// The theme the page is drawn in, for the small map's colours.
CacheThemeId _themeOf(BuildContext context) {
  final k = context.t;
  for (final e in cacheTokens.entries) {
    if (identical(e.value, k) || (e.value.surface == k.surface && e.value.text == k.text)) return e.key;
  }
  return CacheThemeId.dark;
}

/// The area's Map part while it downloads, is paused or stopped: the download pattern (its line, bar, and Pause, Resume or Remove),
/// as a region's part that is not complete.
class _MapPartRow extends StatelessWidget {
  const _MapPartRow({super.key, required this.maps, required this.area});

  final MapsState maps;
  final DownloadedArea area;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = areaDl(area);
    final a = areaDlActions(context, maps.engine, area);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Map', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                DlStatus(state: s, actions: a, keyBase: 'part-map'),
              ],
            ),
          ),
          dlControl(context, s, a, keyBase: 'part-map'),
        ],
      ),
    );
  }
}

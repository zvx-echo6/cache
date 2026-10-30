import 'package:flutter/material.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/ui/catalogue_screen.dart';
import '../../maps/ui/format.dart';
import '../../regions/regions_state.dart';
import '../../regions/ui/region_page.dart';
import '../../regions/ui/regions_screen.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Maps: one line per region on the phone (map downloads from before regions are part of their region, or one line per
/// area), the layers, and (Advanced) the layer definitions with their source addresses. Without the region engine, the map areas
/// list on their own.
class MapsPage extends StatefulWidget {
  const MapsPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<MapsPage> createState() => _MapsPageState();
}

class _MapsPageState extends State<MapsPage> {
  RegionsState? get _regions => widget.deps.hub.regions;

  @override
  void initState() {
    super.initState();
    _regions?.addListener(_note);
    WidgetsBinding.instance.addPostFrameCallback((_) => _note());
  }

  @override
  void dispose() {
    _regions?.removeListener(_note);
    super.dispose();
  }

  /// The one-time note after old map downloads were tidied up.
  void _note() {
    final r = _regions;
    final n = r?.tidyNote;
    if (r == null || n == null || !mounted) return;
    r.tidyNote = null;
    say(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final maps = widget.deps.maps;
    final regions = _regions;
    void openLayers() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CatalogueScreen(maps: maps)));
    void openRegions({int tab = 0}) => regions == null
        ? openLayers()
        : Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionsScreen(regions: regions, initialTab: tab)));
    return ListenableBuilder(
      listenable: Listenable.merge([maps, ?regions]),
      builder: (context, _) {
        final layers = maps.catalogueLayers;
        final on = layers.where((l) => maps.isOn(l.id)).length;
        final local = regions?.local ?? const <LocalRegion>[];
        final areas = regions == null ? maps.engine.allAreas : const <DownloadedArea>[];
        return SettingsPage(
          title: 'Maps',
          children: [
            SettingsGroup(
              label: 'Regions',
              rows: [
                if (regions != null) ...[
                  for (final l in local) RegionRow(regions: regions, region: l),
                  SettingsRow(
                    key: const ValueKey('regions-row'),
                    icon: Icons.add_location_alt_outlined,
                    title: local.isEmpty ? 'Download a region' : 'Download another region',
                    status: const [Part('Directions, map, places and off-road for an area')],
                    onTap: openRegions,
                  ),
                ] else ...[
                  if (areas.isEmpty)
                    SettingsRow(title: 'Nothing downloaded', status: const [Part('Download an area so the map works without a connection')], onTap: openLayers),
                  for (final a in areas)
                    SettingsRow(
                      key: ValueKey('area-${a.id}'),
                      title: a.label,
                      status: switch (a.phase) {
                        AreaPhase.running => [Part('Downloading ${(a.fraction * 100).toStringAsFixed(0)}%')],
                        AreaPhase.failed => [Part(a.error ?? 'Stopped', Tone.danger)],
                        AreaPhase.done => [Part('${formatBytes(a.bytes)}${a.fetchedAt == null ? '' : ' · ${formatDate(a.fetchedAt!)}'}')],
                      },
                      onTap: openLayers,
                    ),
                ],
              ],
            ),
            if (local.isNotEmpty) const NoteText('Tap a region to open it. Press and hold for Carry on, Check for update and Delete.'),
            SettingsGroup(
              label: 'Layers',
              rows: [
                SettingsRow(
                  icon: Icons.layers_outlined,
                  title: 'Layers',
                  status: [
                    Part(
                      maps.engine.problem ??
                          '${layers.length} ${layers.length == 1 ? 'layer' : 'layers'} · $on on the map · ${formatBytes(maps.engine.storageTotal)} on this phone',
                      maps.engine.problem == null ? Tone.normal : Tone.warn,
                    ),
                  ],
                  onTap: openLayers,
                ),
                SettingsRow(
                  key: const ValueKey('maps-advanced'),
                  icon: Icons.tune,
                  title: 'Advanced',
                  status: const [Part('Layer definitions and source addresses')],
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ListenableBuilder(
                        listenable: maps,
                        builder: (context, _) => SettingsPage(title: 'Advanced', children: [LayerDefinitions(maps: maps)]),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

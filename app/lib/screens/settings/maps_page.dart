import 'package:flutter/material.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/ui/catalogue_screen.dart';
import '../../maps/ui/format.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Maps: what is downloaded, the layers, and (Advanced) the layer definitions with their source addresses.
class MapsPage extends StatelessWidget {
  const MapsPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final maps = deps.maps;
    void openLayers() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CatalogueScreen(maps: maps)));
    return ListenableBuilder(
      listenable: maps,
      builder: (context, _) {
        final held = <(DownloadedArea, LayerDef)>[];
        for (final l in maps.catalogueLayers) {
          for (final a in maps.areasOfCard(l)) {
            held.add((a, l));
          }
        }
        final layers = maps.catalogueLayers;
        final on = layers.where((l) => maps.isOn(l.id)).length;
        return SettingsPage(
          title: 'Maps',
          children: [
            SettingsGroup(
              label: 'Downloaded',
              rows: [
                if (held.isEmpty)
                  SettingsRow(
                    title: 'Nothing downloaded',
                    status: const [Part('Download a region or an area so the map works without a connection')],
                    onTap: openLayers,
                  ),
                for (final (a, l) in held)
                  SettingsRow(
                    key: ValueKey('area-${a.id}'),
                    title: a.label,
                    status: switch (a.phase) {
                      AreaPhase.running => [Part('${l.title} · Downloading ${(a.fraction * 100).toStringAsFixed(0)}%')],
                      AreaPhase.failed => [Part('${l.title} · ${a.error ?? 'Stopped'}', Tone.danger)],
                      AreaPhase.done => [Part('${l.title} · ${formatBytes(a.bytes)}${a.fetchedAt == null ? '' : ' · ${formatDate(a.fetchedAt!)}'}')],
                    },
                    onTap: openLayers,
                  ),
              ],
            ),
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
              ],
            ),
            AdvancedRow(
              status: 'Layer definitions and source addresses',
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
        );
      },
    );
  }
}

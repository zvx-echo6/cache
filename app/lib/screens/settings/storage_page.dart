import 'package:flutter/material.dart';

import '../../settings/storage_usage.dart';
import '../../theme.dart';
import '../../video/format.dart';
import '../models_screen.dart';
import '../sources_screen.dart';
import '../videos/library_screen.dart';
import '../../maps/ui/catalogue_screen.dart' as layers;
import 'deps.dart';
import 'widgets.dart';

/// Settings > Storage and data: what is using space (each kind opening its own list to delete from), and the two mobile data switches.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  SettingsDeps get d => widget.deps;
  StorageUsage get u => d.hub.storage;

  @override
  void initState() {
    super.initState();
    u.measure();
  }

  /// A list was opened to delete from: measure again when it closes.
  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) u.measure();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = d.hub.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([u, s]),
      builder: (context, _) {
        final used = u.usedBytes;
        final free = u.freeBytes;
        final total = used + (free ?? 0);
        final colors = [k.accent, k.ok, k.warning, k.secondary];
        final sizes = [u.libraryBytes, u.mapsBytes, u.modelsBytes, u.videosBytes];
        String size(int b) => u.measured ? formatBytes(b) : 'Measuring…';
        return SettingsPage(
          title: 'Storage and data',
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(u.measured ? '${formatBytes(used)} used' : 'Measuring…', key: const ValueKey('used'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: k.text)),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(free == null ? 'Free space unknown' : '${formatBytes(free)} free', key: const ValueKey('free'), textAlign: TextAlign.end, style: TextStyle(fontSize: 14, color: k.secondary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Container(
                      height: 10,
                      color: k.secondary.withValues(alpha: 0.3),
                      child: Row(
                        children: [
                          for (var i = 0; i < 4; i++)
                            if (total > 0 && sizes[i] > 0)
                              Flexible(
                                flex: (sizes[i] * 10000 / total).round().clamp(1, 10000),
                                child: Container(margin: const EdgeInsets.only(right: 2), color: colors[i]),
                              ),
                          Spacer(flex: total > 0 ? (free ?? 0) * 10000 ~/ total : 1),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SettingsGroup(
              rows: [
                _kind('Library', colors[0], size(sizes[0]), () => _open(SourcesScreen(sources: d.sources))),
                _kind('Maps', colors[1], size(sizes[1]), () => _open(layers.CatalogueScreen(maps: d.maps))),
                _kind('Assistant models', colors[2], size(sizes[2]), () => _open(ModelsScreen(app: d.app))),
                _kind('Videos', colors[3], size(sizes[3]), () => _open(LibraryScreen(video: d.video))),
              ],
            ),
            SettingsGroup(
              label: 'Mobile data',
              rows: [
                SwitchRow(
                  title: 'Use mobile data for updates',
                  status: const [Part('Weather, alerts and fires (small)')],
                  value: s.mobileForUpdates,
                  onChanged: s.setMobileForUpdates,
                ),
                SwitchRow(
                  title: 'Use mobile data for downloads',
                  status: const [Part('Maps, library and videos (large)')],
                  value: s.mobileForDownloads,
                  onChanged: s.setMobileForDownloads,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _kind(String title, Color color, String size, VoidCallback onTap) => SettingsRow(
    key: ValueKey('kind-$title'),
    leading: Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
    title: title,
    status: [Part(size)],
    onTap: onTap,
  );
}


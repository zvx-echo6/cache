import 'package:flutter/material.dart';

import '../../settings/data_kinds.dart';
import '../../settings/storage_usage.dart';
import '../../theme.dart';
import '../../video/format.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Storage: what Cache uses and what is free, Clean up, the mobile-data switch for big downloads, the space always kept
/// for the phone (information, not a setting), and one row per kind that opens a list to remove items from.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  SettingsDeps get d => widget.deps;
  StorageUsage get u => d.hub.storage;
  bool _cleaning = false;

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

  Future<void> _cleanUp() async {
    if (u.busy()) {
      say(context, 'Wait for the downloads to finish, then clean up.');
      return;
    }
    setState(() => _cleaning = true);
    final freed = await u.cleanUp();
    if (!mounted) return;
    setState(() => _cleaning = false);
    say(context, freed > 0 ? 'Freed ${formatBytes(freed)}' : 'Nothing to clean up');
  }

  /// One colour per kind for the bar; the rows carry the names, so the colour is never the only sign.
  List<Color> _colors(CacheTokens k) => [k.accent, k.ok, k.warning, k.primary, k.secondary];

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = d.hub.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([u, s]),
      builder: (context, _) {
        final kinds = u.kinds;
        final colors = _colors(k);
        final free = u.freeBytes;
        final clean = u.cleanupBytes;
        return SettingsPage(
          title: 'Storage',
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Bar(sizes: [for (final kind in kinds) u.bytesOf(kind.id)], colors: colors, free: free ?? 0),
                const SizedBox(height: 6),
                Text(
                  [
                    u.measured ? '${formatBytes(u.usedBytes)} used by Cache' : 'Measuring…',
                    free == null ? 'free space unknown' : '${formatBytes(free)} free on the phone',
                  ].join(' · '),
                  key: const ValueKey('storage-line'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: k.secondary),
                ),
              ],
            ),
            SettingsGroup(
              rows: [
                SettingsRow(
                  key: const ValueKey('clean-up'),
                  icon: Icons.cleaning_services_outlined,
                  title: clean > 0 ? 'Clean up · ${formatBytes(clean)}' : 'Clean up',
                  status: [Part(clean > 0 ? 'Unfinished downloads and temporary files' : 'Nothing to clean up')],
                  trailing: _cleaning
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : RowButton(label: 'Clean up', onPressed: clean > 0 ? _cleanUp : null),
                ),
                SwitchRow(
                  title: 'Mobile data downloads',
                  status: [Part(s.mobileForDownloads ? 'On: big downloads use mobile data too' : 'Off: big downloads wait for Wi-Fi')],
                  value: s.mobileForDownloads,
                  onChanged: s.setMobileForDownloads,
                ),
                SettingsRow(
                  key: const ValueKey('kept-free'),
                  icon: Icons.phone_android,
                  title: 'Kept free for the phone',
                  status: const [Part('10% of storage, 5 to 20 GB')],
                  trailing: Text(formatBytes(u.reserveBytes), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              ],
            ),
            const NoteText('Weather and alerts always update, on any connection.'),
            SettingsGroup(
              rows: [
                for (var i = 0; i < kinds.length; i++) _kind(kinds[i], colors[i % colors.length]),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _kind(DataKind kind, Color color) {
    final k = context.t;
    final n = kind.count?.call();
    final size = u.measured ? formatBytes(u.bytesOf(kind.id)) : 'Measuring…';
    final list = kind.list;
    return SettingsRow(
      key: ValueKey('kind-${kind.id}'),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(kind.icon, size: 22, color: k.secondary),
          Positioned(right: -3, bottom: -3, child: Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
        ],
      ),
      title: kind.label,
      status: [Part(n == null ? size : '$n · $size')],
      onTap: list == null ? null : () => _open(list()),
    );
  }
}

/// The usage bar: each kind in its colour, then the free space.
class _Bar extends StatelessWidget {
  const _Bar({required this.sizes, required this.colors, required this.free});

  final List<int> sizes;
  final List<Color> colors;
  final int free;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final total = sizes.fold<int>(0, (a, b) => a + b) + free;
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Container(
        height: 10,
        color: k.secondary.withValues(alpha: 0.3),
        child: Row(
          children: [
            for (var i = 0; i < sizes.length; i++)
              if (total > 0 && sizes[i] > 0)
                Flexible(
                  flex: (sizes[i] * 10000 / total).round().clamp(1, 10000),
                  child: Container(margin: const EdgeInsets.only(right: 2), color: colors[i % colors.length]),
                ),
            Spacer(flex: total > 0 ? (free * 10000 ~/ total).clamp(1, 10000) : 1),
          ],
        ),
      ),
    );
  }
}

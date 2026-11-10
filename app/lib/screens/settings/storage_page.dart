import 'package:flutter/material.dart';

import '../../desktop/desktop.dart';
import '../../desktop/fact_table.dart';
import '../../linux_ui.dart';
import '../../platform/app_log.dart';
import '../../platform/app_log_io.dart' show appLogSize, shareAppLog;
import '../../settings/app_settings.dart';
import '../../settings/data_kinds.dart';
import '../../settings/storage_usage.dart';
import '../../theme.dart';
import '../../share/share_fallback.dart' show kDownloadStarted;
import '../../video/format.dart';
import '../../weather/catalogue.dart' show isAllowedAddress;
import '../../weather/weather_state.dart';
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
                    free == null ? 'free space unknown' : '${formatBytes(free)} free on ${linuxUi ? 'the server' : 'this device'}',
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
                  status: [Part(clean > 0 ? 'Unfinished downloads, damaged files and temporary files' : 'Nothing to clean up')],
                  trailing: _cleaning
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : RowButton(label: 'Clean up', onPressed: clean > 0 ? _cleanUp : null),
                ),
                if (!linuxUi)
                  SwitchRow(
                  title: 'Mobile data downloads',
                  status: [Part(s.mobileForDownloads ? 'On: big downloads use mobile data too' : 'Off: big downloads wait for Wi-Fi')],
                  value: s.mobileForDownloads,
                  onChanged: s.setMobileForDownloads,
                ),
                SettingsRow(
                  key: const ValueKey('kept-free'),
                  icon: linuxUi ? Icons.dns_outlined : Icons.phone_android,
                  title: linuxUi ? 'Kept free on the server' : 'Kept free for the device',
                  status: const [Part('10% of storage, 5 to 20 GB')],
                  trailing: Text(formatBytes(u.reserveBytes), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              ],
            ),
            if (!linuxUi) const NoteText('Weather and alerts always update, on any connection.'),
            // The Linux desktop shows the kinds as a table; every other window keeps the rows.
            if (isLinuxDesktop(context))
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const GroupLabel('What Cache stores'),
                  FactTable(
                    headers: const ['Kind', 'Items', 'Size'],
                    rows: [for (var i = 0; i < kinds.length; i++) _factRow(kinds[i], colors[i % colors.length])],
                  ),
                ],
              )
            else
              SettingsGroup(
                rows: [
                  for (var i = 0; i < kinds.length; i++) _kind(kinds[i], colors[i % colors.length]),
                ],
              ),
            AdvancedRow(
              key: const ValueKey('storage-advanced'),
              status: linuxUi ? 'Log: ${logLevelTitle(appLog.level)}' : 'Background indexing: ${s.indexingNormal ? 'Normal' : 'Gentle'} · Log: ${logLevelTitle(appLog.level)}',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IndexingSpeedPage(settings: s, weather: d.hub.weather))),
            ),
          ],
        );
      },
    );
  }

  FactRow _factRow(DataKind kind, Color color) {
    final k = context.t;
    final n = kind.count?.call();
    final list = kind.list;
    return FactRow(
      key: ValueKey('kind-${kind.id}'),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(kind.icon, size: 22, color: k.secondary),
          Positioned(right: -3, bottom: -3, child: Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
        ],
      ),
      label: kind.label,
      items: n?.toString(),
      size: u.measured ? formatBytes(u.bytesOf(kind.id)) : 'Measuring…',
      onTap: list == null ? null : () => _open(list()),
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

/// Settings > Storage > Advanced: how fast search indexes are made in the background (either way the work eases off when the
/// device warms up, the battery is low or the person is using Cache, and stops while the model writes an answer), and Cache's
/// own log: how much it keeps, Share log and Clear log; and the Source list address, where the list of weather and alerts sources
/// comes from.
class IndexingSpeedPage extends StatelessWidget {
  const IndexingSpeedPage({super.key, required this.settings, this.log, this.weather});

  final AppSettings settings;

  /// The log (the app's own by default).
  final AppLog? log;

  /// Weather and alerts, for the Source list address (left out where there is none).
  final WeatherState? weather;

  /// Asks for the address of the source list; Use the default puts the published one back. An address that is not https is refused.
  Future<void> _changeSourceList(BuildContext context, WeatherState w) async {
    final r = await showDialog<(String, String)>(context: context, builder: (_) => _SourceListDialog(initial: w.catalogueUrl));
    if (r == null) return;
    if (r.$1 == 'save') {
      final u = Uri.tryParse(r.$2);
      if (u == null || !isAllowedAddress(u)) {
        if (context.mounted) say(context, 'Enter an address that starts with https://');
        return;
      }
    }
    await w.setCatalogueUrl(r.$1 == 'default' ? null : r.$2);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final log = this.log ?? appLog;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, log, ?weather]),
      builder: (context, _) {
        Widget choice(String key, String title, String status, bool normal) => SettingsRow(
              key: ValueKey(key),
              title: title,
              status: [Part(status)],
              trailing: settings.indexingNormal == normal ? Icon(Icons.check, color: k.accent) : null,
              chevron: false,
              onTap: () => settings.setIndexingNormal(normal),
            );
        return SettingsPage(
          title: 'Advanced',
          children: [
            if (!linuxUi)
              SettingsGroup(
              label: 'Background indexing speed',
              rows: [
                choice('indexing-gentle', 'Gentle', 'Keeps the device cool and the battery longer', false),
                choice('indexing-normal', 'Normal', 'Finishes sooner, uses more battery', true),
              ],
            ),
            SettingsGroup(
              label: 'Log level',
              rows: [
                for (final l in LogLevel.values)
                  SettingsRow(
                    key: ValueKey('log-${l.name}'),
                    title: l == LogLevel.standard ? '${logLevelTitle(l)} (default)' : logLevelTitle(l),
                    status: [Part(logLevelDetail(l))],
                    trailing: log.level == l ? Icon(Icons.check, color: k.accent) : null,
                    chevron: false,
                    onTap: () => log.setLevel(l),
                  ),
              ],
            ),
            NoteText('The log stays on ${linuxUi ? 'the server' : 'this device'}. Nothing leaves it unless you tap Share log.'),
            SettingsGroup(
              rows: [
                SettingsRow(
                  key: const ValueKey('log-share'),
                  icon: Icons.ios_share,
                  title: 'Share log',
                  status: [Part(log.dir == null ? 'No log yet' : appLogSize())],
                  onTap: log.dir == null
                      ? null
                      : linuxUi
                      ? () => say(context, kDownloadStarted)
                      : () => shareAppLog(context),
                ),
                SettingsRow(
                  key: const ValueKey('log-clear'),
                  icon: Icons.delete_outline,
                  title: 'Clear log',
                  chevron: false,
                  onTap: log.dir == null
                      ? null
                      : linuxUi
                      ? () {
                          log.clear();
                          say(context, 'Log cleared');
                        }
                      : log.clear,
                ),
              ],
            ),
            if (weather case final w?) ...[
              SettingsGroup(
                label: 'Weather and alerts',
                rows: [
                  SettingsRow(
                    key: const ValueKey('source-list-address'),
                    icon: Icons.link,
                    title: 'Source list address',
                    status: [
                      Part(settings.catalogueUrl == null ? 'Default · ${w.catalogueUrl}' : w.catalogueUrl),
                      if (w.catalogueErrors[w.catalogueUrl] case final e?) Part(' · $e', Tone.warn),
                    ],
                    statusLines: 3,
                    onTap: () => _changeSourceList(context, w),
                  ),
                ],
              ),
              const NoteText('Where Cache gets the list of weather and alerts sources. Change it only if someone gives you another address.'),
            ],
          ],
        );
      },
    );
  }
}

/// Asks for the source list's address. Answers ("save", address) or ("default", ""), or nothing when cancelled.
class _SourceListDialog extends StatefulWidget {
  const _SourceListDialog({required this.initial});

  final String initial;

  @override
  State<_SourceListDialog> createState() => _SourceListDialogState();
}

class _SourceListDialogState extends State<_SourceListDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Source list address'),
    content: TextField(key: const ValueKey('source-list-field'), controller: _ctl, keyboardType: TextInputType.url, autocorrect: false, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(key: const ValueKey('source-list-default'), onPressed: () => Navigator.pop(context, ('default', '')), child: const Text('Use the default')),
      TextButton(key: const ValueKey('source-list-save'), onPressed: () => Navigator.pop(context, ('save', _ctl.text.trim())), child: const Text('Save')),
    ],
  );
}

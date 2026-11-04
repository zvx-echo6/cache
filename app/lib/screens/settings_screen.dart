import 'package:flutter/material.dart';

import '../models/model_downloads.dart' show ModelDownloads, modelDownloadLine;
import '../search/index_overview.dart';

import '../nav/units.dart';
import '../layout/adaptive.dart';
import '../theme.dart';
import '../settings/app_settings.dart';
import '../sharing/sharing_state.dart';
import '../version.dart';
import '../video/format.dart';
import 'settings/about_pages.dart';
import 'settings/appearance_page.dart';
import 'settings/assistant_page.dart';
import 'settings/deps.dart';
import 'settings/maps_page.dart';
import 'settings/notifications_page.dart';
import 'settings/sharing_page.dart';
import 'settings/storage_page.dart';
import 'settings/weather_page.dart';
import 'settings/widgets.dart';

/// Settings: eight rows, only things that can be changed, each with its state in one line and opening one page.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsDeps get d => widget.deps;
  late final Future<String> _version = installedVersion();

  @override
  void initState() {
    super.initState();
    d.hub.storage.readFree();
    d.hub.storage.measure();
  }

  /// Opens a Settings page: beside the list on a tablet (the two panes), else as a page of its own.
  Future<void> _open(BuildContext context, String key, Widget page) async {
    await openDetail(context, key: key, builder: (_) => page);
    // Something may have been added or deleted on the page: measure again so every size agrees.
    if (mounted) d.hub.storage.measure();
  }

  /// "Gemma 4 E2B · web search off".
  List<Part> _model() {
    final app = d.app;
    return joinParts([
      if (app.loading != null)
        const [Part('Loading…')]
      else if (app.active == null && modelDownloadLine() != null)
        [Part(modelDownloadLine()!)]
      else if (app.active == null)
        const [Part('Choose a model', Tone.warn)]
      else
        [Part(app.displayName(app.active!))],
      [Part(d.hub.webSearch.active ? 'web search on' : 'web search off')],
    ]);
  }

  /// "Idaho Falls, Twin Falls · miles".
  List<Part> _maps() {
    if (d.maps.engine.problem != null) return const [Part('Not available', Tone.warn)];
    final names = [for (final r in d.hub.regions?.local ?? const []) r.name];
    final units = unitsForLocale(WidgetsBinding.instance.platformDispatcher.locale) == UnitSystem.imperial ? 'miles' : 'kilometres';
    return joinParts([
      [Part(names.isEmpty ? 'No regions yet' : names.join(', '))],
      [Part(units)],
    ]);
  }

  /// "4 sources · 2 places".
  List<Part> _weather() {
    final w = d.hub.weather;
    final on = w.enabledSources.length;
    if (on == 0) return const [Part('Nothing on')];
    final places = d.hub.settings.watchedPlaces.length;
    return joinParts([
      [Part(on == 1 ? '1 source' : '$on sources')],
      [Part(places == 1 ? '1 place' : '$places places')],
    ]);
  }

  /// "Serious alerts · quiet 10 PM–7 AM".
  List<Part> _notifications() {
    final s = d.hub.settings;
    return joinParts([
      [
        switch (s.popUpFor) {
          PopUpFor.serious => const Part('Serious alerts'),
          PopUpFor.all => const Part('All alerts'),
          PopUpFor.none => const Part('No pop-ups', Tone.warn),
        },
      ],
      if (s.quiet.on && s.popUpFor != PopUpFor.none) [Part('quiet ${formatMinutes(s.quiet.from)}–${formatMinutes(s.quiet.to)}')],
    ]);
  }

  /// "118 GB used · 103 GB free".
  List<Part> _storage() {
    final u = d.hub.storage;
    return joinParts([
      if (u.measured) [Part('${formatBytes(u.usedBytes)} used')],
      [Part(u.freeBytes == null ? 'Free space unknown' : '${formatBytes(u.freeBytes!)} free')],
    ]);
  }

  /// "Linked to iPhone".
  List<Part> _sharing(SharingState s) {
    if (!s.enabled) return const [Part('Off')];
    if (!s.running) return [Part(s.error ?? 'Starting…', s.error == null ? Tone.normal : Tone.warn)];
    final peers = s.peers;
    if (peers.isEmpty) return const [Part('Not linked yet')];
    if (peers.length == 1) return [Part('Linked to ${peers.single['name'] ?? 'one device'}')];
    return [Part('Linked to ${peers.length} devices')];
  }

  @override
  Widget build(BuildContext context) {
    // A tablet shows the pages beside the list, the first one chosen.
    return TwoPane(
      id: 'settings',
      listName: 'Settings',
      initialKey: 'settings-model',
      initial: (_) => AssistantPage(deps: d),
      list: Builder(builder: _list),
    );
  }

  Widget _list(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: [?paneHideButton(context)]),
      body: ListenableBuilder(
        listenable: Listenable.merge([d.app, d.maps, d.hub.changes, ?d.hub.regions, ?ModelDownloads.shared]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            SettingsGroup(
              rows: [
                SettingsRow(
                  key: const ValueKey('settings-model'),
                  icon: Icons.lightbulb_outline,
                  title: 'Cache model and web search',
                  status: _model(),
                  selected: isPaneSelected(context, 'settings-model'),
                  onTap: () => _open(context, 'settings-model', AssistantPage(deps: d)),
                ),
                SettingsRow(key: const ValueKey('settings-maps'), icon: Icons.map_outlined, title: 'Maps', status: _maps(), selected: isPaneSelected(context, 'settings-maps'),
                  onTap: () => _open(context, 'settings-maps', MapsPage(deps: d))),
                SettingsRow(
                  key: const ValueKey('settings-weather'),
                  icon: Icons.cloud_outlined,
                  title: 'Weather and alerts',
                  status: _weather(),
                  selected: isPaneSelected(context, 'settings-weather'),
                  onTap: () => _open(context, 'settings-weather', WeatherPage(deps: d)),
                ),
                SettingsRow(
                  key: const ValueKey('settings-notifications'),
                  icon: Icons.notifications_none,
                  title: 'Notifications',
                  status: _notifications(),
                  selected: isPaneSelected(context, 'settings-notifications'),
                  onTap: () => _open(context, 'settings-notifications', NotificationsPage(deps: d)),
                ),
                SettingsRow(
                  key: const ValueKey('settings-storage'),
                  icon: Icons.sd_storage_outlined,
                  title: 'Storage',
                  status: _storage(),
                  selected: isPaneSelected(context, 'settings-storage'),
                  onTap: () => _open(context, 'settings-storage', StoragePage(deps: d)),
                ),
                if (d.hub.sharing case final sharing?)
                  ListenableBuilder(
                    listenable: sharing,
                    builder: (context, _) => SettingsRow(
                      key: const ValueKey('settings-sharing'),
                      icon: Icons.sync_alt,
                      title: 'Sharing and sync',
                      status: _sharing(sharing),
                      selected: isPaneSelected(context, 'settings-sharing'),
                  onTap: () => _open(context, 'settings-sharing', SharingPage(sharing: sharing)),
                    ),
                  ),
                SettingsRow(
                  key: const ValueKey('settings-appearance'),
                  icon: Icons.contrast,
                  title: 'Appearance',
                  status: [Part(d.app.theme.label)],
                  selected: isPaneSelected(context, 'settings-appearance'),
                  onTap: () => _open(context, 'settings-appearance', AppearancePage(app: d.app)),
                ),
                FutureBuilder<String>(
                  future: _version,
                  initialData: kAppVersion,
                  builder: (context, snap) => SettingsRow(
                    key: const ValueKey('settings-credits'),
                    icon: Icons.info_outline,
                    title: 'Credits and licences',
                    status: [Part('${snap.data ?? kAppVersion} · $kAppLicenceShort')],
                    selected: isPaneSelected(context, 'settings-credits'),
                  onTap: () => _open(context, 'settings-credits', const AboutPage()),
                  ),
                ),
              ],
            ),
            // While search indexes are being made or sealed for sync: the same progress bar as at the top of the Library.
            if (d.hub.indexing case final indexing?)
              Padding(
                key: const ValueKey('index-status'),
                padding: const EdgeInsets.only(top: 12),
                child: IndexOverviewLine(scheduler: indexing),
              ),
          ],
        ),
      ),
    );
  }
}

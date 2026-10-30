import 'package:flutter/material.dart';

import '../nav/units.dart';
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

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    // Something may have been added or deleted on the page: measure again so every size agrees.
    if (mounted) d.hub.storage.measure();
  }

  /// "Gemma 4 E2B · web search off".
  List<Part> _model() {
    final app = d.app;
    return joinParts([
      if (app.loading != null)
        const [Part('Loading…')]
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
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([d.app, d.maps, d.hub.changes, ?d.hub.regions]),
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
                  onTap: () => _open(AssistantPage(deps: d)),
                ),
                SettingsRow(key: const ValueKey('settings-maps'), icon: Icons.map_outlined, title: 'Maps', status: _maps(), onTap: () => _open(MapsPage(deps: d))),
                SettingsRow(
                  key: const ValueKey('settings-weather'),
                  icon: Icons.cloud_outlined,
                  title: 'Weather and alerts',
                  status: _weather(),
                  onTap: () => _open(WeatherPage(deps: d)),
                ),
                SettingsRow(
                  key: const ValueKey('settings-notifications'),
                  icon: Icons.notifications_none,
                  title: 'Notifications',
                  status: _notifications(),
                  onTap: () => _open(NotificationsPage(deps: d)),
                ),
                SettingsRow(
                  key: const ValueKey('settings-storage'),
                  icon: Icons.sd_storage_outlined,
                  title: 'Storage',
                  status: _storage(),
                  onTap: () => _open(StoragePage(deps: d)),
                ),
                if (d.hub.sharing case final sharing?)
                  ListenableBuilder(
                    listenable: sharing,
                    builder: (context, _) => SettingsRow(
                      key: const ValueKey('settings-sharing'),
                      icon: Icons.sync_alt,
                      title: 'Sharing and sync',
                      status: _sharing(sharing),
                      onTap: () => _open(SharingPage(sharing: sharing)),
                    ),
                  ),
                SettingsRow(
                  key: const ValueKey('settings-appearance'),
                  icon: Icons.contrast,
                  title: 'Appearance',
                  status: [Part(d.app.theme.label)],
                  onTap: () => _open(AppearancePage(app: d.app)),
                ),
                FutureBuilder<String>(
                  future: _version,
                  initialData: kAppVersion,
                  builder: (context, snap) => SettingsRow(
                    key: const ValueKey('settings-credits'),
                    icon: Icons.info_outline,
                    title: 'Credits and licences',
                    status: [Part('${snap.data ?? kAppVersion} · $kAppLicenceShort')],
                    onTap: () => _open(const AboutPage()),
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

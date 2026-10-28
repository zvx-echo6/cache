import 'package:flutter/material.dart';

import '../maps/layers/layer_def.dart';
import '../sharing/sharing_state.dart';
import '../version.dart';
import '../theme.dart';
import '../video/format.dart';
import 'settings/about_pages.dart';
import 'settings/appearance_page.dart';
import 'settings/assistant_page.dart';
import 'settings/deps.dart';
import 'settings/library_page.dart';
import 'settings/maps_page.dart';
import 'settings/notifications_page.dart';
import 'settings/sharing_page.dart';
import 'settings/storage_page.dart';
import 'settings/videos_page.dart';
import 'settings/weather_page.dart';
import 'settings/widgets.dart';

/// Settings: ten rows in three groups, each saying its current state, each opening one page.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsDeps get d => widget.deps;

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

  List<Part> _assistant() {
    final app = d.app;
    final model = app.active == null ? 'No model' : app.displayName(app.active!);
    final Part state = app.loading != null
        ? const Part('Loading…')
        : app.active == null
        ? const Part('Choose a model', Tone.warn)
        : const Part('Ready', Tone.ok);
    return joinParts([
      if (app.active != null) [Part(model)],
      [state],
      [Part(d.hub.webSearch.active ? 'Web search on' : 'Web search off')],
    ]);
  }

  List<Part> _library() {
    final s = d.sources;
    if (s.unavailable != null && s.zims.isEmpty) return const [Part('Not available', Tone.warn)];
    if (s.zims.isEmpty) return const [Part('No sources yet')];
    final n = s.zims.length;
    // The same figure as Storage and data: the sources and their search indexes, measured on disk.
    final u = d.hub.storage;
    return [Part('$n ${n == 1 ? 'source' : 'sources'}${u.measured ? ' · ${formatBytes(u.libraryBytes)}' : ''}')];
  }

  List<Part> _maps() {
    final m = d.maps;
    if (m.engine.problem != null) return const [Part('Not available', Tone.warn)];
    final done = <String>{};
    var running = 0;
    for (final l in m.catalogueLayers) {
      for (final a in m.areasOfCard(l)) {
        if (a.phase == AreaPhase.done) done.add(a.label.split(' · ').first);
        if (a.phase == AreaPhase.running) running++;
      }
    }
    final String held;
    if (done.isEmpty) {
      held = running > 0 ? 'Downloading' : 'Nothing downloaded';
    } else if (done.length == 1 && done.first != 'This region') {
      held = '${done.first} downloaded';
    } else {
      held = '${done.length} ${done.length == 1 ? 'area' : 'areas'} downloaded';
    }
    final layers = m.catalogueLayers.length;
    return joinParts([
      [Part(held)],
      if (layers > 0) [Part('$layers ${layers == 1 ? 'layer' : 'layers'}')],
    ]);
  }

  List<Part> _weather() => [Part(d.hub.weather.settingsLine())];

  List<Part> _videos() {
    final v = d.video;
    if (v.unavailable != null) return const [Part('Not available', Tone.warn)];
    final String where = v.instances.isEmpty
        ? 'No instances'
        : v.instances.length == 1
        ? v.instances.first.host
        : '${v.instances.length} instances';
    return joinParts([
      [Part(where)],
      [Part('${v.saved.length} downloaded')],
    ]);
  }

  List<Part> _notifications() {
    final s = d.hub.settings;
    return joinParts([
      [Part(s.alertPopups ? 'Pop-ups on' : 'Pop-ups off')],
      [Part(s.quiet.on ? 'Quiet ${s.quiet.label}' : 'No quiet hours')],
    ]);
  }

  List<Part> _sharing(SharingState s) {
    if (!s.enabled) return const [Part('Off', Tone.quiet)];
    if (!s.running) return [Part(s.error ?? 'Starting…', s.error == null ? Tone.normal : Tone.warn)];
    final n = s.peers.length;
    final shared = s.shares.length;
    return [Part(n == 1 ? '1 linked device' : '$n linked devices'), Part(' · $shared shared')];
  }

  List<Part> _storage() {
    final u = d.hub.storage;
    final s = d.hub.settings;
    return joinParts([
      [Part(u.freeBytes == null ? 'Free space unknown' : '${formatBytes(u.freeBytes!)} free')],
      [Part(s.mobileForUpdates ? 'Updates on any connection' : 'Updates on Wi-Fi only')],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          d.app,
          d.sources,
          d.maps,
          d.video,
          d.hub.changes,
          d.chat.historyRevision,
        ]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            SettingsGroup(
              rows: [
                SettingsRow(icon: Icons.lightbulb_outline, title: 'Assistant', status: _assistant(), onTap: () => _open(AssistantPage(deps: d))),
                SettingsRow(icon: Icons.menu_book_outlined, title: 'Library', status: _library(), onTap: () => _open(LibraryPage(deps: d))),
                SettingsRow(icon: Icons.map_outlined, title: 'Maps', status: _maps(), onTap: () => _open(MapsPage(deps: d))),
                SettingsRow(
                  icon: Icons.cloud_outlined,
                  title: 'Weather and alerts',
                  status: _weather(),
                  onTap: () => _open(WeatherPage(deps: d)),
                ),
                SettingsRow(icon: Icons.smart_display_outlined, title: 'Videos', status: _videos(), onTap: () => _open(VideosPage(deps: d))),
              ],
            ),
            const SizedBox(height: 14),
            SettingsGroup(
              rows: [
                SettingsRow(icon: Icons.notifications_none, title: 'Notifications and location', status: _notifications(), onTap: () => _open(NotificationsPage(deps: d))),
                SettingsRow(icon: Icons.sd_storage_outlined, title: 'Storage and data', status: _storage(), onTap: () => _open(StoragePage(deps: d))),
                if (d.hub.sharing != null)
                  ListenableBuilder(
                    listenable: d.hub.sharing!,
                    builder: (context, _) => SettingsRow(
                      icon: Icons.share_outlined,
                      title: 'Sharing and sync',
                      status: _sharing(d.hub.sharing!),
                      onTap: () => _open(SharingPage(sharing: d.hub.sharing!)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            SettingsGroup(
              rows: [
                SettingsRow(icon: Icons.contrast, title: 'Appearance', status: [Part(d.app.theme.label)], onTap: () => _open(AppearancePage(app: d.app))),
                SettingsRow(icon: Icons.info_outline, title: 'About and credits', status: [Part('Version $kAppVersion · $kAppLicenceShort')], onTap: () => _open(const AboutPage())),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

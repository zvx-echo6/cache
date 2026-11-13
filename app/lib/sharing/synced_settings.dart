import '../app_state.dart';
import '../layout/layout_state.dart';
import '../maps/maps_state.dart';
import '../models/recommendations.dart';
import '../settings/app_settings.dart';
import '../settings/web_search_setup.dart';
import '../theme.dart';
import '../video/token_store.dart';
import '../weather/weather_state.dart';
import 'settings_sync.dart';

/// Every app setting that can go between linked devices, by group (What's included). Anything not here never goes: the device's
/// name, mobile data downloads, indexing speed, the space kept free, the log level, the Obsidian and Logseq connections and each
/// device's own permissions, and also the app lock, the source list address, a model the person declined, the map's camera, the
/// layer definitions switched in Advanced and each layer's opacity, each place's own alert rule, the Bookshelves look, the
/// video logins and what each device fetches or builds for itself.
List<SyncedSetting> appSyncedSettings({
  required AppState app,
  required LayoutState layout,
  required AppSettings settings,
  required MapsState maps,
  required WeatherState weather,
  Map<String, String> Function()? placeNames,
  List<ModelRecommendation> Function()? recommended,
}) {
  String count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';
  List<String> strings(Object? v) => [for (final x in (v is List ? v : const [])) if (x is String) x];
  return [
    // Appearance
    SyncedSetting(
      key: 'appearance.theme',
      group: SettingsGroupId.appearance,
      label: 'Theme',
      listenable: app,
      read: () => app.theme.name,
      write: (v) async {
        final t = CacheThemeId.values.where((x) => x.name == v).firstOrNull;
        if (t != null) await app.setTheme(t);
        return true;
      },
      shows: () => app.theme.label,
    ),
    SyncedSetting(
      key: 'appearance.module_icons',
      group: SettingsGroupId.appearance,
      label: 'Module icons',
      listenable: app,
      read: () => app.largeModuleIcons ? 'large' : 'small',
      write: (v) async {
        await app.setLargeModuleIcons(v == 'large');
        return true;
      },
      shows: () => app.largeModuleIcons ? 'Large' : 'Small',
    ),
    SyncedSetting(
      key: 'appearance.dark_pdf_pages',
      group: SettingsGroupId.appearance,
      label: 'Dark PDF pages',
      listenable: app,
      read: () => app.darkPdfPages,
      write: (v) async {
        await app.setDarkPdfPages(v == true);
        return true;
      },
      shows: () => app.darkPdfPages ? 'On' : 'Off',
    ),
    // Home screen
    SyncedSetting(
      key: 'home.bar',
      group: SettingsGroupId.home,
      label: 'Modules in the bar',
      listenable: layout,
      read: () => layout.pinnedNames,
      write: (v) async {
        layout.applyPinned(v);
        return true;
      },
      shows: () => [for (final m in layout.pinned) m.label].join(', '),
    ),
    SyncedSetting(
      key: 'home.blocks',
      group: SettingsGroupId.home,
      label: 'Home and its order',
      listenable: layout,
      read: () => layout.blocksJson,
      write: (v) async {
        layout.applyBlocks(v);
        return true;
      },
      shows: () => count(layout.visibleBlocks.length, 'block shown', 'blocks shown'),
    ),
    SyncedSetting(
      key: 'home.shortcuts',
      group: SettingsGroupId.home,
      label: 'Shortcuts',
      listenable: layout,
      read: () => layout.shortcutsJson,
      write: (v) async {
        layout.applyShortcuts(v);
        return true;
      },
      shows: () => count(layout.shortcuts.length, 'shortcut', 'shortcuts'),
    ),
    // Weather and alerts
    SyncedSetting(
      key: 'weather.sources_on',
      group: SettingsGroupId.weather,
      label: 'Sources on',
      listenable: settings,
      read: () => settings.liveSourcesOn.toList()..sort(),
      write: (v) async {
        settings.replaceLiveSourcesOn(strings(v));
        await weather.sourcesChanged();
        return true;
      },
      shows: () => count(weather.enabledSources.length, 'source on', 'sources on'),
    ),
    SyncedSetting(
      key: 'weather.watch_here',
      group: SettingsGroupId.weather,
      label: 'Your location',
      listenable: settings,
      read: () => settings.watchHere,
      write: (v) async {
        settings.setWatchHere(v == true);
        return true;
      },
      shows: () => settings.watchHere ? 'Watched' : 'Not watched',
    ),
    SyncedSetting(
      key: 'weather.watch_regions',
      group: SettingsGroupId.weather,
      label: 'Regions watched',
      listenable: settings,
      read: () => settings.watchedRegions.toList()..sort(),
      write: (v) async {
        settings.replaceWatched('region:', [for (final r in strings(v)) 'region:$r']);
        return true;
      },
      shows: () => count(settings.watchedRegions.length, 'region', 'regions'),
    ),
    SyncedSetting(
      key: 'weather.watch_places',
      group: SettingsGroupId.weather,
      label: 'Saved places watched',
      listenable: settings,
      read: () => settings.watchedSavedPlaces.toList()..sort(),
      write: (v) async {
        settings.replaceWatched('place:', [for (final k in strings(v)) 'place:$k']);
        return true;
      },
      // The names go with the change, so a place that has not arrived yet can be named.
      note: () {
        final names = placeNames?.call() ?? const {};
        return {for (final k in settings.watchedSavedPlaces) if (names[k] != null) k: names[k]};
      },
      shows: () => count(settings.watchedSavedPlaces.length, 'place', 'places'),
    ),
    SyncedSetting(
      key: 'weather.own_sources',
      group: SettingsGroupId.weather,
      label: 'Your own sources',
      listenable: weather,
      read: () => weather.ownSourcesJson,
      write: (v) async {
        await weather.replaceOwnSources(v);
        return true;
      },
      shows: () => weather.ownSources.isEmpty ? 'None' : [for (final c in weather.ownSources) c.title].join(', '),
    ),
    SyncedSetting(
      key: 'weather.source_links',
      group: SettingsGroupId.weather,
      label: 'Source lists added from a link',
      listenable: settings,
      read: () => settings.extraCatalogues,
      write: (v) async {
        settings.replaceCatalogues(strings(v));
        await weather.sourcesChanged();
        return true;
      },
      shows: () => settings.extraCatalogues.isEmpty ? 'None' : count(settings.extraCatalogues.length, 'list', 'lists'),
    ),
    // Notifications
    SyncedSetting(
      key: 'alerts.pop_up',
      group: SettingsGroupId.notifications,
      label: 'Which alerts pop up',
      listenable: settings,
      read: () => settings.popUpFor.name,
      write: (v) async {
        settings.setPopUpFor(PopUpFor.byName(v));
        return true;
      },
      shows: () => switch (settings.popUpFor) {
        PopUpFor.serious => 'Serious only',
        PopUpFor.all => 'All alerts',
        PopUpFor.none => 'None',
      },
    ),
    SyncedSetting(
      key: 'alerts.quiet_hours',
      group: SettingsGroupId.notifications,
      label: 'Quiet hours',
      listenable: settings,
      read: () => {'on': settings.quiet.on, 'from': settings.quiet.from, 'to': settings.quiet.to},
      write: (v) async {
        if (v is Map) {
          int at(Object? x, int d) => x is int ? x.clamp(0, 1439) : d;
          settings.setQuiet(QuietHours(on: v['on'] != false, from: at(v['from'], 22 * 60), to: at(v['to'], 6 * 60)));
        }
        return true;
      },
      shows: () => settings.quiet.on ? settings.quiet.label : 'Off',
    ),
    // Map layers
    SyncedSetting(
      key: 'maps.layers_on',
      group: SettingsGroupId.maps,
      label: 'Layers on',
      listenable: maps,
      read: () => maps.layersOn,
      write: (v) async {
        maps.setLayersOn(strings(v));
        return true;
      },
      shows: () => count(maps.layersOn.length, 'layer on', 'layers on'),
    ),
    // Ask
    SyncedSetting(
      key: 'ask.model',
      group: SettingsGroupId.ask,
      label: 'Model',
      listenable: app,
      read: () => app.chosenModelFile,
      // False while the file is not on this device: the page offers Download, and nothing downloads on its own.
      write: (v) => app.useModelFile(v is String ? v : null),
      note: () {
        final file = app.chosenModelFile;
        if (file == null) return null;
        final e = app.models.where((m) => m.fileName == file).firstOrNull;
        final r = (recommended?.call() ?? const <ModelRecommendation>[]).where((m) => m.file.split('/').last == file).firstOrNull;
        return {
          'name': e != null ? app.displayName(e) : (r?.name ?? file),
          if (r != null)
            'download': {'repo': r.repo, 'path': r.file, 'size': r.size, 'sha256': ?r.sha256, 'revision': r.revision, 'url': ?r.url?.toString()},
        };
      },
      shows: () {
        final file = app.chosenModelFile;
        if (file == null) return 'None chosen';
        final e = app.models.where((m) => m.fileName == file).firstOrNull;
        return e != null ? app.displayName(e) : file;
      },
    ),
    SyncedSetting(
      key: 'ask.web_search',
      group: SettingsGroupId.ask,
      label: 'Web search',
      listenable: settings,
      read: () => settings.webSearchOn,
      write: (v) async {
        settings.setWebSearchOn(v == true);
        return true;
      },
      shows: () => settings.webSearchOn ? 'On' : 'Off',
    ),
  ];
}

/// The keys saved on this device that can be sent to a linked device (each ticked on its own, all off at first): the web search
/// key and each live source's key, your own sources' too.
///
/// A reference to a key on the server (`keystore://...`, what a browser's store hands out) is never a key: it is not sent.
List<SyncedKey> appSyncedKeys({required WeatherState weather, required WebSearchSetup webSearch, required TokenStore secrets}) {
  Future<String?> real(String name) async {
    final v = await secrets.read(name);
    return v != null && v.startsWith('keystore://') ? null : v;
  }

  return [
    if (webSearch.hasKey) SyncedKey(name: WebSearchSetup.keyName, label: 'Kagi (web search)', read: () => real(WebSearchSetup.keyName)),
    for (final alias in weather.savedKeyAliases)
      SyncedKey(name: WeatherState.secretName(alias), label: _keyLabel(weather, alias), read: () => real(WeatherState.secretName(alias))),
  ];
}

String _keyLabel(WeatherState weather, String alias) {
  final users = weather.sourcesUsingKey(alias);
  if (users.isEmpty) return alias;
  final c = users.first;
  if (weather.isOwn(c)) return 'Your own: ${c.title}';
  return c.provider.isEmpty ? c.title : c.provider;
}

/// Keeps a key a linked device sent, where this app keeps that key, and uses it at once. False for a name this app does not
/// keep (nothing is written).
Future<bool> keepSyncedKey(String name, String value, {required WeatherState weather, required WebSearchSetup webSearch}) async {
  if (value.isEmpty) return false;
  if (name == WebSearchSetup.keyName) {
    await webSearch.keepKey(value);
    return true;
  }
  const prefix = 'live.key.';
  if (name.startsWith(prefix) && name.length > prefix.length && name == WeatherState.secretName(name.substring(prefix.length))) {
    await weather.keepKey(name.substring(prefix.length), value);
    return true;
  }
  return false;
}

/// Keeps the names of the saved places, for the watched places' names that go with a change. Read again when the watched
/// places change.
class PlaceNameCache {
  PlaceNameCache(this.weather, this.settings) {
    settings.addListener(_onSettings);
    _onSettings();
  }

  final WeatherState weather;
  final AppSettings settings;
  Map<String, String> names = const {};
  String _watched = '';

  void _onSettings() {
    final now = (settings.watchedSavedPlaces.toList()..sort()).join('|');
    if (now == _watched) return;
    _watched = now;
    weather
        .placeChoices()
        .then((list) => names = {...names, for (final p in list) if (p.id.startsWith('place:')) p.id.substring(6): p.name})
        .catchError((Object _) => names);
  }

  void dispose() => settings.removeListener(_onSettings);
}

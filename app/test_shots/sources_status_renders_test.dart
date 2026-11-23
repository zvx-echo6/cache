// Pictures of the REAL Settings > Weather and alerts page with its source states (owner review renders). Sample catalogue, fake core.
// flutter test test_shots/sources_status_renders_test.dart --update-goldens  (pictures in test_shots/sources_status/)

import 'package:cache/layout/adaptive.dart' show TwoPane, isPaneSelected;
import 'package:cache/linux_ui.dart' show debugLinuxUi;
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/screens/settings/widgets.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/places.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import '../test/support/weather_fakes.dart';
import 'shot_kit.dart';

const _out = 'sources_status';

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<SettingsRig> _rig(WidgetTester tester) async {
  final r = await SettingsRig.create(tester);
  r.regionList = [const WatchRegion(name: 'Idaho', lat: 44.07, lon: -114.74)];
  r.liveCore.saved = const [
    SavedPlaceRecord(key: 'home', name: 'Home', lat: 43.49, lon: -112.03, label: 'Idaho Falls'),
    SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.22, lon: -114.93, label: 'Stanley'),
  ];
  Map<String, dynamic> e(String id, String cat, String title, String gives, String provider, {String? key, bool? featured}) =>
      entry(id, cat, title, provider: provider, keyAlias: key, featured: featured)..['description'] = gives;
  r.web.serve('https://data.cached.info/connectors/', buildCatalogue(connectors: [
    e('weather', 'weather', 'Forecast', 'Temperature, wind and rain for your places', 'Open-Meteo'),
    e('nws-alerts-point', 'alerts', 'Weather warnings', 'Warnings for storms, floods and heat', 'NWS'),
    e('alerts', 'emergency', 'Emergency alerts', 'Alerts from emergency services', 'NWS'),
    e('wfigs-incidents-near', 'fire', 'Wildfires', 'Wildfires near your place', 'NIFC WFIGS'),
    e('firms-viirs-near', 'fire', 'Fire hotspots (satellite)', 'Satellite fire detections near your place', 'NASA FIRMS'),
    e('idaho511-events', 'roads', 'Road events', 'Closures and crashes on Idaho roads', 'Idaho 511', key: 'idaho511', featured: true),
    e('usgs-quakes-near', 'earthquakes', 'Earthquakes', 'Recent earthquakes near your place', 'USGS'),
    e('traffic-flow', 'traffic', 'Traffic flow', 'Speeds and slowdowns on main roads', 'TomTom'),
    e('swpc-kp', 'space-weather', 'Space weather', 'Kp index', 'NOAA SWPC', featured: false),
    e('avalanche-forecast-zones', 'avalanche', 'Avalanche danger', 'Avalanche danger near your place', 'avalanche.org', featured: false),
  ]));
  await tester.runAsync(() async {
    await r.weather.refreshCatalogues();
    await r.weather.placeChoices();
    for (final id in ['here', 'region:Idaho', 'place:home', 'place:cabin']) {
      r.settings.setWatched(id, true);
    }
  });
  return r;
}

/// [calm]: every source works. Otherwise Road events has no key, Earthquakes does not answer (its saved copy is 3 hours old) and
/// Traffic flow is off.
Future<void> _scene(WidgetTester tester, SettingsRig r, {required bool calm}) async {
  await tester.runAsync(() async {
    final w = r.weather;
    final all = ['weather', 'nws-alerts-point', 'alerts', 'wfigs-incidents-near', 'firms-viirs-near', 'usgs-quakes-near', 'traffic-flow'];
    r.liveCore.fetchErrors.clear();
    r.liveCore.stored.remove('usgs-quakes-near');
    if (calm) await w.saveKey(w.sourceById('idaho511-events')!, 'k');
    r.settings.setLiveSourcesOn([...all, 'idaho511-events'], true);
    if (!calm) r.settings.setLiveSourcesOn(['traffic-flow'], false);
    await w.updateNow(force: true);
    if (!calm) {
      r.clock = r.clock.add(const Duration(hours: 3));
      r.liveCore.stored['usgs-quakes-near'] = {'age': '3 hours old', 'age_seconds': 10800, 'fetched_at': '2026-10-26T09:00:00-06:00', 'expired': true};
      r.liveCore.fetchErrors['usgs-quakes-near'] = const CacheSearchException('fetch_failed', 'Io: timed out reading response');
      await w.updateNow(force: true);
    }
    r.clock = r.clock.add(const Duration(minutes: 12));
  });
}

Future<void> _show(WidgetTester tester, Widget page, Size size, {CacheThemeId theme = CacheThemeId.light, bool desktop = false}) async {
  phone(tester, size: size, ratio: desktop ? 1 : 2);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: desktop ? EdgeInsets.zero : null, desktop: desktop));
  await _settle(tester);
}

Widget _desktop(SettingsRig r) {
  final n = r.deps.hub.weather.sourceCounts;
  Widget list(BuildContext context) {
    Widget row(String key, IconData icon, String title, String status) =>
        SettingsRow(key: ValueKey(key), icon: icon, title: title, status: [Part(status)], selected: isPaneSelected(context, key), onTap: () {});
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          SettingsGroup(
            rows: [
              row('settings-model', Icons.lightbulb_outline, 'Cache model and web search', 'Gemma 4 E2B · Web search off'),
              row('settings-maps', Icons.map_outlined, 'Maps', 'Idaho · 2.1 GB'),
              row('settings-weather', Icons.cloud_outlined, 'Weather and alerts', n.attention > 0 ? '${n.attention} need attention' : 'All ${n.working} working'),
              row('settings-notifications', Icons.notifications_none, 'Notifications', 'Alerts on'),
              row('settings-storage', Icons.sd_storage_outlined, 'Storage', '41 GB used'),
            ],
          ),
        ],
      ),
    );
  }

  return TwoPane(listName: 'Settings', initialKey: 'settings-weather', initial: (_) => WeatherPage(deps: r.deps), list: Builder(builder: list));
}

const _phone = Size(390, 1900);
const _wide = Size(1440, 1500);

void main() {
  setUpAll(loadShotFonts);

  testWidgets('sources status, the real page', (tester) async {
    final r = await _rig(tester);

    await _scene(tester, r, calm: false);
    await _show(tester, WeatherPage(deps: r.deps), _phone);
    await snap(tester, _out, 'real-1-mixed-light');
    await _show(tester, WeatherPage(deps: r.deps), _phone, theme: CacheThemeId.dark);
    await snap(tester, _out, 'real-2-mixed-dark');
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    await _show(tester, _desktop(r), _wide, theme: CacheThemeId.dark, desktop: true);
    await snap(tester, _out, 'real-5-mixed-desktop-dark');
    debugLinuxUi = null;

    await _scene(tester, r, calm: true);
    await _show(tester, WeatherPage(deps: r.deps), _phone);
    await snap(tester, _out, 'real-3-calm-light');
    await _show(tester, WeatherPage(deps: r.deps), _phone, theme: CacheThemeId.dark);
    await snap(tester, _out, 'real-4-calm-dark');
    debugLinuxUi = true;
    await _show(tester, _desktop(r), _wide, theme: CacheThemeId.dark, desktop: true);
    await snap(tester, _out, 'real-6-calm-desktop-dark');
    debugLinuxUi = null;

    await r.dispose(tester);
  });

  testWidgets('sources status with web search and a source of your own', (tester) async {
    final r = await _rig(tester);
    await _scene(tester, r, calm: false);
    await tester.runAsync(() async {
      await r.webSearch.saveKey('k');
      await r.weather.replaceOwnSources([
        {
          'entry': entry('creek-gauge', 'hydrology', 'Creek gauge', provider: 'My town')..['description'] = 'Water level in the creek',
          'definition': miniDefinition('creek-gauge', title: 'Creek gauge', provider: 'My town'),
        },
      ]);
      await r.weather.setSourceOn(r.weather.sourceById('creek-gauge')!, true);
      await r.weather.updateNow(force: true);
      r.clock = r.clock.add(const Duration(minutes: 12));
    });
    r.webSearch.noteSearch('{"ok":false,"error":{"type":"key_missing","detail":"That source isn\'t available right now."}}');
    await _show(tester, WeatherPage(deps: r.deps), const Size(390, 2300));
    await snap(tester, _out, 'more-1-mixed-light');
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    await _show(tester, _desktop(r), const Size(1440, 1800), theme: CacheThemeId.dark, desktop: true);
    await snap(tester, _out, 'more-2-desktop-dark');
    debugLinuxUi = null;
    await r.dispose(tester);
  });
}

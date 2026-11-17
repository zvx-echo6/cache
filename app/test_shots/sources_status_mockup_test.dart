// MOCKUP, not a feature: a proposed status layout for Settings > Weather and alerts, drawn with the app's own SettingsRow, GroupLabel,
// SettingsGroup, RowButton, WatchGroups and theme, and FAKE source data. Nothing here is used by the app.
// flutter test test_shots/sources_status_mockup_test.dart --update-goldens  (pictures in test_shots/sources_status/)

import 'package:cache/layout/adaptive.dart' show TwoPane, isPaneSelected;
import 'package:cache/linux_ui.dart' show debugLinuxUi;
import 'package:cache_search/cache_search.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/screens/settings/widgets.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/places.dart';
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

// ------------------------------------------------------------------ fake data

enum _State { working, updating, off, needsKey, keyRejected, notAnswering, limit, nothingHere }

bool _problem(_State s) => s == _State.needsKey || s == _State.keyRejected || s == _State.notAnswering || s == _State.limit;

class _Src {
  const _Src(this.icon, this.title, this.state, {this.ago, this.gives, this.sentence, this.button});

  final IconData icon;
  final String title;
  final _State state;

  /// "12 min ago" (the state line's "updated ...").
  final String? ago;

  /// An Off source's one-line description.
  final String? gives;
  final String? sentence;
  final String? button;
}

const _forecast = _Src(Icons.wb_cloudy_outlined, 'Forecast', _State.working, ago: '12 min ago');
const _warnings = _Src(Icons.warning_amber_rounded, 'Weather warnings', _State.working, ago: '12 min ago');
const _emergency = _Src(Icons.campaign_outlined, 'Emergency alerts', _State.working, ago: '4 min ago');
const _wildfires = _Src(Icons.local_fire_department_outlined, 'Wildfires', _State.working, ago: '31 min ago');
const _hotspots = _Src(Icons.local_fire_department_outlined, 'Fire hotspots (satellite)', _State.working, ago: '1 hour ago');
const _roadsKey = _Src(Icons.add_road, 'Road events', _State.needsKey, sentence: 'Idaho 511 needs a free key.', button: 'Add key');
const _roadsOk = _Src(Icons.add_road, 'Road events', _State.working, ago: '18 min ago');
const _quakesDown = _Src(Icons.vibration, 'Earthquakes', _State.notAnswering,
    ago: '3 hours ago', sentence: "USGS didn't answer. Showing what Cache saved 3 hours ago.", button: 'Try again');
const _quakesOk = _Src(Icons.vibration, 'Earthquakes', _State.working, ago: '9 min ago');
const _trafficOff = _Src(Icons.traffic_outlined, 'Traffic flow', _State.off, gives: 'Speeds and slowdowns on main roads');
const _trafficOk = _Src(Icons.traffic_outlined, 'Traffic flow', _State.working, ago: '6 min ago');

const _mixed = [_roadsKey, _quakesDown, _forecast, _warnings, _emergency, _wildfires, _hotspots, _trafficOff];
const _calm = [_forecast, _warnings, _emergency, _wildfires, _hotspots, _roadsOk, _quakesOk, _trafficOk];
const _vocabulary = [
  _Src(Icons.directions_car_outlined, 'Travel times', _State.keyRejected,
      ago: '2 days ago', sentence: 'TomTom no longer accepts the saved key.', button: 'Replace key'),
  _Src(Icons.local_fire_department_outlined, 'Fire hotspots (satellite)', _State.limit,
      ago: '40 min ago', sentence: 'NASA FIRMS says it has reached its limit. Cache tries again later.'),
  _Src(Icons.wb_cloudy_outlined, 'Forecast', _State.updating, ago: '12 min ago'),
  _Src(Icons.water_outlined, 'River gauges', _State.nothingHere, sentence: 'Covers the US. Your place is outside it.'),
];

// ------------------------------------------------------------------ mockup-only widgets

String _word(_State s) => switch (s) {
  _State.working => 'Working',
  _State.updating => 'Updating',
  _State.off => 'Off',
  _State.needsKey => 'Needs a key',
  _State.keyRejected => 'Key not accepted',
  _State.notAnswering => 'Not answering',
  _State.limit => 'Limit reached',
  _State.nothingHere => 'Nothing for this place',
};

/// The proposed row: the real SettingsRow (icon, name, trailing slot); line 2 is the state and age, a problem adds the sentence.
class _MockSourceRow extends StatelessWidget {
  const _MockSourceRow(this.s);

  final _Src s;

  @override
  Widget build(BuildContext context) {
    final bad = _problem(s.state);
    final List<Part> line2 = switch (s.state) {
      _State.off => [Part(s.gives!)],
      _State.needsKey || _State.nothingHere => [Part(_word(s.state), bad ? Tone.warn : Tone.normal)],
      _ => [Part(_word(s.state), bad ? Tone.warn : Tone.normal), Part(' · updated ${s.ago}')],
    };
    final Widget? trailing = switch (s.state) {
      _State.working => Switch(value: true, onChanged: (_) {}),
      _State.off => Switch(value: false, onChanged: (_) {}),
      _State.updating => const SizedBox(width: 48, height: 48, child: Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2.5))),
      _ => s.button == null ? null : RowButton(label: s.button!, onPressed: () {}),
    };
    return SettingsRow(
      leading: Icon(s.icon, size: 22, color: context.t.secondary),
      title: s.title,
      titleLines: 2,
      statusWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          statusText(context, line2, maxLines: s.state == _State.off ? 2 : 1),
          if (s.sentence != null) ...[
            const SizedBox(height: 2),
            statusText(context, [Part(s.sentence!, bad ? Tone.warn : Tone.quiet)], maxLines: 2),
          ],
        ],
      ),
      trailing: trailing,
      onTap: () {},
    );
  }
}

/// The proposed top: line 1 the summary (warning tone and icon when something needs attention), line 2 when it was last checked, and the
/// refresh button the real StatusLine has (the real one holds one line only, so this copies its layout).
class _MockStatusLine extends StatelessWidget {
  const _MockStatusLine(this.srcs);

  final List<_Src> srcs;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final bad = srcs.where((s) => _problem(s.state)).length;
    final off = srcs.where((s) => s.state == _State.off).length;
    final summary = bad > 0 ? '$bad need${bad == 1 ? 's' : ''} attention' : 'All ${srcs.length} sources working';
    final line1 = off > 0 ? '$summary · $off off' : summary;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (bad > 0) ...[Icon(Icons.warning_amber_rounded, size: 18, color: k.warning), const SizedBox(width: 6)],
                  Expanded(
                    child: Text(
                      line1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: bad > 0 ? FontWeight.w500 : FontWeight.w400, color: bad > 0 ? k.warning : k.secondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text('Last checked 12 min ago', style: TextStyle(fontSize: 13, color: k.secondary)),
            ],
          ),
        ),
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: 'Refresh',
            onPressed: () {},
            icon: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(shape: BoxShape.circle, color: k.surface),
              child: Icon(Icons.refresh, size: 18, color: k.text),
            ),
          ),
        ),
      ],
    );
  }
}

/// The proposed Weather and alerts page: the status top, the real watch groups, then the groups of sources.
class _MockWeatherPage extends StatelessWidget {
  const _MockWeatherPage({required this.rig, required this.srcs});

  final SettingsRig rig;
  final List<_Src> srcs;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final attention = [for (final s in srcs) if (_problem(s.state)) s];
    final off = [for (final s in srcs) if (s.state == _State.off) s];
    final rest = [for (final s in srcs) if (!_problem(s.state) && s.state != _State.off) s];
    Widget group(List<_Src> l, [String? label]) => SettingsGroup(label: label, rows: [for (final s in l) _MockSourceRow(s)]);
    return SettingsPage(
      title: 'Weather and alerts',
      children: [
        _MockStatusLine(srcs),
        WatchGroups(deps: rig.deps),
        const NoteText('What Cache watches for your places. All free; some need a free key you get from the provider.'),
        if (attention.isNotEmpty) group(attention, 'Needs attention'),
        if (rest.isNotEmpty) group(rest, attention.isNotEmpty || off.isNotEmpty ? 'Working' : null),
        if (off.isNotEmpty) group(off, 'Off'),
        SettingsGroup(
          rows: [
            SettingsRow(
              icon: Icons.add,
              title: 'More sources',
              status: const [Part('Space weather, Avalanche danger')],
              trailing: Text('2 more', style: TextStyle(fontSize: 13, color: k.secondary)),
              chevron: true,
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ rig

/// The settings rig with the eight sample sources in the catalogue (for the real page of BEFORE) and the watched places on.
Future<SettingsRig> _rig(WidgetTester tester) async {
  final r = await SettingsRig.create(tester);
  r.regionList = [const WatchRegion(name: 'Idaho', lat: 44.07, lon: -114.74)];
  r.liveCore.saved = const [
    SavedPlaceRecord(key: 'home', name: 'Home', lat: 43.49, lon: -112.03, label: 'Idaho Falls'),
    SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.22, lon: -114.93, label: 'Stanley'),
  ];
  Map<String, dynamic> e(String id, String cat, String title, String gives, String provider, {String? key, bool? featured}) =>
      entry(id, cat, title, provider: provider, keyAlias: key, featured: featured)..['description'] = gives;
  final catalogue = buildCatalogue(connectors: [
    e('weather', 'weather', 'Forecast', 'Temperature, wind and rain for your places', 'Open-Meteo'),
    e('nws-alerts-point', 'alerts', 'Weather warnings', 'Warnings for storms, floods and heat', 'NWS'),
    e('alerts', 'emergency', 'Emergency alerts', 'Alerts from emergency services', 'NWS'),
    e('wfigs-incidents-near', 'fire', 'Wildfires', 'Wildfires near your place', 'NIFC WFIGS'),
    e('firms-viirs-near', 'fire', 'Fire hotspots (satellite)', 'Satellite fire detections near your place', 'NASA FIRMS'),
    e('idaho511-events', 'roads', 'Road events', 'Closures and crashes on Idaho roads', 'Idaho 511', key: 'idaho511'),
    e('usgs-quakes-near', 'earthquakes', 'Earthquakes', 'Recent earthquakes near your place', 'USGS'),
    e('traffic-flow', 'traffic', 'Traffic flow', 'Speeds and slowdowns on main roads', 'TomTom'),
    e('swpc-kp', 'space-weather', 'Space weather', 'Kp index', 'NOAA SWPC', featured: false),
    e('avalanche-forecast-zones', 'avalanche', 'Avalanche danger', 'Avalanche danger near your place', 'avalanche.org', featured: false),
  ]);
  r.web.serve('https://data.cached.info/connectors/', catalogue);
  await tester.runAsync(() async {
    await r.weather.refreshCatalogues();
    await r.weather.placeChoices();
    r.settings.setLiveSourcesOn(['weather', 'nws-alerts-point', 'alerts', 'wfigs-incidents-near', 'firms-viirs-near', 'usgs-quakes-near'], true);
    r.settings.setLiveSourcesOn(['traffic-flow'], false);
    for (final id in ['here', 'region:Idaho', 'place:home', 'place:cabin']) {
      r.settings.setWatched(id, true);
    }
  });
  return r;
}

Future<void> _show(WidgetTester tester, Widget page, Size size, {CacheThemeId theme = CacheThemeId.light, bool desktop = false}) async {
  phone(tester, size: size, ratio: desktop ? 1 : 2);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: desktop ? EdgeInsets.zero : null, desktop: desktop));
  await _settle(tester);
}

const _phone = Size(390, 844);

void main() {
  setUpAll(loadShotFonts);

  testWidgets('sources status mockup', (tester) async {
    final r = await _rig(tester);

    await _show(tester, _MockWeatherPage(rig: r, srcs: _mixed), _phone);
    await snap(tester, _out, '1-mixed-light');

    await _show(tester, _MockWeatherPage(rig: r, srcs: _mixed), _phone, theme: CacheThemeId.dark);
    await snap(tester, _out, '2-mixed-dark');

    await _show(tester, _MockWeatherPage(rig: r, srcs: _calm), _phone);
    await snap(tester, _out, '3-calm-light');

    // The desktop (the browser build): the page in Settings' detail pane beside the list.
    debugLinuxUi = true;
    addTearDown(() => debugLinuxUi = null);
    Widget list(BuildContext context) {
      Widget row(String key, IconData icon, String title, String status) => SettingsRow(
        key: ValueKey(key),
        icon: icon,
        title: title,
        status: [Part(status)],
        selected: isPaneSelected(context, key),
        onTap: () {},
      );
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            SettingsGroup(
              rows: [
                row('settings-model', Icons.lightbulb_outline, 'Cache model and web search', 'Gemma 4 E2B · Web search off'),
                row('settings-maps', Icons.map_outlined, 'Maps', 'Idaho · 2.1 GB'),
                row('settings-weather', Icons.cloud_outlined, 'Weather and alerts', '2 need attention · 1 off'),
                row('settings-notifications', Icons.notifications_none, 'Notifications', 'Alerts on'),
                row('settings-storage', Icons.sd_storage_outlined, 'Storage', '41 GB used'),
                row('settings-sharing', Icons.sync_alt, 'Sharing and sync', 'Not linked yet'),
                row('settings-appearance', Icons.contrast, 'Appearance', 'Dark'),
              ],
            ),
          ],
        ),
      );
    }

    await _show(
      tester,
      TwoPane(
        listName: 'Settings',
        initialKey: 'settings-weather',
        initial: (_) => _MockWeatherPage(rig: r, srcs: _mixed),
        list: Builder(builder: list),
      ),
      const Size(1440, 900),
      theme: CacheThemeId.dark,
      desktop: true,
    );
    await snap(tester, _out, '4-mixed-desktop-dark');
    debugLinuxUi = null;

    await _show(tester, _MockWeatherPage(rig: r, srcs: _vocabulary), _phone);
    await snap(tester, _out, '5-states-light');

    // BEFORE: today's page, the real WeatherPage, with the same sources.
    await _show(tester, WeatherPage(deps: r.deps), _phone);
    await snap(tester, _out, '6-before-light');

    await r.dispose(tester);
  });
}

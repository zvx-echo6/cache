// The 1.0.29 screens for the owner to approve, drawn by the app itself with sample data (no personal data).
// flutter test test_shots/m29_renders_test.dart --update-goldens  (pictures in test_shots/m29/)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/place_about.dart';
import 'package:cache/browse/reader_screen.dart';
import 'package:cache/guide/guide_book.dart';
import 'package:cache/guide/guide_reader.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs, RailPrefs;
import 'package:cache/layout/layout_state.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/maps/layers/layer_def.dart' show AreaPhase;
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/maps/ui/repeater_card.dart';
import 'package:cache/maps/user_layers.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/download_confirm.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/screens/notebooks/repeater_list_screen.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/screens/settings/widgets.dart' show SettingsPage;
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/setup_card.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:cache/update/app_update.dart';
import 'package:cache/update/update_ui.dart';
import 'package:cache/weather/places.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources;
import '../test/nav_fakes.dart';
import '../test/support/notebook_fake.dart';
import '../test/support/owner_state.dart';
import '../test/support/settings_rig.dart';
import 'owner_renders_test.dart' show ShotWeather;
import 'shot_kit.dart';

const _out = 'm29';

/// The sizes: a large iPhone, iPad (820 x 1180) and an Android tablet (800 x 1280), each both ways round, and a 640 window.
const Size kPhone = Size(430, 932);
const Size kIpadPortrait = Size(820, 1180);
const Size kIpadLandscape = Size(1180, 820);
const Size kTabPortrait = Size(800, 1280);
const Size kTabLandscape = Size(1280, 800);
const Size kWindow640 = Size(640, 900);
const EdgeInsets kTabletInsets = EdgeInsets.only(top: 24, bottom: 20);

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, {GlobalKey<ScaffoldMessengerState>? messenger, CacheThemeId theme = CacheThemeId.light, Size size = kPhone}) async {
  phone(tester, size: size, ratio: size == kPhone ? 3 : 2);
  await tester.pumpWidget(shotApp(page, messenger: messenger, theme: theme, insets: size == kPhone ? null : kTabletInsets));
  await _settle(tester);
}

/// Opens [open] from a button on a blank screen (a pop-up or a sheet as it shows over the app).
Future<void> _over(WidgetTester tester, Future<void> Function(BuildContext c) open, {Size size = kPhone, Widget? under}) async {
  await _show(tester, Scaffold(body: Builder(builder: (c) => Stack(children: [?under, Center(child: TextButton(onPressed: () => open(c), child: const Text('open')))]))), size: size);
  await tester.tap(find.text('open'));
  await _settle(tester);
  await tester.pump(const Duration(milliseconds: 400));
}

/// Idaho on the phone with every part done but places, which are not published for the area (the places server has no
/// current.json for it), and no off-road.
Future<OwnerState> _idahoReadyNoPlaces(WidgetTester tester) async {
  final o = await OwnerState.boot(tester, offroad: false);
  final usfs = o.legacy['usfs']!;
  usfs
    ..phase = AreaPhase.done
    ..interrupted = false
    ..error = null
    ..doneTiles = usfs.totalTiles
    ..bytes = 98 * 1000 * 1000;
  final places = ((o.core.regions['us-id']!['parts'] as Map)['places'] as Map<String, dynamic>);
  places
    ..['state'] = 'failed'
    ..['error'] = 'HTTP 404 from https://data.cached.info/places/current.json';
  await tester.runAsync(o.regions.refresh);
  return o;
}

/// Idaho with its places part failed: [code] "offline" (no connection) or "no_space" (the phone is full).
Future<OwnerState> _idahoPlacesFailed(WidgetTester tester, String code) async {
  final o = await _idahoReadyNoPlaces(tester);
  final places = ((o.core.regions['us-id']!['parts'] as Map)['places'] as Map<String, dynamic>);
  places
    ..['state'] = 'failed'
    ..['code'] = code
    ..['done_bytes'] = 64 << 20
    ..['error'] = code == 'offline' ? 'connection refused' : 'disk full';
  await tester.runAsync(o.regions.refresh);
  return o;
}

SetupCache _setup(OwnerState o, WeatherState weather, {bool model = true, bool library = false}) {
  final r = o.s;
  if (model) r.app.models = [ModelEntry(path: '${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 3435973837)];
  if (library) {
    final zim = '${r.sources.zimsDir!.path}/military_medicine.zim';
    r.sources.zims = [ZimFile(path: zim, size: 1 << 30)];
    r.sources.titles[zim] = 'Military Medicine';
  }
  return SetupCache(
    app: r.app,
    weather: weather,
    sources: r.sources,
    regions: o.regions,
    browse: r.browse,
    chooseModel: (_) {},
    getArea: (_) {},
    turnOnWeather: (_) {},
    addLibrary: (_) {},
    openGuide: (_, _) {},
  );
}

Future<void> _modelName(OwnerState o) async {
  final r = o.s;
  final f = File('${r.dir.path}/settings.json');
  final settings = f.existsSync() ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>() : <String, dynamic>{};
  settings['names'] = {'gemma-4-E2B-it-Q4_K_M.gguf|3435973837': 'Gemma 4 E2B · Q4_K_M'};
  f.writeAsStringSync(jsonEncode(settings));
}

// ---- repeaters -----------------------------------------------------------------------------------------------------------

Map<String, dynamic> _rep(int item, String name, String town, double lat, double lon, String freq, {String? offset, String? tone, String? mode}) => {
  'item': item,
  'address': 'repeater:l2/$item',
  'name': name,
  'town': town,
  'lat': lat,
  'lon': lon,
  'frequency': freq,
  'offset': offset ?? 'not in the imported list',
  'tone': tone ?? 'not in the imported list',
  'mode': ?mode,
  'list': 'Eastern Idaho',
};

final List<Map<String, dynamic>> _eastIdaho = [
  _rep(1, 'W7XYZ', 'Idaho Falls', 43.49, -112.03, '146.880 MHz', offset: '-600 kHz', tone: '100.0 Hz to transmit', mode: 'FM'),
  _rep(2, 'K7ABC', 'Rexburg', 43.83, -111.79, '147.060 MHz', offset: '+600 kHz', tone: '100.0 Hz to transmit', mode: 'FM'),
  _rep(3, 'K7ABC', 'Blackfoot', 43.19, -112.34, '146.760 MHz', offset: '-600 kHz', mode: 'FM'),
  _rep(4, 'W7XYZ', 'Pocatello', 42.87, -112.45, '449.875 MHz', offset: '-5 MHz', tone: '123.0 Hz to transmit and receive', mode: 'FM'),
  _rep(5, 'K7ABC', 'Rigby', 43.67, -111.91, '145.350 MHz', offset: '-600 kHz', tone: 'DCS 023', mode: 'DMR'),
  _rep(6, 'W7XYZ', 'St. Anthony', 43.97, -111.68, '147.320 MHz'),
  _rep(7, 'K7ABC', 'Arco', 43.64, -113.30, '146.940 MHz', offset: '-600 kHz', tone: '100.0 Hz to transmit', mode: 'FM'),
  _rep(8, 'W7XYZ', 'Driggs', 43.72, -111.11, '147.180 MHz', offset: '+600 kHz', mode: 'FM'),
  _rep(9, 'K7ABC', 'American Falls', 42.78, -112.85, '444.200 MHz', offset: '+5 MHz', tone: '88.5 Hz to transmit', mode: 'FM'),
];

UserLayersState _userLayers({List<Map<String, dynamic>>? rows, Future<Map<String, dynamic>> Function()? import}) {
  final list = rows ?? _eastIdaho;
  return UserLayersState((call, [arg]) async => switch (call) {
        'list' => {
            'layers': const [],
            'repeater_lists': [
              {'id': 'l2', 'kind': 'repeaters', 'name': 'Eastern Idaho', 'visible': true, 'repeaters': list.length},
            ],
          },
        'get' => {'id': 'l2', 'name': 'Eastern Idaho', 'repeaters': list},
        'import' => await (import ?? () async => {'id': 'l2', 'repeaters': list.length, 'without_position': 0})(),
        _ => const <String, dynamic>{},
      });
}

const PlaceChoices _idahoFalls = PlaceChoices(here: _here, saved: _noSaved);
Future<({double lat, double lon})?> _here() async => (lat: 43.47, lon: -112.01);
Future<List<NbPlace>> _noSaved() async => const [];

Future<NotebookDeps> _notebooks(WidgetTester tester, UserLayersState u) async {
  final nb = fakeNotebook(FakeNotebookBackend());
  await tester.runAsync(() async {
    await nb.start();
    await u.reload();
    await nb.saveEntry(notebookId: nb.journal!.id, occurredAt: '2026-10-28T09:00:00-06:00', title: 'Water cache restocked', body: 'Six jugs at the shed.');
    final places = await nb.ensureSavedPlaces();
    await nb.saveEntry(notebookId: places.id, occurredAt: '2026-10-27T10:00:00-06:00', title: 'Trailhead', place: const NbPlace(lat: 43.6, lon: -112.2, label: 'Trailhead', key: 'trailhead'));
  });
  return NotebookDeps(notebook: nb, places: _idahoFalls, userLayers: u, now: () => DateTime(2026, 10, 31, 10), onShowRepeater: (_) {}, onRepeaterDirections: (_) {}, fmt: const Fmt(UnitSystem.imperial));
}

// ---- place cards ---------------------------------------------------------------------------------------------------------

class _NoFix implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => throw StateError('no fix');
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

class _About implements PlaceAbout {
  _About(this.state, {this.openFails = false, this.hang = false});

  final AboutState state;
  final bool openFails;
  final bool hang;

  @override
  Future<({AboutState state, String? address})> lookUp(String title) async =>
      (state: state, address: state == AboutState.here ? 'zim:6f1d1c3e-2b7a-4e4b-9a55-1d2f0c9e8a11/${title.replaceAll(' ', '_')}' : null);

  @override
  Future<void> open(String address) async {
    if (hang) return Completer<void>().future;
    if (openFails) throw StateError('gone');
  }

  @override
  void getWikipedia() {}

  @override
  void openLibrary() {}
}

const _craters = MapPlace(
  id: 'place:osm:r1',
  type: 'place',
  name: 'Craters of the Moon',
  kind: 'National monument',
  address: 'Arco, ID',
  lat: 43.42,
  lon: -113.52,
  distanceM: 99800,
  direction: 'W',
  summary:
      'Craters of the Moon National Monument and Preserve is a protected area in the Snake River Plain in central Idaho. Its lava fields, cinder cones and lava tubes were laid down by eruptions along the Great Rift between 15,000 and 2,000 years ago.',
  wikipediaTitle: 'Craters of the Moon National Monument and Preserve',
  matched: 'name',
);

const _gasStation = MapPlace(
  id: 'place:osm:n7',
  type: 'place',
  name: 'Maverik',
  kind: 'Fuel',
  address: '1550 W Broadway St, Idaho Falls, ID',
  lat: 43.49,
  lon: -112.06,
  distanceM: 3400,
  direction: 'NW',
  hours: 'Open 24 hours',
  matched: 'name',
);

Widget _cardOnMap(Widget card) => Scaffold(
  backgroundColor: const Color(0xFFD9D3C4),
  body: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Align(alignment: Alignment.bottomCenter, child: card))),
);

void main() {
  setUpAll(() async {
    await loadShotFonts();
    openStorageForSpace = (_) {};
  });

  // ---- 1. Places: not available yet, and real failures with their fix ----------------------------------------------------

  testWidgets('1: places not available yet, and real failures', (tester) async {
    final o = await _idahoReadyNoPlaces(tester);
    await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1));
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
    await snap(tester, _out, '1a-regions-ready-places-not-available');

    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await snap(tester, _out, '1b-region-page-places-not-available');
    await tester.tap(find.byKey(const ValueKey('part-places')));
    await tester.pump();
    await snap(tester, _out, '1c-region-page-why-note');

    await _show(tester, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showRegionsSheet(c, o.regions, lat: 43.6, lon: -114.5), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '1f-regions-sheet-idaho-row');

    // Home: "Idaho · Ready" ticked (the card goes away once all four are done, so the library is left to do).
    await _modelName(o);
    await tester.runAsync(o.s.app.init);
    final weather = ShotWeather(o.s);
    final setup = _setup(o, weather);
    final layout = LayoutState(settingsDirOverride: o.s.dir);
    await tester.runAsync(layout.init);
    await _show(tester, HomeScreen(layout: layout, setup: setup, weather: weather, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
    await snap(tester, _out, '1e-home-setup-idaho-ready');
    layout.dispose();
    await o.dispose(tester);

    final f = await _idahoPlacesFailed(tester, 'offline');
    await _show(tester, RegionPage(regions: f.regions, id: 'us-id'));
    await snap(tester, _out, '1d-region-page-places-failed-light');
    await _show(tester, RegionPage(regions: f.regions, id: 'us-id'), theme: CacheThemeId.dark);
    await snap(tester, _out, '1d-region-page-places-failed-dark');
    // Try again has not worked twice: Delete and start again.
    f.regions
      ..noteTry('us-id')
      ..noteTry('us-id');
    await _show(tester, RegionPage(regions: f.regions, id: 'us-id'));
    await snap(tester, _out, '1g-region-page-start-again');
    await f.dispose(tester);

    final full = await _idahoPlacesFailed(tester, 'no_space');
    await _show(tester, RegionPage(regions: full.regions, id: 'us-id'));
    await snap(tester, _out, '1h-region-page-free-space');
    await full.dispose(tester);
  });

  // ---- 2. Feedback; Settings > Weather and alerts ------------------------------------------------------------------------

  testWidgets('2: Set up feedback (pressed, Starting…)', (tester) async {
    final o = await OwnerState.boot(tester);
    await _modelName(o);
    await tester.runAsync(o.s.app.init);
    final weather = ShotWeather(o.s);
    final setup = _setup(o, weather, library: true);
    final layout = LayoutState(settingsDirOverride: o.s.dir);
    await tester.runAsync(layout.init);
    await _show(tester, HomeScreen(layout: layout, setup: setup, weather: weather, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('setup-model'))));
    await tester.pump(const Duration(milliseconds: 180));
    await snap(tester, _out, '2a-setup-row-pressed');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('setup-area')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await snap(tester, _out, '2b-setup-get-your-area-starting');
    layout.dispose();
    await o.dispose(tester);
  });

  testWidgets('2: Settings > Weather and alerts, and a place\'s own switch', (tester) async {
    final r = await SettingsRig.create(tester);
    r.regionList = [const WatchRegion(name: 'Idaho', lat: 44.07, lon: -114.74)];
    r.liveCore.saved = const [
      SavedPlaceRecord(key: 'home', name: 'Home', lat: 43.49, lon: -112.03, label: 'Idaho Falls'),
      SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 44.22, lon: -114.93, label: 'Stanley'),
      SavedPlaceRecord(key: 'trailhead', name: 'Trailhead', lat: 43.6, lon: -112.2),
    ];
    await tester.runAsync(() async {
      await r.weather.placeChoices();
      for (final id in ['here', 'region:Idaho', 'place:home', 'place:cabin', 'place:trailhead']) {
        r.settings.setWatched(id, true);
      }
    });
    await _show(tester, WeatherPage(deps: r.deps));
    await snap(tester, _out, '2c-weather-watch-all-on');

    r.settings
      ..setWatched('place:cabin', false)
      ..setWatched('region:Idaho', false);
    await _show(tester, WeatherPage(deps: r.deps));
    await snap(tester, _out, '2d-weather-watch-a-mix');

    // Your location off, and the phone says no when it is turned on: the switch goes back with why and Open settings.
    r.settings.setWatchHere(false);
    r.position.grant = false;
    r.position.permissionState = LocationPermissionState.notAsked;
    final m = GlobalKey<ScaffoldMessengerState>();
    await _show(tester, WeatherPage(deps: r.deps), messenger: m);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('watch-here')), matching: find.byType(Switch)));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, _out, '2e-weather-toggle-goes-back');

    r.position.permissionState = LocationPermissionState.deniedForever;
    r.location.permission = LocationPermissionState.deniedForever;
    await _show(tester, WeatherPage(deps: r.deps));
    await snap(tester, _out, '2f-weather-location-blocked');

    r.location.permission = LocationPermissionState.granted;
    r.liveCore.saved = const [];
    r.regionList = [];
    await _show(tester, WeatherPage(deps: r.deps));
    await snap(tester, _out, '2g-weather-no-saved-places');

    // Refresh: the page's status line while it updates (its button turns into a spinner).
    r.liveCore.saved = const [SavedPlaceRecord(key: 'home', name: 'Home', lat: 43.49, lon: -112.03, label: 'Idaho Falls')];
    await _show(tester, SettingsPage(title: 'Weather and alerts', children: [StatusLine(status: r.weather.status(), updating: true, onRefresh: () {}), WatchGroups(deps: r.deps)]));
    await snap(tester, _out, '2h-weather-refresh-spinning');
    await r.dispose(tester);
  });

  testWidgets('2: a saved place\'s edit page with its own switch', (tester) async {
    final nb = fakeNotebook(FakeNotebookBackend());
    final watched = <String>{'place:cabin'};
    late Notebook book;
    late NbEntry cabin;
    await tester.runAsync(() async {
      await nb.start();
      book = await nb.ensureSavedPlaces();
      cabin = await nb.saveEntry(notebookId: book.id, occurredAt: '2026-10-27T10:00:00-06:00', title: 'Cabin', body: 'Key under the third step.', place: const NbPlace(lat: 44.22, lon: -114.93, label: 'Stanley', key: 'cabin'));
    });
    final deps = NotebookDeps(
      notebook: nb,
      places: _idahoFalls,
      placesDeps: PlaceNotebookDeps(
        watched: watched.contains,
        setWatched: (id, on) => on ? watched.add(id) : watched.remove(id),
        alerts: PlaceAlerts.memory(),
        alertSetting: () => 'Serious only, from Notifications',
      ),
    );
    await _show(tester, PlaceForm(deps: deps, book: book, entry: cabin));
    await snap(tester, _out, '2i-place-edit-weather-switch');
  });

  // ---- 3. Repeaters ------------------------------------------------------------------------------------------------------

  testWidgets('3: the repeater card, the list notebook, Add from a file', (tester) async {
    final u = _userLayers();
    await tester.runAsync(u.reload);
    final rows = (await tester.runAsync(() => u.repeaterSource('l2')))!.rows;
    const fmt = Fmt(UnitSystem.imperial);
    Widget card(Repeater r) => RepeaterCard(
      repeater: r,
      distance: repeaterDistance(r, fmt, fromLat: 43.47, fromLon: -112.01),
      onClose: () {},
      onDirections: () {},
      onOpenList: () {},
    );
    await _show(tester, _cardOnMap(card(rows[0])));
    await snap(tester, _out, '3a-repeater-card');
    await _show(tester, _cardOnMap(card(rows[5])));
    await snap(tester, _out, '3b-repeater-card-missing-fields');

    final deps = await _notebooks(tester, u);
    await _show(tester, RepeaterListScreen(deps: deps, listId: 'l2'));
    await snap(tester, _out, '3c-repeater-list-notebook');
    await tester.enterText(find.byKey(const ValueKey('repeaters-search')), 'rex');
    await _settle(tester);
    await snap(tester, _out, '3d-repeater-list-search');
    await _show(tester, RepeaterListScreen(deps: deps, listId: 'l2', focusItem: 9));
    await snap(tester, _out, '3e-repeater-list-from-card');

    final empty = _userLayers(rows: const []);
    final emptyDeps = await _notebooks(tester, empty);
    await _show(tester, RepeaterListScreen(deps: emptyDeps, listId: 'l2'));
    await snap(tester, _out, '3f-repeater-list-empty');

    await _show(tester, NotebooksScreen(deps: deps));
    await snap(tester, _out, '3g-notebooks-shelf-with-repeaters');
    await tester.tap(find.byKey(const ValueKey('notebooks-add')));
    await _settle(tester);
    await snap(tester, _out, '3h-notebooks-plus-menu');
    await tester.tap(find.text('Add from a file'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '3i-add-from-a-file-from-notebooks');

    final o = await OwnerState.boot(tester, legacyFiles: false, idaho: false);
    await _show(tester, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showLayerSheet(c, o.s.maps, o.s.location, notebooks: deps.notebook, userLayers: u), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('my-layers-add')), 200, scrollable: find.descendant(of: find.byType(LayerSheet), matching: find.byType(Scrollable)).first);
    await _settle(tester);
    await snap(tester, _out, '3j-maps-layers-my-layers');
    await tester.tap(find.byKey(const ValueKey('my-layers-add')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '3k-add-from-a-file-from-my-layers');
    await o.dispose(tester);

    // The long action: "Reading file…" with a bar, then the result with Show; a file that is not a repeater list.
    final reading = Completer<Map<String, dynamic>>();
    final slow = _userLayers(import: () => reading.future);
    await tester.runAsync(slow.reload);
    final m = GlobalKey<ScaffoldMessengerState>();
    await _show(tester, NotebooksScreen(deps: deps), messenger: m);
    unawaited(importRepeaterFile(m.currentState!, slow, onShowList: (_) {}, pick: (use) => use(['/Download/eastern-idaho.csv'])));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, _out, '3l-import-reading-file');
    reading.complete({'id': 'l2', 'repeaters': 214, 'without_position': 0});
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, _out, '3m-import-done-show');
    final bad = _userLayers(import: () async => throw const CacheSearchException('bad_file', 'not a repeater list'));
    await _show(tester, NotebooksScreen(deps: deps), messenger: m);
    unawaited(importRepeaterFile(m.currentState!, bad, pick: (use) => use(['/Download/photo.jpg'])));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, _out, '3n-import-error');
    await _show(tester, const SizedBox());
  });

  // ---- 4. Read about it --------------------------------------------------------------------------------------------------

  testWidgets('4: Read about it on a place card', (tester) async {
    final dir = Directory.systemTemp.createTempSync('m29-nav');
    final location = LocationService(source: _NoFix(), settingsDirOverride: dir);
    final nav = NavState(backend: FakeBackend(), location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    Widget card(MapPlace p, PlaceAbout a) => _cardOnMap(PlaceCard(nav: nav, place: p, fmt: nav.fmt, onClose: () {}, about: a));
    await _show(tester, card(_craters, _About(AboutState.here)));
    await snap(tester, _out, '4a-place-card-read-about-it');
    await _show(tester, card(_gasStation, _About(AboutState.here)));
    await snap(tester, _out, '4b-place-card-no-summary');
    await _show(tester, card(_craters, _About(AboutState.noWikipedia)));
    await snap(tester, _out, '4c-place-card-get-wikipedia');
    await _show(tester, card(_craters, _About(AboutState.missing)));
    await snap(tester, _out, '4d-place-card-article-missing');
    await _show(tester, card(_craters, _About(AboutState.here, hang: true)));
    await tester.tap(find.byKey(const ValueKey('place-read-about')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await snap(tester, _out, '4e-place-card-opening');
    await _show(tester, card(_craters, _About(AboutState.here, openFails: true)));
    await tester.tap(find.byKey(const ValueKey('place-read-about')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, _out, '4f-place-card-article-not-found-snackbar');
    await _show(tester, const SizedBox());
    nav.dispose();
  });

  // ---- 5. Updates --------------------------------------------------------------------------------------------------------

  testWidgets('5: the update banners (iPhone, Android), dismissed stays dismissed, What\'s new, light and dark', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final weather = ShotWeather(r);
    // The owner's approved lines (assets/whats_new.md).
    final lines = whatsNewLines(File('assets/whats_new.md').readAsStringSync(), '1.0.29');
    Widget home(AppUpdates? u) => HomeScreen(layout: layout, weather: weather, updates: u, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {});
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme.name;
      for (final android in [false, true]) {
        final which = android ? 'android' : 'iphone';
        final store = DismissedUpdate(dirOverride: Directory.systemTemp.createTempSync('m29-upd'));
        final u = AppUpdates(source: _Newer(30), openUrl: (_) async {}, android: android, dismissed: store);
        await tester.runAsync(u.check);
        await _show(tester, home(u), theme: theme);
        await snap(tester, _out, '5a-home-$which-banner-$t');
        await _show(tester, AboutPage(updates: u, version: () async => '1.0.29'), theme: theme);
        await snap(tester, _out, '5b-about-$which-new-version-and-whats-new-row-$t');
        if (!android) {
          // Dismissed: after a restart (a new check) it stays away; a newer build brings it back.
          u.dismiss();
          final again = AppUpdates(source: _Newer(30), openUrl: (_) async {}, android: android, dismissed: store);
          await tester.runAsync(again.check);
          await _show(tester, home(again), theme: theme);
          await snap(tester, _out, '5e-home-dismissed-after-restart-$t');
          final newer = AppUpdates(source: _Newer(31), openUrl: (_) async {}, android: android, dismissed: store);
          await tester.runAsync(newer.check);
          await _show(tester, home(newer), theme: theme);
          await snap(tester, _out, '5f-home-newer-build-banner-back-$t');
        }
      }
      await _over(tester, (c) => showWhatsNew(c, version: '1.0.29', lines: lines), under: home(null));
      await snap(tester, _out, '5c-whats-new-phone-$t');
    }
    await _over(tester, (c) => showWhatsNew(c, version: '1.0.29', lines: lines), size: kIpadPortrait);
    await snap(tester, _out, '5d-whats-new-ipad');
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('5: Home "Weather is off · Turn on", light and dark', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    // Weather was on once (its defaults were applied) and every source is off now.
    r.settings.noteLiveDefaults(const ['alerts']);
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      await _show(tester, HomeScreen(layout: layout, weather: r.weather, onOpenWeatherSettings: () {}, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}), theme: theme);
      await snap(tester, _out, '5g-home-weather-is-off-${theme.name}');
    }
    layout.dispose();
    await r.dispose(tester);
  });

  // ---- 6. Tablets --------------------------------------------------------------------------------------------------------

  testWidgets('6: tablets: rail, two panes, sheets and pop-ups', (tester) async {
    final o = await _idahoReadyNoPlaces(tester);
    final r = o.s;
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final dir = Directory.systemTemp.createTempSync('m29-shell');
    final nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    final sizes = {'ipad-portrait': kIpadPortrait, 'ipad-landscape': kIpadLandscape, 'android-portrait': kTabPortrait, 'android-landscape': kTabLandscape};
    for (final e in sizes.entries) {
      await _show(tester, Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub), size: e.value);
      await snap(tester, _out, '6-${e.key}-home');
      await _show(tester, SettingsScreen(deps: r.deps), size: e.value);
      await tester.tap(find.byKey(const ValueKey('settings-weather')));
      await _settle(tester);
      await snap(tester, _out, '6-${e.key}-settings');
      await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1), size: e.value);
      await tester.pump(const Duration(seconds: 5));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('local-us-id')));
      await _settle(tester);
      await snap(tester, _out, '6-${e.key}-regions');
    }

    // Settings opens on its first page; the chosen page stays when the window turns.
    await _show(tester, SettingsScreen(deps: r.deps), size: kIpadPortrait);
    await snap(tester, _out, '6-ipad-portrait-settings-first-page');
    await tester.tap(find.byKey(const ValueKey('settings-maps')));
    await _settle(tester);
    await snap(tester, _out, '6-rotate-a-portrait');
    phone(tester, size: kIpadLandscape, ratio: 2);
    await _settle(tester);
    await snap(tester, _out, '6-rotate-b-landscape');

    final u = _userLayers();
    final nbDeps = await _notebooks(tester, u);
    for (final e in {'ipad-landscape': kIpadLandscape, 'android-portrait': kTabPortrait}.entries) {
      await _show(tester, NotebooksScreen(deps: nbDeps), size: e.value);
      await snap(tester, _out, '6-${e.key}-notebooks-choose-an-item');
      await tester.tap(find.text('Journal'));
      await _settle(tester);
      await snap(tester, _out, '6-${e.key}-notebooks');
    }

    final book = GuideBook.parse([for (var i = 1; i <= kGuideChapterCount; i++) File('assets/guide/chapters/ch$i.md').readAsStringSync()]);
    await _show(tester, GuideReaderScreen(book: book), size: kIpadLandscape);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Getting started').first);
    await tester.pumpAndSettle();
    final first = find.textContaining('Download a region');
    if (first.evaluate().isNotEmpty) {
      await tester.tap(first.first);
      await tester.pumpAndSettle();
    }
    await snap(tester, _out, '6-ipad-landscape-guide');

    r.sources.zims = [
      ZimFile(path: '${r.sources.zimsDir!.path}/wikipedia_en_all_maxi_2026-02.zim', size: 110 << 30),
      ZimFile(path: '${r.sources.zimsDir!.path}/military_medicine.zim', size: 1 << 30),
    ];
    r.sources.titles['${r.sources.zimsDir!.path}/military_medicine.zim'] = 'Military Medicine';
    r.sources.titles['${r.sources.zimsDir!.path}/wikipedia_en_all_maxi_2026-02.zim'] = 'Wikipedia';
    await _show(tester, BrowseScreen(browse: r.browse, active: true), size: kTabLandscape);
    await snap(tester, _out, '6-android-landscape-library');

    // A 640 window (iPad Split View): the rail and two panes start here.
    await _show(tester, SettingsScreen(deps: r.deps), size: kWindow640);
    await snap(tester, _out, '6-window-640-settings');

    // The download pop-up (400 wide at most) and a sheet (560 wide, centred) on a tablet.
    await _over(
      tester,
      (c) => confirmDownload(c, title: 'Download Jerome County?', summary: const ['Map, directions, places and off-road.', '1.0 GB'], bytes: 1000 * 1000 * 1000, name: 'Jerome County', lines: const [], space: Space(free: 103 * 1000 * 1000 * 1000, reserve: 20 * 1000 * 1000 * 1000)),
      size: kIpadLandscape,
    );
    await snap(tester, _out, '6-ipad-landscape-popup');
    await _over(tester, (c) => addMapFile(c, notebooks: nbDeps.notebook, userLayers: u), size: kIpadLandscape);
    await snap(tester, _out, '6-ipad-landscape-sheet');

    // The repeater card as the left card from 800 wide (over a plain stand-in for the map).
    final rows = (await tester.runAsync(() => u.repeaterSource('l2')))!.rows;
    await _show(
      tester,
      Scaffold(
        backgroundColor: const Color(0xFFD9D3C4),
        body: SafeArea(
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(width: 360, child: RepeaterCard(repeater: rows[0], distance: '1.4 mi NW', onClose: () {}, onDirections: () {}, onOpenList: () {})),
            ),
          ),
        ),
      ),
      size: kIpadLandscape,
    );
    await snap(tester, _out, '6-ipad-landscape-map-left-card');

    await _show(tester, const SizedBox());
    nav.dispose();
    layout.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    await o.dispose(tester);
  });
  testWidgets('6: tablet navigation and hidden lists: upright the bottom bar, sideways the rail; every list hides; light and dark', (tester) async {
    final o = await _idahoReadyNoPlaces(tester);
    final r = o.s;
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final t = theme.name;
      for (final (name, upright, sideways) in [('ipad', kIpadPortrait, kIpadLandscape), ('android', kTabPortrait, kTabLandscape)]) {
        PanePrefs.testDir = Directory.systemTemp.createTempSync('m29-panes');
        // Upright: the bottom bar, and Settings with its list shown, then hidden.
        await _show(tester, SettingsScreen(deps: r.deps), size: upright, theme: theme);
        await snap(tester, _out, '6-$name-portrait-settings-list-shown-$t');
        await tester.tap(find.byKey(const ValueKey('pane-hide')));
        await tester.pumpAndSettle();
        await snap(tester, _out, '6-$name-portrait-settings-list-hidden-$t');
        final prefs = RailPrefs(dirOverride: Directory.systemTemp.createTempSync('m29-rail'));
        await _show(tester, Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: prefs), size: upright, theme: theme);
        await snap(tester, _out, '6-$name-portrait-bottom-bar-$t');
        // Sideways: the rail shown, then hidden; a list shown, then hidden.
        await _show(tester, Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: prefs), size: sideways, theme: theme);
        await snap(tester, _out, '6-$name-landscape-rail-shown-$t');
        await tester.tap(find.byKey(const ValueKey('rail-hide')));
        await tester.pumpAndSettle();
        await snap(tester, _out, '6-$name-landscape-rail-hidden-$t');
        PanePrefs.testDir = Directory.systemTemp.createTempSync('m29-panes');
        await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1), size: sideways, theme: theme);
        await tester.pump(const Duration(seconds: 5));
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('local-us-id')));
        await _settle(tester);
        await snap(tester, _out, '6-$name-landscape-list-shown-$t');
        await tester.tap(find.byKey(const ValueKey('pane-hide')));
        await tester.pumpAndSettle();
        await snap(tester, _out, '6-$name-landscape-list-hidden-$t');
      }
    }
    PanePrefs.testDir = null;
    await _show(tester, const SizedBox());
    nav.dispose();
    layout.dispose();
    await o.dispose(tester);
  });

  // ---- The ZIM reader's bars (the top-left arrow leaves; the bottom arrows are the page history) ----------------------------

  testWidgets('7: the reader\'s top and bottom bars, light and dark', (tester) async {
    final dir = Directory.systemTemp.createTempSync('m29-reader');
    final sources = _PendingSources(dir);
    final zim = ZimFile(path: '${dir.path}/urban-prepper_en_all_2026-08.zim', size: 2245235674);
    sources
      ..zims = [zim]
      ..titles[zim.path] = 'Urban Prepper'
      ..ids[zim.path] = '6f1d1c3e-2b7a-4e4b-9a55-1d2f0c9e8a11';
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      await _show(tester, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ZimReaderScreen(sources: sources, zim: zim, debugHasHistory: true))), child: const Text('open'))))), theme: theme);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await snap(tester, _out, '7-reader-bars-${theme.name}');
    }
    await _show(tester, const SizedBox());
  });
}

/// A Library whose ZIM is still opening (the reader shows its bars over the spinner).
class _PendingSources extends FakeSources {
  _PendingSources(super.dir);

  @override
  Future<String> zimMainPage(String zimId) => Completer<String>().future;
}


class _Newer implements AppUpdateSource {
  _Newer(this.build);

  final int build;

  @override
  Future<AppUpdate?> check() async => AppUpdate(version: '1.0.$build', build: build, link: Uri.parse('https://testflight.apple.com/join/example'));
}

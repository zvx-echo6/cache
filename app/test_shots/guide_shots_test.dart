// The Cache guide's screenshots: one picture per id in tools/guide/shots.txt, drawn by the app's own widgets with sample data (Twin
// Falls, Idaho), in the light theme, on a 430 x 932 phone at 2x. Where a map is behind a panel the map is not drawn (MapLibre is a
// platform view); the panels and sheets are drawn over the empty map area, as the Maps tests do.
// flutter test test_shots/guide_shots_test.dart --update-goldens  (pictures and crops.json in test_shots/guide/)
// tools/guide/make_shots.py then resizes them into app/assets/guide/shots.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Point;

import 'package:cache/location/position_source.dart' show LocationPermissionState;
import 'package:cache/settings/data_policy.dart' show ConnectionKind;
import 'package:cache/settings/location_access.dart' show LocationAccess;
import 'package:cache/theme.dart' show CacheThemeId;
import 'package:cache/browse/zim_download.dart';
import 'package:cache/browse/browse_screen.dart';
import 'package:cache/maps/ui/ring_menu.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/maps_screen.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, MapLibreMap, MapLibrePlatform;
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/libraries_screen.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart' show PlaceNotebookDeps;
import 'package:cache/screens/videos/instance_screen.dart';
import 'package:cache/screens/videos/player_screen.dart';
import 'package:cache/screens/videos/videos_screen.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:cache/actions/confirm.dart';
import 'package:cache/chat/answer_reports.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/navigation_action.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/model_search_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache_search/cache_search.dart' show CsNative, MapPlace, MapProgress, MapRoute, MapSearchResponse, VideoTarget;
import 'package:cache/layout/edit_home_screen.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/layout/modules_screen.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/regions/offroad_catalogue.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/regions/ui/region_actions.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/regions/ui/regions_list_sheet.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/download_confirm.dart' show confirmDownload, openStorageForSpace;
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/setup_card.dart';
import 'package:cache/search/app_search.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/screens/settings/appearance_page.dart';
import 'package:cache/screens/settings/assistant_page.dart';
import 'package:cache/screens/settings/catalogues_page.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:cache/screens/settings/notifications_page.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/screens/settings/source_page.dart';
import 'package:cache/screens/settings/storage_page.dart';
import 'package:cache/screens/settings/weather_page.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/weather/curated.dart';
import 'package:cache/app_state.dart' show ModelEntry;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources, catalogWith, fixture;
import '../test/chat_fakes.dart' show ScriptedBackend, say;
import '../test/nav_fakes.dart' show FakeBackend, FakeNavPosition, FakeSpeaker, fakeProgressJson, fakeRouteJson, fixAt;
import '../test/navigation_camera_test.dart' show NoSurface;
import '../test/video_fake.dart' show VideoFakeNative;
import '../test/video_player_screen_test.dart' show RecordingController;
import '../test/support/notebook_fake.dart';
import '../test/support/owner_state.dart';
import '../test/support/regions_fake.dart';
import '../test/support/settings_rig.dart';
import '../test/support/weather_fakes.dart';
import 'shot_kit.dart';

const _out = 'guide';
const _ratio = 2.0;

/// The part of the screen a picture is cut to (logical points: left, top, right, bottom), by id; written to crops.json.
final Map<String, List<double>> _crops = {};

/// The settings rig, with the app set to the light theme (the pictures are drawn in it, and Appearance says so).
Future<SettingsRig> _rig(
  WidgetTester tester, {
  ConnectionKind connection = ConnectionKind.wifi,
  LocationAccess locationAccess = LocationAccess.always,
  LocationPermissionState permission = LocationPermissionState.granted,
}) async {
  final r = await SettingsRig.create(tester, connection: connection, locationAccess: locationAccess, permission: permission);
  await tester.runAsync(() => r.app.setTheme(CacheThemeId.light));
  return r;
}

Future<OwnerState> _owner(WidgetTester tester, {bool legacyFiles = true}) async {
  final o = await OwnerState.boot(tester, legacyFiles: legacyFiles);
  await tester.runAsync(() => o.s.app.setTheme(CacheThemeId.light));
  return o;
}

/// Writes (with --update-goldens) the picture of the whole screen as guide/[id].png. With [crop], the picture is later cut to that
/// widget's box (a sheet or a dialog), grown by [pad] points.
Future<void> shot(WidgetTester tester, String id, {Finder? crop, double pad = 0}) async {
  await snap(tester, _out, id);
  if (crop != null) {
    final r = tester.getRect(crop.first);
    final s = tester.view.physicalSize / tester.view.devicePixelRatio;
    _crops[id] = [
      (r.left - pad).clamp(0, s.width).toDouble(),
      (r.top - pad).clamp(0, s.height).toDouble(),
      (r.right + pad).clamp(0, s.width).toDouble(),
      (r.bottom + pad).clamp(0, s.height).toDouble(),
    ];
  }
}

/// Lets timers and file work run, a few times, so a page has read what it shows.
Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// [page] on the phone, after the rig has set its own view size.
Future<void> show(WidgetTester tester, Widget page, {GlobalKey<ScaffoldMessengerState>? messenger, double height = 932}) async {
  phone(tester, size: Size(430, height), ratio: _ratio);
  await tester.pumpWidget(shotApp(page, messenger: messenger));
  await settle(tester);
}

/// The debug-only warning about a list tile on a coloured box (the app's Weather cards); the phone's release build does not make it.
void _ignoreDebugAsserts(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Finder get _sheet => find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material));
Finder get _dialog => find.descendant(of: find.byType(Dialog), matching: find.byType(Material));

void main() {
  setUpAll(() async {
    await loadShotFonts();
    openStorageForSpace = (_) {};
  });

  tearDownAll(() {
    final f = File('test_shots/guide/crops.json');
    final old = f.existsSync() ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>() : <String, dynamic>{};
    f.createSync(recursive: true);
    f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({...old, ..._crops}));
  });

  // ---- Settings -------------------------------------------------------------------------------------------

  testWidgets('settings, settings-maps, settings-maps-advanced', (tester) async {
    final o = await _owner(tester, legacyFiles: false);
    final r = o.s;
    await tester.runAsync(() async {
      File('${r.sources.zimsDir!.path}/wikivoyage_en_idaho.zim').openSync(mode: FileMode.write)
        ..truncateSync(180 << 20)
        ..closeSync();
      await r.sources.refresh();
      await r.storage.measure();
    });
    await show(tester, SettingsScreen(deps: r.deps));
    await shot(tester, 'settings');

    await show(tester, MapsPage(deps: r.deps));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, 'settings-maps');

    await tester.tap(find.byKey(const ValueKey('maps-advanced')));
    await settle(tester);
    await shot(tester, 'settings-maps-advanced');
    await o.dispose(tester);
  });

  testWidgets('settings-storage', (tester) async {
    final r = await _rig(tester);
    void file(Directory d, String name, int bytes) => File('${d.path}/$name').openSync(mode: FileMode.write)
      ..truncateSync(bytes)
      ..closeSync();
    file(r.libraryDir, 'wikivoyage_en_idaho.zim', 180 << 20);
    file(r.libraryDir, 'wikipedia_en_medicine.zim', 940 << 20);
    file(r.mapsDir, 'tiles.sqlite', 410 << 20);
    file(r.modelsDir, 'gemma-4-E2B-it-Q4_K_M.gguf', 1900 << 20);
    final leftovers = Directory('${r.dir.path}/leftovers')..createSync();
    file(leftovers, 'x.part', 38 << 20);
    await tester.runAsync(r.app.refreshModels);
    await tester.runAsync(r.sources.refresh);
    await show(tester, StoragePage(deps: r.deps));
    for (var i = 0; i < 40 && !r.storage.measured; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await settle(tester);
    await shot(tester, 'settings-storage');
    await r.dispose(tester);
  });

  testWidgets('settings-appearance, settings-credits, settings-notifications, quiet-hours', (tester) async {
    final r = await _rig(tester);
    await show(tester, AppearancePage(app: r.app));
    await shot(tester, 'settings-appearance');

    await show(tester, AboutPage(openUrl: (u) async {}, version: () async => '1.0.28 (28)'));
    await settle(tester);
    await shot(tester, 'settings-credits');

    await show(tester, NotificationsPage(deps: r.deps));
    await shot(tester, 'settings-notifications');

    await show(tester, QuietHoursPage(settings: r.settings));
    await shot(tester, 'quiet-hours');
    await r.dispose(tester);
  });

  testWidgets('settings-assistant', (tester) async {
    final r = await _rig(tester);
    await _gemma(tester, r);
    for (final t in ['Water from a stream', 'Treating burns', 'Route to Rock Creek']) {
      r.store.create(title: t);
    }
    r.chat.historyRevision.value++;
    await show(tester, AssistantPage(deps: r.deps, reports: AnswerReports(dirOverride: r.dir)));
    await settle(tester, rounds: 14);
    await shot(tester, 'settings-assistant');
    await r.dispose(tester);
  });

  testWidgets('settings-location-blocked', (tester) async {
    final r = await _rig(tester, permission: LocationPermissionState.deniedForever);
    await tester.runAsync(r.location.init);
    await show(tester, AssistantPage(deps: r.deps));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('use-my-location-row')), 200);
    await settle(tester);
    await shot(tester, 'settings-location-blocked');
    await r.dispose(tester);
  });

  testWidgets('settings-sharing', (tester) async {
    final r = await _rig(tester);
    r.sync.peers
      ..add({'id': 'peer1', 'name': 'Desk', 'linked': 1, 'last_seen': DateTime.now().millisecondsSinceEpoch - 120000, 'via': null, 'error': null})
      ..add({'id': 'peer2', 'name': 'Tablet', 'linked': 1, 'last_seen': DateTime.now().millisecondsSinceEpoch - 3600000, 'via': null, 'error': null});
    await show(tester, SharingPage(sharing: r.sharing));
    await tester.runAsync(() => r.sharing.setUp());
    await tester.runAsync(() => r.sharing.setShared(r.sharing.kinds.single, true));
    await settle(tester);
    await shot(tester, 'settings-sharing');
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });

  testWidgets('settings-weather, source-page, key-sheet, add-catalogue', (tester) async {
    final r = await _rig(tester);
    await tester.runAsync(() async {
      await r.weather.setRowOn(kCurated.first, true);
      await r.weather.setRowOn(kCurated[1], true);
      await r.weather.updateNow();
    });
    r.clock = r.clock.add(const Duration(hours: 1));
    await show(tester, WeatherPage(deps: r.deps));
    await tester.pumpAndSettle();
    await shot(tester, 'settings-weather');

    await tester.tap(find.byKey(const ValueKey('get-key-firms-viirs-near')));
    await tester.pumpAndSettle();
    await shot(tester, 'key-sheet', crop: _sheet);
    await tester.tapAt(const Offset(10, 60));
    await tester.pumpAndSettle();

    await tester.runAsync(() => r.weather.saveKey(r.weather.sourceById('firms-viirs-near')!, 'sample-key-0000'));
    await show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'));
    await tester.pumpAndSettle();
    await shot(tester, 'source-page');

    await show(tester, CataloguesPage(deps: r.deps));
    await tester.pumpAndSettle();
    await shot(tester, 'add-catalogue');
    await r.dispose(tester);
  });

  // ---- Home, Modules, Edit Home ---------------------------------------------------------------------------

  Future<void> homeRig(WidgetTester tester, _HomeRig h) async {
    h.r = await _rig(tester);
    h.layout = LayoutState(settingsDirOverride: h.r.dir);
    await tester.runAsync(h.layout.init);
    h.weather = _GuideWeather(h.r);
  }

  testWidgets('home, home-search, home-shortcut-menu, edit-home', (tester) async {
    final h = _HomeRig();
    await homeRig(tester, h);
    for (final m in [ModuleId.library, ModuleId.maps, ModuleId.notebooks, ModuleId.weather]) {
      h.layout.addShortcut(Shortcut.module(m));
    }
    h.layout.setBlockOn(HomeBlock.setup, false);
    final search = AppSearch([
      _Found('Library', Icons.menu_book_outlined, [('Water purification', 'Wikipedia', 0.9), ('Boiling water for safety', 'Survival manuals, p. 112', 0.7)]),
      _Found('Notebooks', Icons.book_outlined, [('Water cache restocked', 'Journal · Oct 27', 0.8)]),
      _Found('Places', Icons.place_outlined, [('Water tank', 'Saved place · 1.4 mi', 0.6)]),
      _Found('Maps', Icons.map_outlined, [('Rock Creek Water Gap', 'Dam · 2.1 mi', 0.5)]),
    ]);
    Widget home() => HomeScreen(
      layout: h.layout,
      weather: h.weather,
      search: search,
      onAsk: (_) {},
      onOpenSettings: () {},
      onOpenShortcut: (_) {},
      onOpenWeather: () {},
    );
    await show(tester, home());
    await shot(tester, 'home');

    await tester.enterText(find.byKey(const ValueKey('home-search')), 'water');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await shot(tester, 'home-search');

    await show(tester, home());
    await tester.longPress(find.byKey(const ValueKey('shortcut-module:maps')));
    await settle(tester);
    await shot(tester, 'home-shortcut-menu', crop: _sheet);

    await show(tester, EditHomeScreen(layout: h.layout));
    await shot(tester, 'edit-home');
    await tester.pumpWidget(const SizedBox());
    h.layout.dispose();
    await h.r.dispose(tester);
  });

  testWidgets('modules, modules-hold-menu', (tester) async {
    final h = _HomeRig();
    await homeRig(tester, h);
    await show(tester, ModulesScreen(layout: h.layout, app: h.r.app, onOpen: (_) {}));
    await shot(tester, 'modules');
    await tester.longPress(find.byKey(const ValueKey('module-videos')));
    await settle(tester);
    await shot(tester, 'modules-hold-menu', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
    h.layout.dispose();
    await h.r.dispose(tester);
  });

  testWidgets('home-setup-card', (tester) async {
    final h = _HomeRig();
    await homeRig(tester, h);
    final r = h.r;
    final regions = _Regions(r);
    regions.set([
      LocalRegion(
        id: 'us-id-twin-falls-county',
        name: 'Twin Falls County',
        routing: {'state': 'downloading', 'bytes': 50 << 20, 'done_bytes': 21 << 20},
        places: {'state': 'downloading', 'bytes': 12 << 20, 'done_bytes': 2 << 20},
      ),
    ]);
    await _gemma(tester, r);
    final setup = SetupCache(
      app: r.app,
      weather: h.weather,
      sources: r.sources,
      regions: regions,
      browse: r.browse,
      modelDownloads: ModelDownloads(app: r.app),
      chooseModel: (_) {},
      getArea: (_) {},
      turnOnWeather: (_) {},
      addLibrary: (_) {},
      openGuide: (_, _) {},
    );
    await show(tester, HomeScreen(layout: h.layout, setup: setup, weather: h.weather, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}));
    await tester.pumpAndSettle();
    await shot(tester, 'home-setup-card');
    await tester.pumpWidget(const SizedBox());
    h.layout.dispose();
    await r.dispose(tester);
  });

  // ---- Regions --------------------------------------------------------------------------------------------

  testWidgets('region-row, region-detail, regions-updates-tab', (tester) async {
    final o = await _owner(tester, legacyFiles: false);
    await show(tester, RegionsScreen(regions: o.regions, initialTab: 1));
    await tester.pump(const Duration(seconds: 5));
    await o.settle(tester);
    await shot(tester, 'region-row');

    await show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await o.settle(tester);
    await shot(tester, 'region-detail');

    // A county with its map, ready: the Updates tab lists its map with the date.
    final county = o.us['us-id-twin-falls-county']!;
    await tester.runAsync(() async {
      await o.catalogue.geometry(county);
      await o.regions.download(county, routing: true, map: true, anyway: true);
      o.core.finish('us-id-twin-falls-county');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await o.regions.refresh();
    });
    await show(tester, RegionsScreen(regions: o.regions, initialTab: 2));
    await o.settle(tester);
    await shot(tester, 'regions-updates-tab');
    await o.dispose(tester);
  });

  testWidgets('download-popup-new, regions-select', (tester) async {
    final o = await _owner(tester, legacyFiles: false);
    final space = Space(free: 103 * 1000 * 1000 * 1000, reserve: 20 * 1000 * 1000 * 1000);
    final jerome = o.us['us-id-jerome-county']!;
    final offer = o.regions.offer(jerome);
    await show(tester, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(
      onPressed: () => confirmDownload(c,
          title: 'Download ${jerome.name}?',
          summary: [partsSentence(map: offer.map, routing: offer.routing, places: offer.places, offroad: offer.offroad), sizeWords(offer.bytes)],
          bytes: offer.bytes,
          name: jerome.name,
          lines: const [],
          space: space),
      child: const Text('open'),
    )))));
    await tester.tap(find.text('open'));
    await o.settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, 'download-popup-new', crop: _dialog, pad: 8);

    await show(tester, Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showRegionsSheet(c, o.regions, lat: 42.56, lon: -114.46), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await o.settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('regions-select')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('region-us-id-jerome-county')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('region-us-id-twin-falls-county')));
    await tester.pump(const Duration(milliseconds: 500));
    await shot(tester, 'regions-select', crop: _sheet);
    await o.dispose(tester);
  });

  testWidgets('storage-regions', (tester) async {
    final s = await _rig(tester);
    final core = FakeRegions(tileDir: '${s.dir.path}/regions/tiles/2026-10');
    Directory(core.tileDir).createSync(recursive: true);
    final offroadWeb = FakeWeb()
      ..files['${kOffroadBaseUrl}current.json'] = utf8.encode(jsonEncode({
        'format': 1,
        'component': 'offroad',
        'base_url': kOffroadBaseUrl,
        'elevation': {'minzoom': 12, 'maxzoom': 12},
        'regions': [offroadPack('idaho', 'Idaho', [-118.0, 41.5, -110.3, 49.5], 300 << 20)],
      }));
    final catalogue = RegionCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: regionWeb().fetch);
    final regions = RegionsState(
      policy: s.policy,
      supportDir: () async => s.dir,
      catalogue: catalogue,
      maps: s.maps,
      opener: (_) async => core,
      offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${s.dir.path}/region-catalogue'), fetch: offroadWeb.fetch),
      packDownloader: _Packs(),
    );
    await tester.runAsync(() async {
      await s.engine.saveDefinition(File('../packages/cache_search/layers/mapterhorn.json').readAsStringSync());
      await regions.init();
      final us = await catalogue.shard('us');
      for (final id in ['us-id', 'us-id-twin-falls-county']) {
        await catalogue.geometry(us[id]!);
      }
      await regions.download(us['us-id-twin-falls-county']!, routing: true, map: false, offroad: true, anyway: true);
      await regions.download(us['us-id']!, routing: false, map: false, offroad: true, anyway: true);
      core.finish('us-id-twin-falls-county');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await regions.refresh();
    });
    await show(tester, RegionsScreen(regions: regions, initialTab: 1));
    await settle(tester);
    await shot(tester, 'storage-regions');
    await tester.pumpWidget(const SizedBox());
    regions.dispose();
    await s.dispose(tester);
  });

  // ---- Ask ------------------------------------------------------------------------------------------------

  Future<_AskRig> askRig(WidgetTester tester) async {
    final a = _AskRig();
    a.r = await _rig(tester);
    await _gemma(tester, a.r, two: true);
    a.layout = LayoutState(settingsDirOverride: a.r.dir);
    await tester.runAsync(a.layout.init);
    a.chat = a.r.chat..setBackend(ScriptedBackend([(_) => say('ok')]));
    a.chat.messages
      ..add(ChatMessage.user('How do I make water from a stream safe to drink?'))
      ..add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'Bring it to a rolling boil for one minute [1]. Above 6,500 feet, boil it for three minutes [2]. Let it cool before you drink it.'
        ..sources = const [
          NumberedResult(1, SourceResult(title: 'Water purification', snippet: 'Boiling kills germs: bring the water to a rolling boil for one minute.', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Water_purification')),
          NumberedResult(2, SourceResult(title: 'Boiling at altitude', snippet: 'Water boils at a lower temperature as you climb.', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Boiling_point')),
        ]);
    return a;
  }

  Widget askScreen(_AskRig a) => AskScreen(app: a.r.app, chat: a.chat, location: a.r.location, layout: a.layout, onOpenSource: (_) {}, onOpenNavigation: (_) {});

  testWidgets('ask, ask-sources, ask-plus-menu, ask-model-menu, ask-report', (tester) async {
    final a = await askRig(tester);
    await show(tester, askScreen(a), height: 600);
    await shot(tester, 'ask');

    // One source, opened: the Library article it came from.
    a.chat.messages.last
      ..text = 'Bring it to a rolling boil for one minute [1]. Let it cool before you drink it.'
      ..sources = [a.chat.messages.last.sources.first];
    await show(tester, askScreen(a), height: 650);
    await tester.tap(find.text('1 source'));
    await settle(tester);
    await shot(tester, 'ask-sources');

    await tester.tap(find.byKey(const ValueKey('ask-plus')));
    await settle(tester);
    await shot(tester, 'ask-plus-menu', crop: _sheet);
    await tester.tapAt(const Offset(10, 60));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('model-name')));
    await settle(tester);
    await shot(tester, 'ask-model-menu', crop: _sheet);
    await tester.tapAt(const Offset(10, 60));
    await settle(tester);

    await tester.ensureVisible(find.byKey(const ValueKey('report-answer')));
    await tester.tap(find.byKey(const ValueKey('report-answer')));
    await settle(tester);
    await shot(tester, 'ask-report', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
    a.layout.dispose();
    await a.r.dispose(tester);
  });

  testWidgets('ask-open-navigation, ask-confirm-card', (tester) async {
    final a = await askRig(tester);
    a.chat.messages
      ..clear()
      ..add(ChatMessage.user('Take me to the Rock Creek trailhead.'))
      ..add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'The Rock Creek trailhead is 15 miles east of you, about 24 minutes by road. The route is ready.'
        ..navigationActions = [NavigationAction(address: 'nav:r1', route: MapRoute.fromJson(fakeRouteJson(id: 'r1', name: 'Rock Creek trailhead')))]);
    await show(tester, askScreen(a), height: 520);
    await shot(tester, 'ask-open-navigation');

    a.chat.messages
      ..clear()
      ..add(ChatMessage.user('Add to my journal: swapped six water jugs at the shed.'))
      ..add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'I put up a card to add this to your Journal. Nothing is saved until you tap the button.'
        ..confirms = [
          ConfirmCard(
            confirmId: 'c1',
            toolCallId: 't1',
            action: 'notebook.add_journal_entry',
            title: 'Add to Journal',
            summary: const [MapEntry('title', 'Water jugs'), MapEntry('text', 'Swapped six water jugs at the shed.')],
            fields: const {},
          ),
        ]);
    await show(tester, askScreen(a), height: 600);
    await shot(tester, 'ask-confirm-card');
    await tester.pumpWidget(const SizedBox());
    a.layout.dispose();
    await a.r.dispose(tester);
  });

  testWidgets('chat-list, chat-menu', (tester) async {
    final a = await askRig(tester);
    final now = DateTime.now();
    int chatAt(String title, DateTime at) {
      final c = a.r.store.create(title: title);
      a.r.store.addMessage(c.id, role: 'user', content: 'question', message: {'role': 'user', 'content': 'question'});
      return c.id;
    }

    final pinned = chatAt('Water from a stream', now);
    chatAt('Treating burns', now);
    chatAt('Splinting a sprained ankle', now);
    chatAt('Route to Rock Creek', now);
    a.chat.setPinned(pinned, true);
    a.chat.historyRevision.value++;
    await show(tester, askScreen(a));
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await settle(tester);
    await shot(tester, 'chat-list', crop: find.byType(Drawer));

    await tester.longPress(find.text('Treating burns'));
    await settle(tester);
    await shot(tester, 'chat-menu', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
    a.layout.dispose();
    await a.r.dispose(tester);
  });

  // ---- Models ---------------------------------------------------------------------------------------------

  testWidgets('models-screen, hf-search', (tester) async {
    final r = await _rig(tester);
    await _gemma(tester, r);
    final downloads = ModelDownloads(app: r.app, hub: _Hub());
    ModelDownloads.shared = downloads;
    addTearDown(() => ModelDownloads.shared = null);
    final recs = RecommendedModels(
      builtIn: () async => jsonEncode({
        'format': 1,
        'models': [
          {'name': 'Gemma 4 E4B', 'repo': 'acme/gemma-4-E4B-it-GGUF', 'file': 'gemma-4-E4B-it-Q4_K_M.gguf', 'size': 3 << 30, 'sha256': null, 'kind': 'works_not_tuned', 'note': 'A good all-round model for most phones.'},
          {'name': 'Qwen3 14B', 'repo': 'acme/Qwen3-14B-GGUF', 'file': 'Qwen3-14B-Q4_K_M.gguf', 'size': 9 << 30, 'sha256': null, 'kind': 'works_not_tuned', 'note': 'Bigger and slower; needs a phone with a lot of memory.'},
        ],
      }),
      fetch: () async => throw const SocketException('offline'),
    );
    await show(tester, ModelsScreen(app: r.app, recommended: recs, memory: 8 << 30));
    await tester.pumpAndSettle();
    await shot(tester, 'models-screen');

    await show(tester, ModelFilesScreen(downloads: downloads, model: const HfModel(id: 'acme/gemma-4-E4B-it-GGUF', downloads: 120000), memory: 8 << 30));
    await tester.pumpAndSettle();
    await shot(tester, 'hf-search');
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    await r.dispose(tester);
  });

  // ---- Weather and Places ---------------------------------------------------------------------------------

  testWidgets('weather, weather-choose-place', (tester) async {
    final r = await _rig(tester);
    await tester.runAsync(() async {
      for (final i in [0, 1, 2]) {
        await r.weather.setRowOn(kCurated[i], true);
      }
    });
    final fetched = r.clock.subtract(const Duration(minutes: 50)).toIso8601String();
    r.liveCore.stored['openmeteo-forecast'] = {
      'fetched_at': fetched,
      'age': '50 minutes old',
      'expired': false,
      'items': [
        {'address': 'live:openmeteo-forecast/x/now', 'label': 'Now', 'fields': {'Temperature': '50 °F', 'Conditions': 'partly cloudy', 'Wind': '8 mph NW'}},
        {'address': 'live:openmeteo-forecast/x/2026-10-26', 'label': 'Mon 26 Oct', 'fields': {'High': '58 °F', 'Low': '37 °F', 'Conditions': 'partly cloudy', 'Rain chance': '10%'}},
        {'address': 'live:openmeteo-forecast/x/2026-10-27', 'label': 'Tue 27 Oct', 'fields': {'High': '55 °F', 'Low': '34 °F', 'Conditions': 'light rain', 'Rain chance': '60%'}},
        {'address': 'live:openmeteo-forecast/x/2026-10-28', 'label': 'Wed 28 Oct', 'fields': {'High': '49 °F', 'Low': '31 °F', 'Conditions': 'overcast', 'Rain chance': '20%'}},
      ],
    };
    r.liveCore.stored['nws-alerts-point'] = {
      'fetched_at': fetched,
      'age': '5 minutes old',
      'expired': false,
      'items': [
        {'address': 'live:nws-alerts-point/x/1', 'label': 'Red flag warning', 'fields': {'Until': 'Mon 9 PM', 'Area': 'Twin Falls County'}},
      ],
    };
    r.liveCore.stored['wfigs-incidents-near'] = {
      'fetched_at': fetched,
      'age': '20 minutes old',
      'expired': false,
      'items': [
        {'address': 'live:wfigs-incidents-near/x/1', 'label': 'East Fork fire', 'fields': {'Size': '266 acres', 'Contained': '60%', 'From the place': '31 mi N'}},
      ],
    };
    r.liveCore.stored['wfigs-perimeters-near'] = {
      'fetched_at': fetched,
      'age': '20 minutes old',
      'expired': false,
      'items': [
        {'address': 'live:wfigs-perimeters-near/x/none', 'label': 'No active fires', 'none_active': true, 'fields': {}},
      ],
    };
    await tester.runAsync(() async {
      await r.weather.updateNow();
      final here = (await r.weather.watchedPlaces()).first;
      await r.weather.viewFor(here);
    });
    WeatherTurnOn turnOn(List<MapPlace> found) => WeatherTurnOn(
      weather: r.weather,
      location: r.location,
      searchPlaces: (q) async => found,
      savePlace: (p) async {},
    );
    await show(tester, WeatherScreen(weather: r.weather, turnOn: turnOn(const []), onOpenSettings: () {}, onAsk: (_) {}));
    await settle(tester, rounds: 12);
    _ignoreDebugAsserts(tester);
    await shot(tester, 'weather');

    // The Choose a place sheet, from the empty state.
    final off = await _rig(tester);
    off.here = null;
    await show(tester, WeatherScreen(weather: off.weather, turnOn: WeatherTurnOn(
      weather: off.weather,
      location: off.location,
      searchPlaces: (q) async => const [
        MapPlace(id: 'place:osm:n1', type: 'place', name: 'Twin Falls', kind: 'City', address: 'Twin Falls County, ID', lat: 42.5629, lon: -114.4609),
        MapPlace(id: 'place:osm:n2', type: 'place', name: 'Twin Lakes', kind: 'Town', address: 'Kootenai County, ID', lat: 47.9, lon: -116.8),
        MapPlace(id: 'place:osm:n3', type: 'place', name: 'Twin Bridges', kind: 'Town', address: 'Madison County, MT', lat: 45.5, lon: -112.3),
      ],
      savePlace: (p) async {},
    )));
    await settle(tester, rounds: 10);
    await tester.tap(find.byKey(const ValueKey('weather-choose-place')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('weather-place-search')), 'twin');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    _ignoreDebugAsserts(tester);
    await shot(tester, 'weather-choose-place', crop: _sheet);
    _ignoreDebugAsserts(tester);
    await tester.pumpWidget(const SizedBox());
    await off.dispose(tester);
    await r.dispose(tester);
  });

  testWidgets('places-list, places-edit, place-alerts-sheet', (tester) async {
    final n = _NbRig();
    final book = await n.saved(tester);
    await n.place(tester, book, 'Home', 42.5607, -114.4623, color: 'green');
    await n.place(tester, book, 'Rally point 1', 42.5630, -114.4610, color: 'purple');
    await n.place(tester, book, 'Shoshone Falls lot', 42.5944, -114.4003, color: 'yellow');
    n.watched.add('place:home');
    await show(tester, NotebookScreen(deps: n.deps, notebookId: book.id));
    await tester.pumpAndSettle();
    await shot(tester, 'places-list');

    await tester.longPress(find.text('Home'));
    await tester.pumpAndSettle();
    await shot(tester, 'places-edit');

    await tester.dragUntilVisible(find.byKey(const ValueKey('weather-gear')), find.byType(ListView).last, const Offset(0, -200));
    await tester.tap(find.byKey(const ValueKey('weather-gear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('alert-mode-custom')));
    await tester.pumpAndSettle();
    await shot(tester, 'place-alerts-sheet', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
  });

  // ---- Notebooks ------------------------------------------------------------------------------------------

  testWidgets('notebooks, notebook-new, notebook-entry', (tester) async {
    final n = _NbRig();
    await n.start(tester);
    final g = await n.generator(tester);
    await tester.runAsync(() async {
      await n.nb.saveEntry(notebookId: n.nb.journal!.id, occurredAt: '2026-10-28T09:00:00-06:00', title: 'Water cache restocked', body: 'Swapped six jugs at the shed. Next check on the 12th.');
      await n.nb.saveEntry(notebookId: n.nb.journal!.id, occurredAt: '2026-10-27T16:12:00-06:00', title: 'Rally point', body: 'Meet at the lot if phones are down.');
      final family = await n.nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Family plan', fields: [], sort: NotebookSort.recent), map: false);
      await n.nb.saveEntry(notebookId: family.id, occurredAt: '2026-10-27T10:00:00-06:00', title: 'Where we meet', body: 'Blood type and **meeting places** for each of us.');
    });
    await show(tester, NotebooksScreen(deps: n.deps, templates: n.templates));
    await tester.pumpAndSettle();
    await shot(tester, 'notebooks');

    await tester.tap(find.text('New notebook'));
    await tester.pumpAndSettle();
    await shot(tester, 'notebook-new');

    await show(tester, NotebookScreen(deps: n.deps, notebookId: n.nb.journal!.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Water cache restocked'));
    await tester.pumpAndSettle();
    await shot(tester, 'notebook-entry');
    expect(g.name, 'Generator test');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('log-quick-add, notebook-edit, log-editor, markdown-cheatsheet', (tester) async {
    final n = _NbRig();
    await n.start(tester);
    final g = await n.generator(tester);
    await show(tester, NotebooksScreen(deps: n.deps, templates: n.templates));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('again-${g.id}')));
    await tester.pumpAndSettle();
    await shot(tester, 'log-quick-add', crop: _sheet);

    await tester.runAsync(() => n.nb.saveEntry(notebookId: g.id, occurredAt: '2026-10-26T10:00:00-06:00', values: {'f1': 25}, place: const NbPlace(lat: 42.5607, lon: -114.4623)));
    n.nb.privateSharing = _Included();
    await show(tester, NotebookEditor(notebook: n.nb, existing: g));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-private')));
    await tester.pumpAndSettle();
    await shot(tester, 'notebook-edit');

    await show(tester, NotebookEditor(notebook: n.nb, template: n.templates.byId('log')!));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('notebook-name')), 'Pump house check');
    await tester.tap(find.byKey(const ValueKey('add-field')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-label')), 'Run time');
    await tester.tap(find.text('Number'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-unit')), 'min');
    await tester.tap(find.byKey(const ValueKey('field-done')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-field')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-label')), 'Under load');
    await tester.tap(find.text('Yes/No'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('field-done')));
    await tester.pumpAndSettle();
    await shot(tester, 'log-editor');

    await show(tester, NotebookScreen(deps: n.deps, notebookId: n.nb.journal!.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Write an entry'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('markdown-help')));
    await tester.pumpAndSettle();
    await shot(tester, 'markdown-cheatsheet', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connections', (tester) async {
    final n = _NbRig();
    await n.start(tester);
    final dir = Directory.systemTemp.createTempSync('guide-conn');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = NotebookConnections(notebook: n.nb, dir: () async => dir);
    await tester.runAsync(c.init);
    await show(tester, ConnectionsScreen(connections: c, pickFolder: () async => null));
    await tester.pumpAndSettle();
    await shot(tester, 'connections');
    await tester.pumpWidget(const SizedBox());
  });

  // ---- Library --------------------------------------------------------------------------------------------

  testWidgets('library, library-add, library-own', (tester) async {
    final r = await _rig(tester);
    final sources = _ReadySources(Directory('${r.dir.path}/library-zims')..createSync());
    void zim(String name, int bytes) => File('${sources.zimsDir!.path}/$name').openSync(mode: FileMode.write)
      ..truncateSync(bytes)
      ..closeSync();
    zim('wikipedia_en_medicine.zim', 940 << 20);
    zim('wikivoyage_en_idaho.zim', 180 << 20);
    await tester.runAsync(sources.refresh);
    for (final z in sources.zims) {
      sources.ready.add(z.path);
      sources.ids[z.path] = z.fileName.hashCode.toRadixString(16).padLeft(8, '0');
      sources.titles[z.path] = z.fileName.contains('medicine') ? 'Wikipedia Medicine' : 'Wikivoyage Idaho';
    }
    final libs = _Libs(sources);
    libs.libraries = [
      LibraryItem(dir: Directory('${r.dir.path}/libraries/cache-guide'), size: 3 << 20),
      LibraryItem(dir: Directory('${r.dir.path}/libraries/field-manuals'), size: 22 << 20),
    ];
    Future<String> recorded(Uri u) async {
      if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
      if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
      return fixture('kiwix_entries_wikivoyage.xml');
    }

    final browse = BrowseState(sources: sources, libraries: libs, catalog: catalogWith(recorded), policy: r.policy, settingsDirOverride: r.dir, phoneLanguage: 'en');
    await tester.runAsync(browse.init);
    await show(tester, BrowseScreen(browse: browse, active: true));
    await settle(tester);
    await shot(tester, 'library');

    await show(tester, AddToLibraryScreen(browse: browse));
    await tester.pumpAndSettle();
    await shot(tester, 'library-add');

    await show(tester, LibrariesScreen(libraries: libs));
    await tester.pumpAndSettle();
    await shot(tester, 'library-own');
    await tester.pumpWidget(const SizedBox());
    browse.dispose();
    libs.dispose();
    await r.dispose(tester);
  });

  // ---- Videos ---------------------------------------------------------------------------------------------

  Future<VideoState> videoRig(WidgetTester tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('guide-video')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final v = VideoState(dirOverride: dir, nativeFactory: _guideVideoNative, tokens: MemoryTokenStore());
    await tester.runAsync(v.init);
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    return v;
  }

  testWidgets('videos-list, video-download', (tester) async {
    final v = await videoRig(tester);
    await show(tester, VideosScreen(video: v));
    await settle(tester);
    await shot(tester, 'videos-list');

    await show(tester, InstanceScreen(video: v, instance: v.instances.last));
    await settle(tester);
    await settle(tester);
    await tester.tap(find.text('Water purification at camp'));
    await settle(tester);
    await tester.tap(find.text('Download'));
    await settle(tester);
    await shot(tester, 'video-download', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
    v.dispose();
  });

  testWidgets('video-player', (tester) async {
    final c = RecordingController();
    await show(tester, PlayerScreen(
      target: VideoTarget(isLocal: true, uuid: 'sample-video', title: 'Water purification at camp', offsetS: 0, durationS: 60, location: 'offline.mp4', captions: const []),
      controllerFactory: (_) => c,
    ));
    await settle(tester);
    await shot(tester, 'video-player');
    await tester.pumpWidget(const SizedBox());
  });

  // ---- Maps (the map itself is a platform view and is not drawn) -------------------------------------------

  Future<_MapRig> mapRig(WidgetTester tester, {bool notebooks = false}) async {
    final before = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => NoSurface();
    addTearDown(() => MapLibrePlatform.createInstance = before);
    final m = _MapRig();
    m.r = await _rig(tester);
    m.backend = FakeBackend()
      ..onRoute = (to, mode, from) async => MapRoute.fromJson(fakeRouteJson(id: 'r-$mode', mode: mode.startsWith('offroad') ? 'walk' : mode, offroad: mode.startsWith('offroad'), name: 'Shoshone Falls Park'));
    m.gps = FakeNavPosition();
    m.nav = NavState(
      backend: m.backend,
      location: m.r.location,
      speaker: FakeSpeaker(),
      positionSource: m.gps,
      fmt: const Fmt(UnitSystem.imperial),
      searchDebounce: const Duration(milliseconds: 1),
      meaningDebounce: const Duration(milliseconds: 2),
    );
    m.r.location.publish(fixAt(42.5629, -114.4609, heading: 90));
    m.regions = _Regions(m.r);
    if (notebooks) {
      m.store = FakeNotebookBackend();
      m.notebooks = fakeNotebook(m.store!);
      await tester.runAsync(() async {
        await m.notebooks!.start();
        for (final (name, tpl) in [('Places', 'places'), ('Rally points', 'places'), ('Notes', 'notes'), ('Fuel log', 'notes'), ('Medical', 'notes'), ('Water', 'notes')]) {
          await m.notebooks!.saveNotebook(template: tpl, def: NotebookDef(name: name, fields: const [], sort: NotebookSort.recent));
        }
      });
    }
    return m;
  }

  Future<void> showMap(WidgetTester tester, _MapRig m) async {
    await show(tester, MapsScreen(
      location: m.r.location,
      maps: m.r.maps,
      nav: m.nav,
      themeId: CacheThemeId.light,
      regions: m.regions,
      notebooks: m.notebooks,
      onNewEntryAt: m.notebooks == null ? null : (_, _) {},
      glyphsLoader: () async => 'file:///test/fonts/{fontstack}/{range}.pbf',
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await settle(tester);
  }

  Future<void> endMap(WidgetTester tester, _MapRig m) async {
    await tester.pumpWidget(const SizedBox());
    m.nav.dispose();
    await m.r.dispose(tester);
  }

  const park = MapPlace(
    id: 'place:osm:w7',
    type: 'place',
    name: 'Shoshone Falls Park',
    kind: 'Park',
    category: 'park',
    address: '4155 Shoshone Falls Grade, Twin Falls, ID',
    lat: 42.5944,
    lon: -114.4003,
    distanceM: 6400,
    direction: 'E',
    phone: '+1 208 555 0142',
    hours: 'Dawn to dusk',
    summary: 'A waterfall on the Snake River, often called the Niagara of the West.',
    matched: 'name',
  );

  // One test for every Maps picture: the map screen is built once (a second one in the same run waits for its style for good).
  testWidgets('the Maps pictures', (tester) async {
    final m = await mapRig(tester, notebooks: true);
    await showMap(tester, m);
    await shot(tester, 'maps-find-me');

    m.nav.select(park);
    await settle(tester);
    await shot(tester, 'place-card');
    m.nav.clearSelection();

    m.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: [
      park,
      const MapPlace(id: 'place:osm:n8', type: 'place', name: 'Shoshone Falls Overlook', kind: 'Viewpoint', address: 'Twin Falls, ID', lat: 42.5951, lon: -114.4012, distanceM: 6500, direction: 'E', matched: 'name'),
      const MapPlace(id: 'place:osm:n9', type: 'place', name: 'Shoshone', kind: 'City', address: 'Lincoln County, ID', lat: 42.9366, lon: -114.4084, distanceM: 38000, direction: 'N', matched: 'name'),
    ]);
    await tester.tap(find.byKey(const ValueKey('map-search-field')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('map-search-field')), 'shoshone');
    await tester.pump(const Duration(milliseconds: 50));
    await settle(tester);
    await shot(tester, 'maps-search');
    m.nav.closeSearch();
    await settle(tester);

    await tester.tap(find.byTooltip('Layers'));
    await settle(tester);
    await shot(tester, 'layers-sheet', crop: _sheet);
    await tester.tapAt(const Offset(10, 60));
    await settle(tester);

    await tester.runAsync(() => m.nav.openDirections(park));
    await settle(tester);
    await shot(tester, 'directions-panel');

    await tester.runAsync(() => m.nav.setMode('offroad_foot'));
    await settle(tester);
    await shot(tester, 'directions-offroad');

    await tester.runAsync(() => m.nav.setMode('drive'));
    await settle(tester);
    final route = m.nav.route!;
    m.backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route.raw, 0.3));
    await tester.runAsync(() async {
      await m.nav.start();
      m.gps.controller.add(fixAt(42.5, -113.69, heading: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle(tester);
    await shot(tester, 'guidance');
    await tester.runAsync(() async => m.nav.end());
    await settle(tester);

    // The ring, with a route shown (so it offers Add stop), then the notebook ring after Save, then Measure.
    await tester.runAsync(() => m.nav.openDirections(park));
    await settle(tester);
    final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapLongClick!(const Point(215.0, 466.0), const LatLng(42.57, -114.45));
    await settle(tester);
    await shot(tester, 'map-ring');

    RingMenu ring() => tester.widget<RingMenu>(find.byKey(const ValueKey('ring-menu')));
    ring().onPick(const RingItem(id: 'save', label: 'Save', icon: Icons.book_outlined));
    await settle(tester);
    await shot(tester, 'map-notebook-ring');

    await tester.tapAt(const Offset(30, 200));
    await settle(tester);
    m.nav.cancelDirections();
    await settle(tester);
    map.onMapLongClick!(const Point(215.0, 466.0), const LatLng(42.57, -114.45));
    await settle(tester);
    ring().onPick(const RingItem(id: 'measure', label: 'Measure', icon: Icons.straighten));
    await settle(tester);
    for (final p in [const LatLng(42.572, -114.452), const LatLng(42.575, -114.447)]) {
      map.onMapClick!(const Point(215.0, 400.0), p);
      await settle(tester);
    }
    await shot(tester, 'map-measure');
    await endMap(tester, m);
  });
}

// ---- Sample data and fakes ----------------------------------------------------------------------------------

class _HomeRig {
  late SettingsRig r;
  late LayoutState layout;
  late _GuideWeather weather;
}

/// The weather Home shows: partly cloudy and 50 degrees, a warning and a fire nearby.
class _GuideWeather extends WeatherState {
  _GuideWeather(SettingsRig r)
    : super(
        settings: r.settings,
        policy: r.policy,
        core: r.liveCore,
        secrets: r.secrets,
        catalogueDir: () async => r.catalogueDir,
        liveDir: () async => r.liveDir,
        builtIns: () async => builtInDefinitions(),
      );

  @override
  Future<bool> needsTurnOn() async => false;

  @override
  Future<HomeWeather> homeCard() async => const HomeWeather(
    place: 'Where I am',
    temperature: '50 °F',
    conditions: 'partly cloudy',
    high: '58 °F',
    low: '37 °F',
    age: '1 hour old',
    alertsKnown: true,
    alerts: [
      HomeAlert(fire: false, label: 'Red flag warning', detail: 'Until 9 PM · Twin Falls County · National Weather Service'),
      HomeAlert(fire: true, label: 'East Fork fire', detail: '31 mi N · 266 acres · 60% contained'),
    ],
  );
}

/// One module's part of Home's search, with the results it is given.
class _Found implements AppSearchProvider {
  _Found(this.module, this.icon, this.rows);

  @override
  final String module;
  @override
  final IconData icon;
  final List<(String, String, double)> rows;

  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async => [
    for (final (title, detail, score) in rows) AppSearchResult(title: title, module: module, icon: icon, detail: detail, score: score, open: () {}),
  ];
}

/// The regions on the phone, as the picture sets them.
class _Regions extends RegionsState {
  _Regions(SettingsRig r)
    : super(policy: r.policy, supportDir: () async => r.dir, catalogue: RegionCatalogue(dir: () async => r.dir), maps: r.maps);

  List<LocalRegion> onPhone = [];

  @override
  List<LocalRegion> get local => onPhone;

  void set(List<LocalRegion> l) {
    onPhone = l;
    notifyListeners();
  }
}

/// The download of an off-road pack: the bytes written to the hidden file, at once.
class _Packs extends ZimDownloader {
  @override
  Future<DownloadResult> download({
    required Uri url,
    required File part,
    Uri? sha256Url,
    Uri? md5Url,
    String? expectedSha256,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) async {
    await part.writeAsBytes(utf8.encode('pack'));
    return DownloadResult(file: part, bytes: 4, verified: true, checksumKind: 'sha256');
  }
}

class _AskRig {
  late SettingsRig r;
  late LayoutState layout;
  late ChatController chat;
}

/// The model the phone has: Gemma 4 E2B, active (and a second model to switch to).
Future<void> _gemma(WidgetTester tester, SettingsRig r, {bool two = false}) async {
  final settingsFile = File('${r.dir.path}/settings.json');
  final settings = settingsFile.existsSync() ? (jsonDecode(settingsFile.readAsStringSync()) as Map).cast<String, dynamic>() : <String, dynamic>{};
  settings['names'] = {'gemma-4-E2B-it-Q4_K_M.gguf|3435973837': 'Gemma 4 E2B · Q4_K_M', 'Qwen3-8B-Q4_K_M.gguf|5027784704': 'Qwen3 8B · Q4_K_M'};
  settingsFile.writeAsStringSync(jsonEncode(settings));
  await tester.runAsync(r.app.init);
  final gemma = ModelEntry(path: '${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf', size: 3435973837);
  r.app.models = [gemma, if (two) ModelEntry(path: '${r.modelsDir.path}/Qwen3-8B-Q4_K_M.gguf', size: 5027784704)];
  r.app.active = gemma;
}

/// Hugging Face with no network: the files of one repository.
class _Hub extends HfHub {
  @override
  Future<List<HfFile>> ggufFiles(String repo) async => [
    HfFile(repo: repo, path: 'gemma-4-E4B-it-Q3_K_M.gguf', size: 2200 << 20),
    HfFile(repo: repo, path: 'gemma-4-E4B-it-Q4_K_M.gguf', size: 3 << 30),
    HfFile(repo: repo, path: 'gemma-4-E4B-it-Q6_K.gguf', size: 4300 << 20),
    HfFile(repo: repo, path: 'gemma-4-E4B-it-Q8_0.gguf', size: 7 << 30),
  ];
}

// ---- Notebooks ----

final DateTime _now = DateTime(2026, 10, 29, 16, 12);

Templates _templates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

const PlaceChoices _places = PlaceChoices(here: _hereNow, saved: _savedNone);
Future<({double lat, double lon})?> _hereNow() async => (lat: 42.5600, lon: -114.4600);
Future<List<NbPlace>> _savedNone() async => const [];

class _NbRig {
  final FakeNotebookBackend store = FakeNotebookBackend();
  late final NotebookState nb = fakeNotebook(store);
  final Templates templates = _templates();
  final PlaceAlerts alerts = PlaceAlerts.memory();
  final Set<String> watched = {'here'};

  PlaceNotebookDeps get pd => PlaceNotebookDeps(
    watched: watched.contains,
    setWatched: (id, on) => on ? watched.add(id) : watched.remove(id),
    alerts: alerts,
    placesChanged: () async {},
    alertSetting: () => 'Serious only, from Notifications',
    alertKinds: () => const ['alerts', 'fire', 'earthquakes', 'hydrology'],
    regions: () async => const [(id: 'region:Idaho', name: 'Idaho')],
    hereOnMap: () => true,
    setHereOnMap: (_) {},
    // The map is a platform view: the space is left empty, as in the Maps tests.
    map: (context, pin, onPick) => const SizedBox.shrink(),
  );

  NotebookDeps get deps => NotebookDeps(notebook: nb, places: _places, placesDeps: pd, now: () => _now);

  Future<void> start(WidgetTester tester) => tester.runAsync(nb.start).then((_) {});

  Future<Notebook> saved(WidgetTester tester) async {
    await start(tester);
    return (await tester.runAsync(nb.ensureSavedPlaces))!;
  }

  Future<NbEntry> place(WidgetTester tester, Notebook book, String name, double lat, double lon, {String? color}) async => (await tester.runAsync(() => nb.saveEntry(
    notebookId: book.id,
    occurredAt: '2026-10-27T10:00:00-06:00',
    title: name,
    place: NbPlace(lat: lat, lon: lon),
    props: {'color': ?color, 'on_map': true},
  )))!;

  /// The Generator test starter log, with one entry four days ago.
  Future<Notebook> generator(WidgetTester tester) async {
    final t = templates.starters.firstWhere((s) => s.id == 'starter.generator_test');
    return (await tester.runAsync(() async {
      final log = await nb.saveNotebook(template: t.template, def: t.def, templateRef: t.ref, map: false);
      await nb.saveEntry(notebookId: log.id, occurredAt: '2026-10-25T16:12:00-06:00', values: {'f1': 20, 'f2': true, 'f3': 'Half'});
      return nb.notebook(log.id)!;
    }))!;
  }
}

class _Included implements PrivateSharing {
  final Set<String> ids = {};

  @override
  bool included(String notebookId) => ids.contains(notebookId);

  @override
  Future<void> setIncluded(String notebookId, bool on) async {
    if (on) {
      ids.add(notebookId);
    } else {
      ids.remove(notebookId);
    }
  }
}

/// Sources whose search core is up (the add buttons of "Your own library" work only then).
class _ReadySources extends FakeSources {
  _ReadySources(super.dir);

  @override
  bool get coreReady => true;
}

/// The libraries on the phone, as the picture names them (no search core): the guide that ships in the app, and one the person added.
class _Libs extends LibrariesState {
  _Libs(SourcesState s) : super(sources: s);

  bool _guide(LibraryItem l) => l.folderName == 'cache-guide';

  @override
  String titleOf(LibraryItem l) => _guide(l) ? 'Cache guide' : 'Field manuals';

  @override
  String? idOf(LibraryItem l) => _guide(l) ? kGuideLibraryId : 'field-manuals';

  @override
  int docsOf(LibraryItem l) => _guide(l) ? 214 : 38;

  @override
  LibraryPhase phaseOf(LibraryItem l) => LibraryPhase.ready;

  @override
  double? indexFraction(LibraryItem l) => null;
}

/// The video connector's stand-in, with the sample video named for the guide.
class _GuideVideoNative extends VideoFakeNative {
  @override
  String? video(int handle, String op, String requestJson) => super
      .video(handle, op, requestJson)
      ?.replaceAll('Big Clive', 'Idaho Field Notes')
      .replaceAll('big-clive', 'idaho-field-notes')
      .replaceAll('Merry Christmas', 'Water purification at camp');
}

CsNative _guideVideoNative() => _GuideVideoNative();

class _MapRig {
  late SettingsRig r;
  late FakeBackend backend;
  late FakeNavPosition gps;
  late NavState nav;
  late _Regions regions;
  FakeNotebookBackend? store;
  NotebookState? notebooks;
}

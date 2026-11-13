// The Cache guide's screenshots: one picture per id in tools/guide/shots.txt, drawn by the app's own widgets with sample data, in
// the light theme, on a 430 x 932 phone at 2x. The sample place of the maps, the saved places, the weather and the chats is Arches
// National Park (guide_sample.dart); the region pictures keep their earlier sample region. A test cannot draw a map (MapLibre is
// a platform view), so the Maps pictures and the place form show the real map behind the screen, rendered from the scene this
// test writes (guide_map_kit.dart).
// Made by the Renders workflow with guide=true (tools/guide/README.md, "Making the pictures"): it runs this test once with
// GUIDE_MAPS=export to write the scenes, renders them, and runs it again to draw the pictures (pictures and crops.json in
// test_shots/guide/). tools/guide/make_shots.py then resizes them into app/assets/guide/shots.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Point;
import 'dart:typed_data';

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
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition, LatLng, MapLibreMap, MapLibrePlatform;
import 'package:cache/maps/maps_state.dart' show FollowMode;
import 'package:cache/maps/palette/map_palette.dart' show mapPaletteFor;
import 'package:cache/maps/ui/place_map.dart' show kPlaceZoom;
import 'package:cache/maps/style/style_generator.dart' show kMeasureSource, kNotebookSource, kPinSource;
import 'package:cache/nav/elevation/route_elevation.dart' show RouteElevation;
import 'package:cache/nav/guidance_camera.dart' show guidanceAnchor;
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/notebook/notebook_map.dart' show PinLook;
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/pin_image.dart' show PinImages, PinStyle, pinImageRatio;
import 'package:cache/notebook/places.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/notebook/sync/folder.dart' show FolderFile, SyncFolder;
import 'package:cache/notebook/sync/sync_engine.dart' show SyncKind;
import 'package:cache/screens/notebooks/entry_editor.dart' show EntryEditor;
import 'package:cache/notebook/templates.dart';
import 'package:cache/screens/libraries_screen.dart';
import 'package:cache/screens/notebooks/connections_screen.dart';
import 'package:cache/screens/notebooks/notebook_editor.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/notebooks_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart' show PlaceNotebookDeps;
import 'package:cache/screens/videos/instance_screen.dart';
import 'package:cache/screens/videos/instance_sheet.dart';
import 'package:cache/screens/videos/player_screen.dart';
import 'package:cache/screens/videos/videos_screen.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/screens/weather_turn_on.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_prefs.dart';
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
import 'package:cache/screens/ask_off.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/model_search_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache_search/cache_search.dart' show CsNative, DownloadedCaption, GeoPoint, MapPlace, MapRoute, MapSearchResponse, SearchResponse, VideoTarget;
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
import 'package:cache/search/app_search_providers.dart' show LibrarySearchProvider;
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/pdf/index/pdf_index_app.dart' show pdfIndexShared;
import 'package:cache/pdf/index/pdf_index_core.dart' show PdfIndexCoreMissing;
import 'package:cache/pdf/index/pdf_index_state.dart' show PdfIndexState, PdfPart, PdfPartPhase, PdfZimRef;
import 'package:cache/pdf/pdf_reader_screen.dart' show PdfReaderScreen;
import 'package:cache/pdf/pdf_source.dart' show PdfFileSource;
import 'package:cache/settings/space.dart';
import 'package:cache/settings/data_kinds.dart' show DataKind;
import 'package:cache/sharing/sharing_state.dart' show SharingState;
import 'package:cache/weather/weather_state.dart';
import 'package:cache/screens/settings/about_pages.dart';
import 'package:cache/screens/settings/appearance_page.dart';
import 'package:cache/screens/settings/assistant_page.dart';
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
import 'package:image/image.dart' as img;

import '../test/browse/fakes.dart' show FakeSources, catalogWith, fixture;
import '../test/chat_fakes.dart' show ScriptedBackend, say;
import '../test/nav_fakes.dart' show FakeBackend, FakeNavPosition, FakeSpeaker, fakeRouteJson, fixAt;
import '../test/video_fake.dart' show VideoFakeNative, savedManifest, seededVideoNative;
import '../test/video_player_fakes.dart' show RecordingController, kKnotCues, kKnotCuesEs, writeCaption;
import '../test/support/pdf_test_kit.dart' show readerDone;
import '../test/support/pdfium_for_tests.dart' show pdfiumForTests;
import '../test/support/sample_pdf.dart' show sampleHandbook;
import '../test/support/notebook_fake.dart';
import '../test/support/owner_state.dart';
import '../test/support/regions_fake.dart';
import '../test/support/sync_fake.dart' show FakeSync;
import '../test/support/settings_rig.dart';
import '../test/support/weather_fakes.dart';
import '../test/support/weather_screen_kit.dart' show dayItem, nowItem, nwsAlert, storedAnswer;
import 'guide_map_kit.dart';
import 'guide_sample.dart';
import 'shot_kit.dart';

const _out = 'guide';
const _ratio = 2.0;

/// The part of the screen a picture is cut to (logical points: left, top, right, bottom), by id; written to crops.json.
final Map<String, List<double>> _crops = {};

/// What the place form's small map takes from the app's one map state: the style, with the guide's layers on, and the pin style.
/// The Maps test keeps them for the places test after it: a second map state in the same run would wait for its style for good
/// (the style's templates are read once, in the first test that asks for them).
String? _formMapStyle;
PinStyle? _formPinStyle;

/// The settings rig, with the app set to the light theme (the pictures are drawn in it, and Appearance says so).
Future<SettingsRig> _rig(
  WidgetTester tester, {
  ConnectionKind connection = ConnectionKind.wifi,
  LocationAccess locationAccess = LocationAccess.always,
  LocationPermissionState permission = LocationPermissionState.granted,
  List<Map<String, dynamic>> publishedLayers = const [],
}) async {
  final r = await SettingsRig.create(tester, connection: connection, locationAccess: locationAccess, permission: permission, publishedLayers: publishedLayers);
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
    await pdfiumForTests();
    openStorageForSpace = (_) {};
    GuideMaps.startRun();
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
    // Search indexes are being made in the background: the one quiet line at the foot of Settings.
    final indexing = _ShotIndexing('Getting search ready · 3 of 12 done');
    addTearDown(indexing.dispose);
    final h = r.hub;
    r.hub = SettingsHub(
      settings: h.settings,
      policy: h.policy,
      webSearch: h.webSearch,
      storage: h.storage,
      weather: h.weather,
      sharing: h.sharing,
      regions: h.regions,
      indexing: indexing,
      openUrl: h.openUrl,
    );
    await show(tester, SettingsScreen(deps: r.deps), height: 1000);
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
    // Tall enough for "Advanced" (Background indexing) at the foot of the page.
    await show(tester, StoragePage(deps: r.deps), height: 1160);
    for (var i = 0; i < 40 && !r.storage.measured; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await settle(tester);
    await shot(tester, 'settings-storage');
    await r.dispose(tester);
  });

  testWidgets('settings-indexing-speed', (tester) async {
    final r = await _rig(tester);
    await show(tester, StoragePage(deps: r.deps), height: 1160);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('storage-advanced')));
    await tester.pumpAndSettle();
    expect(find.byType(IndexingSpeedPage), findsOneWidget);
    await shot(tester, 'settings-indexing-speed');
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
    for (final t in ['Water from a stream', 'Treating burns', 'Route to Delicate Arch']) {
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
    // The app's kinds (main.dart's dataKinds, with folders here): Library and Notebooks ticked.
    Directory folder(String name, Map<String, int> files) {
      final d = Directory('${r.dir.path}/share-$name')..createSync(recursive: true);
      for (final f in files.entries) {
        File('${d.path}/${f.key}').openSync(mode: FileMode.write)
          ..truncateSync(f.value)
          ..closeSync();
      }
      return d;
    }

    final zims = folder('library', {'wikivoyage_en_idaho.zim': 180 << 20, 'wikipedia_en_medicine.zim': 940 << 20});
    final models = folder('models', {'gemma-4-E2B-it-Q4_K_M.gguf': 3200 << 20});
    final notebooks = folder('notebooks', {for (var i = 1; i <= 12; i++) 'Journal 2026-10-$i.md': 2 << 10});
    final sync = _CountingSync()..peers.addAll(r.sync.peers);
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: [
        DataKind(id: 'library', label: 'Library', icon: Icons.menu_book_outlined, shared: () => {'library': zims}),
        DataKind(id: 'models', label: 'Models', icon: Icons.memory, shared: () => {'models': models}),
        DataKind(id: 'notebooks', label: 'Notebooks', icon: Icons.book_outlined, shared: () => {'notebooks': notebooks}),
      ],
      deviceName: 'Android device',
      opener: (_) async => sync,
    );
    await show(tester, SharingPage(sharing: sharing));
    await tester.runAsync(() => sharing.setUp());
    await tester.runAsync(() => sharing.setShared(sharing.kinds.first, true));
    await tester.runAsync(() => sharing.setShared(sharing.kinds[2], true));
    await settle(tester);
    await shot(tester, 'settings-sharing');
    await tester.pumpWidget(const SizedBox());
    sharing.dispose();
    await r.dispose(tester);
  });

  testWidgets('settings-weather, source-page, key-sheet', (tester) async {
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

    // The watch list (1.0.29) sits above the sources: the row with Get key is further down the page.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('get-key-firms-viirs-near')), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('get-key-firms-viirs-near')));
    await tester.pumpAndSettle();
    await shot(tester, 'key-sheet', crop: _sheet);
    await tester.tapAt(const Offset(10, 60));
    await tester.pumpAndSettle();

    await tester.runAsync(() => r.weather.saveKey(r.weather.sourceById('firms-viirs-near')!, 'sample-key-0000'));
    await show(tester, SourcePage(deps: r.deps, sourceId: 'firms-viirs-near'), height: 1000);
    await tester.pumpAndSettle();
    await shot(tester, 'source-page');

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
      _Found('Maps', Icons.map_outlined, [('Water point', 'Drinking water · 2.1 mi', 0.5)]),
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
    await _gemma(tester, h.r);
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
    // The row's speed is measured on the real clock (two seconds of data), so the stalled download's "Waiting for the server"
    // comes after a varying wait: wait for it, so every redraw shows the same row.
    await _until(tester, find.textContaining('Waiting for the server'), max: 400);
    await shot(tester, 'region-row');

    await show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await o.settle(tester);
    await shot(tester, 'region-detail');

    // A county with its map, ready: the Updates tab lists its map with the date.
    final county = o.us['us-id-twin-falls-county']!;
    o.s.engine.clock = () => _shotClock;
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
      // a fixed storage, so the region's space check never depends on the machine drawing the pictures
      spaceOf: (_) => const Space(free: 200 << 30, reserve: 20 << 30),
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

  // The app's Ask has "Need help now?" in its top bar (1.0.29); the sheet itself is not shown here.
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

  testWidgets('ask-no-model', (tester) async {
    final r = await _rig(tester);
    // No model on the device: Ask's page says so, with the saved chats under it (they open read-only).
    for (final (title, q, ans) in [
      ('Treating a burn', 'How do I treat a burn?', 'Cool the burn under cool running water for 20 minutes.'),
      ('Water from a stream', 'How do I make stream water safe?', 'Bring it to a rolling boil for one minute.'),
      ('Signals for help', 'What is the signal for help?', 'Three of anything: three blasts on a whistle, three fires.'),
    ]) {
      final c = r.store.create(title: title);
      r.store.addMessage(c.id, role: 'user', content: q, message: {'role': 'user', 'content': q});
      r.store.addMessage(c.id, role: 'assistant', content: ans, message: {'role': 'assistant', 'content': ans});
    }
    r.chat.historyRevision.value++;
    await show(tester, AskOffPage(app: r.app, chat: r.chat, onChooseModel: () {}, onOpenChat: (_) {}));
    await settle(tester);
    expect(find.text('Treating a burn'), findsOneWidget);
    await shot(tester, 'ask-no-model');
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });

  testWidgets('ask-open-navigation, ask-confirm-card', (tester) async {
    final a = await askRig(tester);
    a.chat.messages
      ..clear()
      ..add(ChatMessage.user('Take me to the Delicate Arch trailhead.'))
      ..add(ChatMessage.assistant()
        ..phase = TurnPhase.done
        ..text = 'The Delicate Arch trailhead is 2 miles east of you, about 4 minutes by road. The route is ready.'
        ..navigationActions = [NavigationAction(address: 'nav:r1', route: MapRoute.fromJson(fakeRouteJson(id: 'r1', name: 'Delicate Arch trailhead')))]);
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
    chatAt('Route to Delicate Arch', now);
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
    // Monday noon in the park, updated twelve minutes ago: the forecast for sixteen days, one warning in force and one fire far
    // off. Each item is written as its source lists it (the field names are the sources' own: weather_screen_kit.dart, which
    // the Weather screen's own tests use). The warning and the fire are the ones on Home's card; the fire is made up.
    final shown = r.clock, updated = shown.subtract(const Duration(minutes: 12));
    r.clock = updated;
    await tester.runAsync(() async {
      for (final i in [0, 1, 2]) {
        await r.weather.setRowOn(kCurated[i], true);
      }
    });
    r.liveCore.stored['openmeteo-forecast'] = storedAnswer(shown, updated, [
      nowItem(updated, temperature: 50, feels: 46, wind: '8 mph NW, gusts 15 mph', conditions: 'partly cloudy'),
      for (final (n, (conditions, high, low, rain)) in _forecastDays.indexed)
        dayItem(DateTime(updated.year, updated.month, updated.day + n), conditions, high, low, rain, precipitation: rain >= 45 ? '0.1 in over 5 h' : '0.0 in over 0 h', windMax: 9 + n),
    ]);
    r.liveCore.stored['nws-alerts-point'] = storedAnswer(shown, updated, [
      nwsAlert('rf1', 'Red Flag Warning', 'severe', updated.subtract(const Duration(hours: 3)), DateTime(updated.year, updated.month, updated.day, 21), 'Grand County'),
    ]);
    r.liveCore.stored['wfigs-incidents-near'] = storedAnswer(shown, updated, [
      {
        'address': 'live:wfigs-incidents-near/x/f1',
        'label': 'East Fork fire',
        'fields': {'Size': '266 acres', 'Contained': '60%', 'From the place': '31 mi N', 'County': 'Grand'},
        'distances': {
          'From the place': {'km': 31 * 1.609344, 'inside': false},
        },
      },
    ]);
    r.liveCore.stored['wfigs-perimeters-near'] = storedAnswer(shown, updated, const []);
    await tester.runAsync(() => r.weather.updateNow());
    r.clock = shown;
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
        MapPlace(id: 'place:osm:n1', type: 'place', name: 'Moab', kind: 'City', address: 'Grand County, UT', lat: 38.5733, lon: -109.5498),
        MapPlace(id: 'place:osm:n2', type: 'place', name: 'Monticello', kind: 'City', address: 'San Juan County, UT', lat: 37.8714, lon: -109.3429),
        MapPlace(id: 'place:osm:n3', type: 'place', name: 'Montrose', kind: 'City', address: 'Montrose County, CO', lat: 38.4783, lon: -107.8762),
      ],
      savePlace: (p) async {},
    )));
    await settle(tester, rounds: 10);
    await tester.tap(find.byKey(const ValueKey('weather-choose-place')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('weather-place-search')), 'mo');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    _ignoreDebugAsserts(tester);
    await shot(tester, 'weather-choose-place', crop: _sheet);
    _ignoreDebugAsserts(tester);
    await tester.pumpWidget(const SizedBox());
    await off.dispose(tester);
    await r.dispose(tester);
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

    await tester.tap(find.byKey(const ValueKey('notebooks-add')));
    await tester.pumpAndSettle();
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

    await tester.runAsync(() => n.nb.saveEntry(notebookId: g.id, occurredAt: '2026-10-26T10:00:00-06:00', values: {'f1': 25}, place: NbPlace(lat: GuideSample.here.lat, lon: GuideSample.here.lon)));
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
    final c = NotebookConnections(notebook: n.nb, dir: () async => dir, clock: () => _shotClock);
    await tester.runAsync(c.init);
    // An Obsidian vault connected on a phone: the line that Obsidian syncs only while it is open.
    final vault = Directory('${dir.path}/Field notes')..createSync();
    final err = await tester.runAsync(() => c.connect(SyncKind.obsidian, vault.path, display: 'Field notes'));
    expect(err, isNull);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await show(tester, ConnectionsScreen(connections: c, pickFolder: () async => null, phone: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('obsidian-phone-note')), findsOneWidget);
    await shot(tester, 'connections');
    await tester.pumpWidget(const SizedBox());
  });

  // ---- Import by tag (Obsidian) ---------------------------------------------------------------------------

  /// Notebooks with an Obsidian vault connected (a folder in memory), [notes] in the vault before the first sync.
  Future<(NotebookState, _MemFolder, NotebookConnections)> tagRig(WidgetTester tester, {Map<String, String> notes = const {}}) async {
    final nb = fakeNotebook(FakeNotebookBackend());
    final mem = _MemFolder()..text.addAll(notes);
    final dir = Directory.systemTemp.createTempSync('guide-tagsync');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = NotebookConnections(notebook: nb, dir: () async => dir, folderFor: (_) => mem, clock: () => _shotClock);
    await tester.runAsync(() async {
      await nb.start();
      await nb.saveNotebook(template: 'notes', def: const NotebookDef(name: 'Camping trip', fields: [], sort: NotebookSort.recent));
      await c.init();
      await c.connect(SyncKind.obsidian, '/storage/Vault', display: 'Vault');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c.syncAll();
      while (c.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    return (nb, mem, c);
  }

  testWidgets('import-tag-row, import-tag-sheet', (tester) async {
    final (_, _, c) = await tagRig(tester);
    await show(tester, ConnectionsScreen(connections: c, pickFolder: () async => null, phone: true));
    await settle(tester);
    expect(find.byKey(const ValueKey('import-tag-obsidian')), findsOneWidget);
    await shot(tester, 'import-tag-row', crop: find.byKey(const ValueKey('connection-obsidian')), pad: 8);

    await tester.tap(find.byKey(const ValueKey('import-tag-obsidian')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('import-tag-field')), '#camping');
    await settle(tester);
    await shot(tester, 'import-tag-sheet', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stop-syncing-note, note-sync-off', (tester) async {
    final (nb, mem, c) = await tagRig(tester, notes: {'Trips/Camping list.md': '---\ntags:\n  - cachesync/Camping-trip\n---\nWater filter, stove, two fuel cans.\n'});
    final id = RegExp(r'cache_id: (\S+)').firstMatch(mem.text['Trips/Camping list.md']!)!.group(1)!;
    Future<Widget> editor() async {
      final e = (await tester.runAsync(() => nb.entry(id)))!;
      return EntryEditor(notebook: nb, book: nb.notebook(e.notebookId)!, places: PlaceChoices.none, entry: e, connections: c, now: () => DateTime(2026, 10, 29, 17, 2));
    }

    await show(tester, await editor());
    await tester.tap(find.byKey(const ValueKey('editor-menu')));
    await settle(tester);
    expect(find.text('Stop syncing this note'), findsOneWidget);
    await shot(tester, 'stop-syncing-note');

    await tester.tap(find.text('Stop syncing this note'));
    await settle(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('stop-sync-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester, rounds: 20);
    // The entry opened again (no snackbar): its "Not syncing with Obsidian" mark.
    await show(tester, await editor());
    expect(find.byTooltip('Not syncing with Obsidian'), findsOneWidget);
    await shot(tester, 'note-sync-off');
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
    // Wikipedia Medicine's PDFs are being made searchable (the row's note), as on a phone soon after adding it.
    final pdfs = _ShotPdfIndex(r.dir, {'wikipedia_en_medicine.zim': const PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 340)});
    pdfIndexShared = pdfs;
    addTearDown(() {
      pdfIndexShared = null;
      pdfs.dispose();
    });
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
    // Search indexes are being made: the overview line and bar at the top of the Library (the same one as in Settings).
    final medicineId = sources.ids.entries.firstWhere((e) => e.key.contains('medicine')).value;
    final libraryIndexing = _ShotIndexing('Getting search ready · 3 of 12 done', shown: [
      IndexItem(key: 'zim-pdf/$medicineId', state: IndexState.running, title: 'Wikipedia Medicine', progress: (340, 5768)),
    ]);
    indexSchedulerShared = libraryIndexing;
    addTearDown(() {
      indexSchedulerShared = null;
      libraryIndexing.dispose();
    });
    await show(tester, BrowseScreen(browse: browse, active: true));
    await settle(tester);
    await shot(tester, 'library');
    indexSchedulerShared = null;

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

  /// Videos with saved videos from two channels (their pictures drawn here) and one site.
  Future<VideoState> savedVideoRig(WidgetTester tester, _VideoPictures p) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('guide-videos')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    Map<String, dynamic> cap(String lang, String label, {bool auto = false}) =>
        {'language': lang, 'label': label, 'automatic': auto, 'path': '${p.dir.path}/captions-$lang.vtt'};
    final saved = [
      savedManifest(uuid: 'knots', title: 'Knots every camper should know', channel: 'Field Skills', at: '2026-10-03T10:00:00Z', durationS: 730, captions: [cap('en', 'English'), cap('es', 'Spanish', auto: true)], thumb: p.thumbs['knots']),
      savedManifest(uuid: 'fire', title: 'Fire without matches', channel: 'Field Skills', at: '2026-10-01T10:00:00Z', size: 310 << 20, durationS: 580, captions: [cap('en', 'English')], thumb: p.thumbs['fire']),
      savedManifest(uuid: 'splint', title: 'A splint from a stick', channel: 'Medical Basics', at: '2026-10-02T10:00:00Z', size: 96 << 20, durationS: 312, captions: [cap('en', 'English')], thumb: p.thumbs['splint']),
      savedManifest(uuid: 'burns', title: 'Treating a burn', channel: 'Medical Basics', at: '2026-09-28T10:00:00Z', size: 140 << 20, durationS: 401, thumb: p.thumbs['burns']),
    ];
    final v = VideoState(
      dirOverride: dir,
      nativeFactory: seededVideoNative(saved),
      tokens: MemoryTokenStore(),
      prefs: VideoPrefs(),
      spaceOf: () => const Space(free: 40 << 30, reserve: 0),
    );
    await tester.runAsync(v.init);
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    addTearDown(v.dispose);
    return v;
  }

  testWidgets('videos-list', (tester) async {
    final p = _videoPictures();
    final v = await savedVideoRig(tester, p);
    v.tasks.add(
      DownloadTask(instance: 'example.org', uuid: 'water', title: 'Purifying water in the field', choice: '480', label: '480p', expectedSize: 412 << 20)
        ..done = 160 << 20
        ..total = 412 << 20,
    );
    await show(tester, VideosScreen(video: v));
    await _precache(tester, p);
    await shot(tester, 'videos-list');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('video-download', (tester) async {
    final v = await videoRig(tester);
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
    final p = _videoPictures();
    final c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
    await show(tester, _knots(p, c, prefs: VideoPrefs()..captions = 'en'));
    await _precache(tester, p);
    c.at(const Duration(seconds: 14));
    await tester.pump();
    // The gear's sheet: Speed, Quality and Captions over the playing video.
    await tester.tap(find.byKey(const ValueKey('player-settings')));
    await tester.pumpAndSettle();
    await shot(tester, 'video-player');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('video-transcript', (tester) async {
    final p = _videoPictures();
    final c = RecordingController(duration: const Duration(seconds: 730), size: const Size(1280, 720));
    // The smallest window with the transcript beside the video (kTranscriptMinWidth by kTranscriptMinHeight), a computer's window.
    phone(tester, size: const Size(960, 640), ratio: _ratio);
    await tester.pumpWidget(shotApp(_knots(p, c, prefs: VideoPrefs()..captions = 'en'), insets: EdgeInsets.zero));
    await settle(tester);
    await _precache(tester, p);
    c.at(const Duration(seconds: 14));
    await tester.pump();
    // The pane reads the caption file outside the test's clock.
    await _until(tester, find.byKey(const ValueKey('player-transcript')));
    await settle(tester);
    await shot(tester, 'video-transcript', crop: find.byType(PlayerScreen));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('video-sign-in', (tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('guide-video-sign-in')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    // A site that offers its own sign-in page and a user name and password.
    final v = VideoState(dirOverride: dir, nativeFactory: seededVideoNative(const [], auth: 'both'), tokens: MemoryTokenStore(), prefs: VideoPrefs());
    await tester.runAsync(v.init);
    await tester.runAsync(() => v.addInstance('tube.example.org'));
    addTearDown(v.dispose);
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('tube.example.org')),
          body: Center(child: TextButton(onPressed: () => showInstanceSheet(context, video: v, instance: v.instances.single), child: const Text('open'))),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.pumpAndSettle();
    await shot(tester, 'video-sign-in', crop: _sheet);
    await tester.pumpWidget(const SizedBox());
  });

  // ---- PDFs -----------------------------------------------------------------------------------------------

  testWidgets('pdf-reader, pdf-cited-passage', (tester) async {
    final dir = Directory.systemTemp.createTempSync('guide-pdf');
    addTearDown(() => dir.deleteSync(recursive: true));
    final book = (File('${dir.path}/book.pdf')..writeAsBytesSync(sampleHandbook())).path;

    await _openPdf(tester, PdfReaderScreen(source: PdfFileSource(book, title: 'Water and Shelter Handbook'), initialPage: 12));
    await _until(tester, find.text('12 of 340'));
    await settle(tester, rounds: 30);
    await shot(tester, 'pdf-reader');

    const quote = 'If you cannot boil water, filter it through a clean cloth, then add household bleach without scent: '
        'two drops to each litre, stir, and wait thirty minutes.';
    await _openPdf(tester, PdfReaderScreen(source: PdfFileSource(book, title: 'Water and Shelter Handbook'), initialPage: 47, quote: quote));
    await _until(tester, find.text('Cited passage'));
    await settle(tester, rounds: 30);
    await shot(tester, 'pdf-cited-passage');
    await readerDone(tester);
  });

  testWidgets('search-pdf-hits', (tester) async {
    final h = _HomeRig();
    await homeRig(tester, h);
    // The app's own Library search (its rows and second lines as Home shows them) over what the core finds for "boil water":
    // a passage in a ZIM's PDF, a ZIM page, and words said in a ZIM's video (a caption hit).
    final dir = Directory.systemTemp.createTempSync('guide-search');
    addTearDown(() => dir.deleteSync(recursive: true));
    const zim = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
    final libraryHits = LibrarySearchProvider(
      sources: _HitSources(dir, [
        {'address': 'zimpdf:$zim/Manuals/water.pdf@3', 'title': 'Water and Shelter Handbook, p. 47', 'snippet': 'Bring it to a rolling boil.', 'source_id': zim, 'source_kind': 'zim', 'source_title': 'Survival Library', 'page': 47, 'pdf_page': 49},
        {'address': 'zimcap:$zim/Videos/water_en.srt@6', 'title': 'Purifying water in the field, at 02:15', 'snippet': 'Boil the water for one full minute.', 'source_id': zim, 'source_kind': 'zim', 'source_title': 'Survival Library', 'page': null, 'link': 'zim:$zim/Videos/water.mp4', 'time': 135, 'lang': 'en', 'quote': 'Boil the water'},
        {'address': 'zim:$zim/A/Water_purification', 'title': 'Water purification', 'snippet': 'Boiling kills germs.', 'source_id': zim, 'source_kind': 'zim', 'source_title': 'Wikipedia Medicine', 'page': null},
      ]),
      openZim: (_) {},
      openAddress: (_) {},
      openVideo: (_, _, _) {},
      openPassage: (_, _) {},
    );
    final search = AppSearch([
      libraryHits,
      _Found('Notebooks', Icons.book_outlined, [('Water cache restocked', 'Journal · Oct 27', 0.5)]),
    ]);
    await show(tester, HomeScreen(layout: h.layout, weather: h.weather, search: search, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}, onOpenWeather: () {}));
    await tester.enterText(find.byKey(const ValueKey('home-search')), 'boil water');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await shot(tester, 'search-pdf-hits');
    await tester.pumpWidget(const SizedBox());
    h.layout.dispose();
    await h.r.dispose(tester);
  });

  // ---- Maps: the screens over the real map of the sample park (guide_sample.dart, guide_map_kit.dart) -----------------

  Future<_MapRig> mapRig(WidgetTester tester, {bool notebooks = false}) async {
    final m = _MapRig();
    final before = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => GuideMapSurface(m.kit.picture, mapPaletteFor(CacheThemeId.light)['land']);
    addTearDown(() => MapLibrePlatform.createInstance = before);
    await m.kit.load(tester);
    m.sample = GuideSample.load();
    // The public lands layer comes from the published catalogue on a phone; here its definition is handed to the test engine.
    m.r = await _rig(tester, publishedLayers: [m.sample.publicLands]);
    // Hillshade is on in the guide's map views (a new install draws only the base map until it is switched on).
    m.r.maps.setOn('hillshade', true);
    // The routes are the park's: the walk along a trail for the off-road modes, else the drive.
    m.backend = FakeBackend()..onRoute = (to, mode, from) async => MapRoute.fromJson(m.sample.routeFor(mode));
    // The heights along a route are read from the map's elevation tiles on a phone; here from the sample's files, read from the
    // same tiles.
    m.elevation = RouteElevation(loader: (route) async => m.sample.elevationOf(route));
    m.gps = FakeNavPosition();
    m.nav = NavState(
      backend: m.backend,
      location: m.r.location,
      speaker: FakeSpeaker(),
      positionSource: m.gps,
      fmt: const Fmt(UnitSystem.imperial),
      // As the app wires it: guidance turns the map to the heading.
      onFollow: m.r.maps.setFollow,
      searchDebounce: const Duration(milliseconds: 1),
      meaningDebounce: const Duration(milliseconds: 2),
    );
    m.r.location.publish(fixAt(GuideSample.here.lat, GuideSample.here.lon, heading: GuideSample.hereHeading));
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

  // Where the style reads its fonts in a test; the renderer puts the app's own font files there.
  const mapGlyphs = 'file:///test/fonts/{fontstack}/{range}.pbf';

  MapLibreMap mapOf(WidgetTester tester) => tester.widget<MapLibreMap>(find.byType(MapLibreMap));

  /// Tells the screen its style has loaded, as the map does after the first style and after each new one, and waits until the
  /// screen has added its images and put its data on the map (the measure line is the last it sets).
  Future<void> styleLoaded(WidgetTester tester, _MapRig m) async {
    mapOf(tester).onStyleLoadedCallback!();
    for (var i = 0; i < 300 && !m.kit.controller.sources.containsKey(kMeasureSource); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(m.kit.controller.sources.containsKey(kMeasureSource), isTrue, reason: 'the Maps screen did not put its data on the map');
    await settle(tester);
  }

  /// A change of layers: the screen builds its style again after a short wait and sets it on the map, which then loads it.
  Future<void> restyled(WidgetTester tester, _MapRig m) async {
    final before = m.kit.controller.styleSets;
    for (var i = 0; i < 300 && m.kit.controller.styleSets == before; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(m.kit.controller.styleSets, before + 1, reason: 'the Maps screen did not set a new style');
    await styleLoaded(tester, m);
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
      glyphsLoader: () async => mapGlyphs,
      snapshotter: m.kit.inset,
      elevation: m.elevation,
      // The pictures stand for a 3x phone: its pins are drawn for that screen, as the renderer shows them.
      imagePixelRatio: kGuidePhoneScale,
    ));
    for (var i = 0; i < 600 && find.byType(MapLibreMap).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await settle(tester);
    // The style the screen built its map with: the same call, with the same layers on.
    m.kit.firstStyle = await tester.runAsync(() => m.r.maps.styleJson(mapPaletteFor(CacheThemeId.light), mapGlyphs));
    // The map is there: the screen gets its controller and is told the style has loaded, as on a phone. From here it moves the
    // camera and puts the position, the route and the pins on the map, and the controller keeps what it asked for.
    mapOf(tester).onMapCreated!(m.kit.controller);
    await styleLoaded(tester, m);
  }

  /// A Maps picture with the real map behind it: writes the scene (what the map shows now), puts the scene's rendered picture
  /// where the map is, tells the screen the camera the map has (the scale bar and the compass follow it), and takes the picture.
  Future<void> mapShot(WidgetTester tester, _MapRig m, String id, String scene) async {
    final map = mapOf(tester);
    final size = tester.getSize(find.byType(MapLibreMap));
    final cam = m.kit.cameraOf(map, size);
    m.kit.writeScene(
      scene,
      style: m.kit.style,
      camera: cam,
      size: size,
      ratio: tester.view.devicePixelRatio,
      sources: m.kit.controller.sources,
      images: m.kit.controller.images,
    );
    m.kit.show(scene);
    map.onCameraMove!(CameraPosition(target: LatLng(cam.lat, cam.lon), zoom: cam.zoom, bearing: cam.bearing));
    await tester.pump();
    await shot(tester, id);
  }

  Future<void> endMap(WidgetTester tester, _MapRig m) async {
    m.kit.writeIndex();
    await tester.pumpWidget(const SizedBox());
    m.nav.dispose();
    m.elevation.dispose();
    await m.r.dispose(tester);
    m.kit.dispose();
  }

  /// A press and hold on the map at [spot]: a real pointer goes down where the camera puts the spot (the screen opens the ring
  /// around the finger), the map reports the long press there, as the platform view does, and the finger lifts.
  Future<void> holdMap(WidgetTester tester, _MapRig m, GeoPoint spot) async {
    final box = tester.getRect(find.byType(MapLibreMap));
    final at = m.kit.cameraOf(mapOf(tester), box.size).project(spot.lat, spot.lon, box.size);
    final finger = await tester.startGesture(box.topLeft + at);
    mapOf(tester).onMapLongClick!(Point(at.dx, at.dy), LatLng(spot.lat, spot.lon));
    await tester.pump();
    await finger.up();
    await settle(tester);
    final ring = tester.getCenter(find.byKey(const ValueKey('ring-menu')));
    expect((ring - (box.topLeft + at)).distance, lessThan(4), reason: 'the ring did not open around the finger');
  }

  /// A tap on the map at [spot], as the platform view reports it.
  Future<void> tapMap(WidgetTester tester, _MapRig m, GeoPoint spot) async {
    final size = tester.getSize(find.byType(MapLibreMap));
    final at = m.kit.cameraOf(mapOf(tester), size).project(spot.lat, spot.lon, size);
    mapOf(tester).onMapClick!(Point(at.dx, at.dy), LatLng(spot.lat, spot.lon));
    await settle(tester);
  }

  // One test for every Maps picture: the map screen is built once (a second one in the same run waits for its style for good).
  // Every picture has the real map behind it (mapShot).
  testWidgets('the Maps pictures', (tester) async {
    // Over a map the round buttons and the panels cast real, soft shadows, as on a phone (a test otherwise draws a button's
    // shadow as a hard black ring). Put back before the test ends, which checks it.
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    // The notebooks' icons on the ring are Material Symbols. This is the last test but one of the file (the places test after it
    // needs the font too), so no other picture changes with it.
    await tester.runAsync(loadSymbolFont);
    final m = await mapRig(tester, notebooks: true);
    await showMap(tester, m);
    await mapShot(tester, m, 'maps-find-me', 'find-me');

    // The layers sheet over the map, with public lands on as well: the whole screen, so the map shows above the sheet.
    m.r.maps.setOn(m.sample.publicLandsId, true);
    await restyled(tester, m);
    await tester.tap(find.byTooltip('Layers'));
    await settle(tester);
    await mapShot(tester, m, 'layers-sheet', 'layers');
    await tester.tapAt(const Offset(10, 60));
    await settle(tester);
    m.r.maps.setOn(m.sample.publicLandsId, false);
    await restyled(tester, m);

    m.nav.select(GuideSample.arch);
    await settle(tester);
    await mapShot(tester, m, 'place-card', 'place-card');
    m.nav.clearSelection();

    // A search, with the map where the place card left it: the park's arches, nearest to the phone first.
    m.backend.onSearch = (q, {near, meaning}) async => MapSearchResponse(query: q, kind: 'text', meaning: 'off', results: GuideSample.arches);
    await tester.tap(find.byKey(const ValueKey('map-search-field')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('map-search-field')), 'arch');
    await tester.pump(const Duration(milliseconds: 50));
    await settle(tester);
    await mapShot(tester, m, 'maps-search', 'search');
    m.nav.closeSearch();
    m.backend.onSearch = null;
    await settle(tester);

    // Directions start where the phone is: it has moved on, to where the drive begins.
    final start = m.sample.routeStart;
    m.r.location.publish(fixAt(start.lat, start.lon, heading: m.sample.routeStartHeading));
    await tester.runAsync(() => m.nav.openDirections(GuideSample.trailhead));
    await settle(tester);
    await mapShot(tester, m, 'directions-panel', 'directions');

    // Off-road, on foot: the phone is at the Windows parking, and the way to the arch of the place card is its trail. The screen
    // fits the route into the free part of the map (with Off-road chosen: the column between the position chip and the map's
    // buttons), and the picture shows that view.
    m.nav.cancelDirections();
    final foot = m.sample.offroadStart;
    m.r.location.publish(fixAt(foot.lat, foot.lon, heading: m.sample.offroadStartHeading));
    await tester.runAsync(() => m.nav.setMode('offroad_foot'));
    await tester.runAsync(() => m.nav.openDirections(GuideSample.arch));
    await settle(tester);
    await mapShot(tester, m, 'directions-offroad', 'offroad');

    // The drive again, and guidance along it.
    m.nav.cancelDirections();
    m.r.location.publish(fixAt(start.lat, start.lon, heading: m.sample.routeStartHeading));
    await tester.runAsync(() => m.nav.setMode('drive'));
    await tester.runAsync(() => m.nav.openDirections(GuideSample.trailhead));
    await settle(tester);
    final fix = m.sample.guidanceFix;
    m.backend.onProgress = (r, lat, lon) async => m.sample.progress();
    await tester.runAsync(() async {
      await m.nav.start();
      m.gps.controller.add(fixAt(fix.lat, fix.lon, heading: m.sample.guidanceHeading));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle(tester);
    // The camera the screen asked for puts the phone low on the map, where the screen means it to be: the picture and the
    // screen then agree.
    final mapSize = tester.getSize(find.byType(MapLibreMap));
    final at = m.kit.cameraOf(mapOf(tester), mapSize).project(fix.lat, fix.lon, mapSize);
    expect((at - guidanceAnchor(mapSize, side: false)).distance, lessThan(3), reason: 'the guidance camera does not put the position at its anchor');
    m.kit.inset.write();
    await mapShot(tester, m, 'guidance', 'guidance');
    await tester.runAsync(() async => m.nav.end());
    m.r.maps.setFollow(FollowMode.free);

    // The ring, with a route shown (so it offers Add stop): the phone is where the drive begins again, the drive is asked for
    // and the screen fits it into view. The map then shows what it shows in the directions picture, so these two pictures are
    // drawn over that scene (if the map ever differs here, its picture no longer matches the scene and the test says so). Then
    // the notebook ring after Save.
    m.r.location.publish(fixAt(start.lat, start.lon, heading: m.sample.routeStartHeading));
    await settle(tester);
    m.kit.movedTo(GuideCamera(lat: start.lat, lon: start.lon, zoom: 14));
    // The screen is told where the map is, as the map tells it: north up again after the guidance. Its North up button goes, so
    // the map's buttons take the room they take in the directions picture and the drive is fitted the same.
    mapOf(tester).onCameraMove!(CameraPosition(target: LatLng(start.lat, start.lon), zoom: 14));
    await settle(tester);
    await tester.runAsync(() => m.nav.openDirections(GuideSample.trailhead));
    await settle(tester);
    await holdMap(tester, m, GuideSample.ringSpot);
    await mapShot(tester, m, 'map-ring', 'directions');

    RingMenu ring() => tester.widget<RingMenu>(find.byKey(const ValueKey('ring-menu')));
    ring().onPick(const RingItem(id: 'save', label: 'Save', icon: Icons.book_outlined));
    await settle(tester);
    await mapShot(tester, m, 'map-notebook-ring', 'directions');

    // Measure: the route is put away, the map is moved to the place card's view, and three points are measured there.
    await tester.tapAt(const Offset(30, 200));
    await settle(tester);
    m.nav.cancelDirections();
    m.nav.clearSelection();
    await settle(tester);
    final view = GuideCamera(lat: GuideSample.arch.lat, lon: GuideSample.arch.lon, zoom: GuideSample.measureZoom);
    m.kit.movedTo(view);
    mapOf(tester).onCameraMove!(CameraPosition(target: LatLng(view.lat, view.lon), zoom: view.zoom));
    await settle(tester);
    await holdMap(tester, m, GuideSample.measured.first);
    ring().onPick(const RingItem(id: 'measure', label: 'Measure', icon: Icons.straighten));
    await settle(tester);
    for (final p in GuideSample.measured.skip(1)) {
      await tapMap(tester, m, p);
    }
    await mapShot(tester, m, 'map-measure', 'measure');
    // The place form's small map has this style on a phone too (see _formMapStyle).
    _formMapStyle = m.kit.style;
    _formPinStyle = m.r.maps.pinStyle;
    await endMap(tester, m);
    debugDisableShadows = true;
  });

  // ---- Places (after the Maps pictures: the place form has a map too, and its pin is drawn in the icons' own font) --------

  testWidgets('places-list, places-edit, place-alerts-sheet', (tester) async {
    await tester.runAsync(loadSymbolFont);
    final kit = GuideMaps();
    await kit.load(tester);
    final n = _NbRig()..formMap = kit;
    final book = await n.saved(tester);
    await n.place(tester, book, 'Camp', 38.7755, -109.588, color: 'green');
    await n.place(tester, book, GuideSample.trailhead.name, GuideSample.trailhead.lat, GuideSample.trailhead.lon, color: 'yellow');
    await n.place(tester, book, 'Water', 38.6166, -109.6195, color: 'blue');
    await n.place(tester, book, 'Meeting point', 38.7017, -109.5647, color: 'purple');
    n.watched.add('place:trailhead');
    await show(tester, NotebookScreen(deps: n.deps, notebookId: book.id));
    await tester.pumpAndSettle();
    await shot(tester, 'places-list');

    await tester.longPress(find.text(GuideSample.trailhead.name));
    await tester.pumpAndSettle();
    // The form's small map. The app's PlaceMap is a platform view, so its scene is written here the way PlaceMap fills its map:
    // the app's style with the same layers on (the Maps test's, as the app has one map state), the place in the middle at the
    // zoom PlaceMap opens a pinned place at, and the place's pin drawn by the notebook pins' layer with the image PlaceMap adds
    // for it. The rendered picture is then shown in the form.
    final style = _formMapStyle, pins = _formPinStyle;
    if (style == null || pins == null) fail('The place form needs the map style the Maps test keeps: run the whole file');
    final pin = n.mapPin!, look = n.mapLook!;
    final images = <String, Uint8List>{};
    final image = (await tester.runAsync(() => PinImages((name, png) async {
      images[name] = png;
    }, pins, ratio: pinImageRatio(kGuidePhoneScale)).ensure(look.icon.id, look.glyph, look.tint)))!;
    Map<String, dynamic> points(List<Map<String, dynamic>> features) => {'type': 'FeatureCollection', 'features': features};
    kit.writeScene(
      'place-form',
      style: style,
      camera: GuideCamera(lat: pin.lat, lon: pin.lon, zoom: kPlaceZoom),
      size: tester.getSize(find.byType(GuideFormMap)),
      ratio: tester.view.devicePixelRatio,
      sources: {
        kPinSource: points(const []),
        kNotebookSource: points([
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [pin.lon, pin.lat],
            },
            'properties': {'pin': image, 'title': 'place'},
          },
        ]),
      },
      images: images,
    );
    kit.show('place-form');
    await tester.pump();
    await shot(tester, 'places-edit');

    await tester.dragUntilVisible(find.byKey(const ValueKey('weather-gear')), find.byType(ListView).last, const Offset(0, -200));
    await tester.tap(find.byKey(const ValueKey('weather-gear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('alert-mode-custom')));
    await tester.pumpAndSettle();
    await shot(tester, 'place-alerts-sheet', crop: _sheet);
    kit.writeIndex();
    await tester.pumpWidget(const SizedBox());
    kit.dispose();
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
      HomeAlert(fire: false, label: 'Red flag warning', detail: 'Until 9 PM · Grand County · National Weather Service'),
      HomeAlert(fire: true, label: 'East Fork fire', detail: '31 mi N · 266 acres · 60% contained'),
    ],
  );
}

/// The sample videos' pictures and caption files, drawn once (a sky, a ground and a sun in each video's colours; no photo).
class _VideoPictures {
  _VideoPictures(this.dir, this.frame, this.thumbs, this.en, this.es);

  final Directory dir;
  final String frame;
  final Map<String, String> thumbs;
  final DownloadedCaption en;
  final DownloadedCaption es;
}

_VideoPictures? _pictures;

_VideoPictures _videoPictures() {
  if (_pictures case final p?) return p;
  final dir = Directory.systemTemp.createTempSync('guide-video-pictures');
  String picture(String name, int r, int g, int b, {int w = 640, int h = 360}) {
    final im = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final t = y / h;
        final sun = (x - w * 0.72) * (x - w * 0.72) + (y - h * 0.3) * (y - h * 0.3) < (h * 0.12) * (h * 0.12);
        if (sun) {
          im.setPixelRgb(x, y, 250, 226, 160);
        } else if (y < h * 0.62) {
          im.setPixelRgb(x, y, (r * (1 - t * 0.5)).round(), (g * (1 - t * 0.4)).round(), (b * (1 - t * 0.2)).round());
        } else {
          final hill = (y - h * 0.62) / (h * 0.38);
          im.setPixelRgb(x, y, (60 + 40 * hill).round(), (90 + 30 * hill).round(), (52 + 10 * hill).round());
        }
      }
    }
    return (File('${dir.path}/$name.png')..writeAsBytesSync(img.encodePng(im))).path;
  }

  return _pictures = _VideoPictures(
    dir,
    picture('frame', 120, 170, 220, w: 1280, h: 720),
    {
      'knots': picture('knots', 110, 160, 210),
      'fire': picture('fire', 210, 130, 90),
      'splint': picture('splint', 150, 190, 170),
      'burns': picture('burns', 190, 160, 200),
    },
    writeCaption(dir, 'en', 'English', kKnotCues),
    writeCaption(dir, 'es', 'Spanish', kKnotCuesEs, automatic: true),
  );
}

/// Reads the sample pictures once (an image file loads outside the test's clock).
Future<void> _precache(WidgetTester tester, _VideoPictures p) async {
  final ctx = tester.element(find.byType(Scaffold).first);
  await tester.runAsync(() async {
    for (final f in [...p.thumbs.values, p.frame]) {
      await precacheImage(FileImage(File(f)), ctx);
    }
  });
  await tester.pump();
}

/// The saved knots video in the player: two caption languages, saved at 480p, its frame drawn by [p].
PlayerScreen _knots(_VideoPictures p, RecordingController c, {VideoPrefs? prefs}) => PlayerScreen(
  target: VideoTarget(
    isLocal: true,
    uuid: 'knots',
    title: 'Knots every camper should know',
    offsetS: 0,
    durationS: 730,
    location: 'offline.mp4',
    instance: 'example.org',
    captions: [p.en, p.es],
  ),
  prefs: prefs ?? VideoPrefs(),
  channel: 'Field Skills',
  mobileOverride: false,
  savedQuality: '480p',
  frame: Image.file(File(p.frame), fit: BoxFit.cover),
  controllerFactory: (_) => c,
);

/// [reader] opened over a blank page (so its top-left arrow shows), on the phone.
Future<void> _openPdf(WidgetTester tester, Widget reader) async {
  phone(tester, size: const Size(430, 932), ratio: _ratio);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
    key: UniqueKey(),
    navigatorKey: nav,
    debugShowCheckedModeBanner: false,
    theme: shotTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 54, bottom: 34), viewPadding: const EdgeInsets.only(top: 54, bottom: 34)),
      child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
    ),
    home: const Scaffold(),
  ));
  nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => reader));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps until [f] finds something (file work runs outside the test's clock).
Future<void> _until(WidgetTester tester, Finder f, {int max = 200}) async {
  for (var i = 0; i < max && f.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(f, findsWidgets);
}

/// The sync engine's stand-in that counts each shared folder's files and bytes, as the real one reports them.
class _CountingSync extends FakeSync {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> args = const {}]) async {
    final r = await super.call(method, args);
    if (method != 'status') return r;
    return {
      ...r,
      'shares': [
        for (final sh in (r['shares'] as List).cast<Map<String, Object?>>())
          () {
            final files = Directory(sh['path']! as String).listSync(recursive: true).whereType<File>().toList();
            return {...sh, 'files': files.length, 'bytes': files.fold<int>(0, (n, f) => n + f.lengthSync())};
          }(),
      ],
    };
  }
}

/// An Obsidian vault in memory (the connection's folder).
class _MemFolder implements SyncFolder {
  final Map<String, String> text = {};

  @override
  String get display => 'Vault';

  @override
  Future<bool> reachable() async => true;

  @override
  Future<List<FolderFile>> list(String dir) async => [
    for (final p in (text.keys.toList()..sort()))
      if (dir.isEmpty || p.startsWith('$dir/')) FolderFile(p, 0, text[p]!.length),
  ];

  @override
  Future<String?> readText(String path) async => text[path];

  @override
  Future<Uint8List?> readBytes(String path) async => null;

  @override
  Future<void> writeText(String path, String t) async {
    text[path] = t;
  }

  @override
  Future<void> writeBytes(String path, Uint8List b) async {}

  @override
  Future<void> delete(String path) async => text.remove(path);

  @override
  Future<bool> exists(String path) async => text.containsKey(path);
}

/// The index scheduler as Settings reads it: only its status line, set by the picture (no work is run).
class _ShotIndexing extends IndexScheduler {
  _ShotIndexing(this._line, {this.shown = const []}) : super(sources: const [], space: () => throw UnimplementedError('no index work in a picture'));

  final String _line;

  /// The work the picture shows (the rows and the overview read it); none: only the line.
  final List<IndexItem> shown;

  @override
  String? get line => _line;

  @override
  List<IndexItem> get items => shown;

  @override
  IndexItem? statusOf(String key) => shown.where((i) => i.key == key).firstOrNull;

  @override
  double get fraction => 0.3;
}

/// The Library's PDF indexing as the rows read it: each ZIM's PDFs part (by file name), set by the picture (no work is run).
class _ShotPdfIndex extends PdfIndexState {
  _ShotPdfIndex(Directory dir, this.parts)
    : super(
        core: const PdfIndexCoreMissing(),
        zims: () => const [],
        indexesDir: () async => dir,
        recordFile: () async => File('${dir.path}/pdf-index.json'),
        autoStart: null,
      );

  final Map<String, PdfPart> parts;

  @override
  PdfPart? partOf(PdfZimRef z) => parts[z.path.split(Platform.pathSeparator).last];
}

/// Sources whose search core answers every search with [hits] (the core's own JSON for each hit).
class _HitSources extends FakeSources {
  _HitSources(super.dir, this.hits);

  final List<Map<String, dynamic>> hits;

  @override
  bool get coreReady => true;

  @override
  Future<SearchResponse> searchIn(String query, {List<String>? zimIds, int k = 20, int offset = 0}) async =>
      SearchResponse.fromJson({'results': hits, 'total_estimate': hits.length});
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

/// The moment the guide's pictures show where a screen tells the time of a sync or a download ("Synced 4:59 PM", an imported
/// note's date, "Downloaded Nov 8"), so a redraw on another day does not change them. A local time, so it reads the same on
/// any machine.
final DateTime _shotClock = DateTime(2026, 11, 8, 16, 59);

Templates _templates() => Templates.parse(File('assets/notebook/templates.json').readAsStringSync(), File('assets/notebook/starters.json').readAsStringSync());

/// The Weather picture's sixteen days from Monday, made up: conditions (in the forecast source's words), high, low and chance of
/// rain. The first is the day on Home's card.
const List<(String, int, int, int)> _forecastDays = [
  ('partly cloudy', 58, 37, 10),
  ('light rain', 55, 34, 60),
  ('overcast', 49, 31, 20),
  ('mainly clear', 54, 32, 5),
  ('clear sky', 59, 35, 0),
  ('clear sky', 62, 38, 0),
  ('partly cloudy', 60, 39, 10),
  ('light rain', 56, 38, 45),
  ('overcast', 53, 35, 25),
  ('mainly clear', 55, 33, 5),
  ('clear sky', 58, 34, 0),
  ('clear sky', 61, 36, 0),
  ('partly cloudy', 60, 38, 10),
  ('rain showers', 54, 37, 65),
  ('partly cloudy', 52, 34, 20),
  ('clear sky', 55, 32, 0),
];

const PlaceChoices _places = PlaceChoices(here: _hereNow, saved: _savedNone);
Future<({double lat, double lon})?> _hereNow() async => (lat: GuideSample.here.lat, lon: GuideSample.here.lon);
Future<List<NbPlace>> _savedNone() async => const [];

class _NbRig {
  final FakeNotebookBackend store = FakeNotebookBackend();
  late final NotebookState nb = fakeNotebook(store);
  final Templates templates = _templates();
  final PlaceAlerts alerts = PlaceAlerts.memory();
  final Set<String> watched = {'here'};

  /// The pictures of the place form's small map (guide_map_kit.dart); null leaves its space empty.
  GuideMaps? formMap;

  /// What the place form last asked its map to show: the place and the look of its pin.
  NbPlace? mapPin;
  PinLook? mapLook;

  PlaceNotebookDeps get pd => PlaceNotebookDeps(
    watched: watched.contains,
    setWatched: (id, on) => on ? watched.add(id) : watched.remove(id),
    alerts: alerts,
    placesChanged: () async {},
    alertSetting: () => 'Serious only, from Notifications',
    alertKinds: () => const ['alerts', 'fire', 'earthquakes', 'hydrology'],
    regions: () async => const [(id: 'region:Utah', name: 'Utah')],
    hereOnMap: () => true,
    setHereOnMap: (_) {},
    // The map is a platform view: the picture of its scene is shown in its place, or the space is left empty.
    map: (context, pin, onPick, look) {
      mapPin = pin;
      mapLook = look;
      final kit = formMap;
      return kit == null ? const SizedBox.shrink() : GuideFormMap(kit.picture);
    },
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
  /// The map pictures (guide_map_kit.dart) and the sample park (guide_sample.dart).
  final GuideMaps kit = GuideMaps();
  late GuideSample sample;
  late SettingsRig r;
  late FakeBackend backend;
  late FakeNavPosition gps;
  late NavState nav;
  late RouteElevation elevation;
  late _Regions regions;
  FakeNotebookBackend? store;
  NotebookState? notebooks;
}


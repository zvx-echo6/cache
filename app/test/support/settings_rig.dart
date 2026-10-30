import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/screens/videos/library_screen.dart' as videos show LibraryScreen;
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/settings/location_access.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:cache/settings/web_search_setup.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:cache/weather/places.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import '../nav_fakes.dart';
import '../video_fake.dart';
import 'weather_fakes.dart';
import 'sync_fake.dart';
import 'test_layer_engine.dart';

class FakeAccess implements LocationAccessProbe {
  FakeAccess(this.value);

  LocationAccess value;

  @override
  Future<LocationAccess> read() async => value;
}

class RigPositionSource implements PositionSource {
  RigPositionSource({this.permissionState = LocationPermissionState.granted});

  LocationPermissionState permissionState;
  int settingsOpened = 0;
  int asked = 0;

  @override
  Future<LocationPermissionState> permission() async => permissionState;
  @override
  Future<LocationPermissionState> requestPermission() async {
    asked++;
    return permissionState = LocationPermissionState.granted;
  }

  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async => settingsOpened++;
  @override
  Future<void> openLocationSettings() async {}
}

/// Every object the Settings pages read, on fakes: no core, no network, files in a temp folder. Pages are shown with [show].
class SettingsRig {
  SettingsRig._();

  late Directory dir;
  late AppSettings settings;
  late FakeProbe probe;
  late DataPolicy policy;
  late MemoryTokenStore secrets;
  late WebSearchSetup webSearch;
  late StorageUsage storage;
  late FakeAccess access;
  late RigPositionSource position;
  late AppState app;
  late ConversationStore store;
  late ChatController chat;
  late FakeSources sources;
  late BrowseState browse;
  late VideoState video;
  late LocationService location;
  late MapsState maps;
  late TestLayerEngine engine;
  late SettingsHub hub;
  late SharingState sharing;
  final FakeSync sync = FakeSync();
  late WeatherState weather;
  late FakeLiveCore liveCore;
  late FakeWeb web;
  late Directory liveDir;
  late Directory catalogueDir;

  /// The phone's position for "Where I am" (null: no fix yet).
  Position? here = (lat: 42.54, lon: -113.79);

  /// The time the weather part sees; tests move it.
  DateTime clock = DateTime(2026, 10, 26, 12, 0);

  /// Downloaded regions the weather part offers.
  List<WatchRegion> regionList = [];
  final List<String> opened = [];
  final List<String> keysChecked = [];

  /// What the search core was told (provider, key, online), in order.
  final List<(String?, String?, bool)> webCalls = [];

  /// What the core's web_search tool answers to the test search (set per test): results, or the tool's error JSON.
  String searchContent = '[1] Cache (web, fetched now) - a result';

  /// Folders the storage page measures, by kind.
  late Directory libraryDir;
  late Directory mapsDir;
  late Directory modelsDir;
  late Directory videosDir;

  SettingsDeps get deps => SettingsDeps(
    app: app,
    chat: chat,
    sources: sources,
    maps: maps,
    video: video,
    browse: browse,
    location: location,
    hub: hub,
    onOpenAsk: () => opened.add('ask'),
  );

  static Future<SettingsRig> create(
    WidgetTester tester, {
    ConnectionKind connection = ConnectionKind.wifi,
    LocationAccess locationAccess = LocationAccess.always,
    LocationPermissionState permission = LocationPermissionState.granted,
  }) async {
    tester.view.physicalSize = const Size(1080, 5400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final r = SettingsRig._();
    r.dir = Directory.systemTemp.createTempSync('settings-rig');
    r.settings = AppSettings(settingsDirOverride: r.dir);
    r.probe = FakeProbe(connection);
    r.policy = DataPolicy(settings: r.settings, probe: r.probe);
    r.secrets = MemoryTokenStore();
    r.webSearch = WebSearchSetup(
      settings: r.settings,
      secrets: r.secrets,
      setWeb: (provider, key, online) async => r.webCalls.add((provider, key, online)),
      probe: r.probe,
      searchProbe: (key) async {
        r.keysChecked.add(key);
        return r.searchContent;
      },
    );
    r.sources = FakeSources(Directory('${r.dir.path}/zims')..createSync());
    // The library folder is where the sources are (FakeSources keeps its indexes inside it, so it is measured once).
    r.libraryDir = r.sources.zimsDir!;
    r.mapsDir = Directory('${r.dir.path}/maps')..createSync();
    r.modelsDir = Directory('${r.dir.path}/models')..createSync();
    r.videosDir = Directory('${r.dir.path}/videos')..createSync();
    r.storage = StorageUsage(
      kinds: [
        DataKind(
          id: 'library',
          label: 'Library',
          icon: Icons.menu_book_outlined,
          shared: () => {'library': r.libraryDir},
          count: () => r.sources.zims.length,
          list: () => BrowseScreen(browse: r.browse, active: true),
        ),
        DataKind(id: 'models', label: 'Models', icon: Icons.memory, shared: () => {'models': r.modelsDir}, count: () => r.app.models.length, list: () => ModelsScreen(app: r.app)),
        DataKind(id: 'regions', label: 'Regions', icon: Icons.map_outlined, shared: () => {'maps': r.mapsDir}),
        DataKind(id: 'videos', label: 'Videos and weather', icon: Icons.smart_display_outlined, shared: () => {'videos': r.videosDir}, list: () => videos.LibraryScreen(video: r.video)),
      ],
      freeIn: () => r.dir,
      leftovers: () => [Directory('${r.dir.path}/leftovers')],
      freeSpace: (_) => 41 * 1024 * 1024 * 1024,
      totalSpace: (_) => 128 * 1024 * 1024 * 1024,
    );
    r.access = FakeAccess(locationAccess);
    r.position = RigPositionSource(permissionState: permission);
    r.app = AppState(settingsDirOverride: r.dir, modelsDirOverride: r.modelsDir);
    r.store = ConversationStore.memory();
    r.chat = ChatController(tools: const [])..attachStore(r.store);
    r.engine = TestLayerEngine(policy: r.policy);
    r.browse = BrowseState(sources: r.sources, policy: r.policy, settingsDirOverride: r.dir, phoneLanguage: 'en');
    r.video = VideoState(
      dirOverride: r.videosDir,
      nativeFactory: fakeVideoNative,
      tokens: MemoryTokenStore(),
      policy: r.policy,
    );
    r.location = LocationService(source: r.position, settingsDirOverride: r.dir);
    r.maps = MapsState(engine: r.engine, settingsDirOverride: r.dir);
    r.liveDir = Directory('${r.dir.path}/live-sources');
    r.catalogueDir = Directory('${r.dir.path}/live-catalogues');
    r.liveCore = FakeLiveCore(r.liveDir);
    r.web = FakeWeb()..serve('https://cache.echo6.co/connectors/', standardCatalogue());
    r.weather = WeatherState(
      settings: r.settings,
      policy: r.policy,
      core: r.liveCore,
      secrets: r.secrets,
      catalogueDir: () async => r.catalogueDir,
      liveDir: () async => r.liveDir,
      builtIns: () async => builtInDefinitions(),
      position: () => r.here,
      regions: () => r.regionList,
      fetch: r.web.fetch,
      clock: () => r.clock,
    );
    r.sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: [DataKind(id: 'shared', label: 'Shared folder', icon: Icons.folder_shared_outlined, shared: () => {'shared': Directory('${r.dir.path}/Shared')}, inStorage: false)],
      opener: (_) async => r.sync,
    );
    r.hub = SettingsHub(
      sharing: r.sharing,
      settings: r.settings,
      policy: r.policy,
      webSearch: r.webSearch,
      storage: r.storage,
      weather: r.weather,
      locationAccess: r.access,
      openUrl: (u) async => r.opened.add(u),
    );
    await tester.runAsync(() async {
      await r.settings.init();
      await r.webSearch.init();
      await r.browse.init();
      await r.video.init();
      await r.app.init();
      await r.maps.init();
      await r.weather.start();
      while (r.weather.refreshingCatalogues) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    return r;
  }

  /// Shows [page] in the dark theme (or [theme]).
  Future<void> show(WidgetTester tester, Widget page, {CacheThemeId theme = CacheThemeId.dark}) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(theme), home: page));
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    video.dispose();
    browse.dispose();
    sources.dispose();
    store.close();
    webSearch.dispose();
    weather.dispose();
    sharing.dispose();
    await tester.runAsync(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // A file the test left open on Windows; the temp folder is cleaned by the system.
      }
    });
  }
}

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/screens/settings/deps.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/settings/location_access.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:cache/settings/web_search_setup.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import '../nav_fakes.dart';
import '../video_fake.dart';
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
  final List<String> opened = [];
  final List<String> keysChecked = [];

  /// What the search core was told (provider, key, online), in order.
  final List<(String?, String?, bool)> webCalls = [];

  /// What the key check answers (set per test).
  KeyCheck keyAnswer = const KeyCheck.ok();

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
      check: (key) async {
        r.keysChecked.add(key);
        return r.keyAnswer;
      },
    );
    r.libraryDir = Directory('${r.dir.path}/library')..createSync();
    r.mapsDir = Directory('${r.dir.path}/maps')..createSync();
    r.modelsDir = Directory('${r.dir.path}/models')..createSync();
    r.videosDir = Directory('${r.dir.path}/videos')..createSync();
    r.storage = StorageUsage(
      library: () => [r.libraryDir],
      maps: () => [r.mapsDir],
      models: () => [r.modelsDir],
      videos: () => [r.videosDir],
      freeIn: () => r.dir,
      freeSpace: (_) => 41 * 1024 * 1024 * 1024,
    );
    r.access = FakeAccess(locationAccess);
    r.position = RigPositionSource(permissionState: permission);
    r.app = AppState(settingsDirOverride: r.dir, modelsDirOverride: r.modelsDir);
    r.store = ConversationStore.memory();
    r.chat = ChatController(tools: const [])..attachStore(r.store);
    r.sources = FakeSources(Directory('${r.dir.path}/zims')..createSync());
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
    r.hub = SettingsHub(
      settings: r.settings,
      policy: r.policy,
      webSearch: r.webSearch,
      storage: r.storage,
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
    await tester.runAsync(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // A file the test left open on Windows; the temp folder is cleaned by the system.
      }
    });
  }
}

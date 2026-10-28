import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'actions/act_core.dart';
import 'actions/action_registry.dart';
import 'actions/app_actions.dart';
import 'app_state.dart';
import 'brand.dart';
import 'browse/browse_state.dart';
import 'chat/chat_controller.dart';
import 'chat/chat_location.dart';
import 'chat/local_llama_backend.dart';
import 'chat/read_tool.dart';
import 'chat/search_tool.dart';
import 'chat/system_prompt.dart' show isoWithOffset;
import 'history/conversation_store.dart';
import 'layout/layout_state.dart';
import 'location/location_service.dart';
import 'maps/layers/core_layer_engine.dart';
import 'maps/maps_state.dart';
import 'nav/demo_backend.dart';
import 'nav/nav_backend.dart';
import 'nav/query_embedder.dart';
import 'nav/notification_access.dart';
import 'nav/nav_position.dart';
import 'nav/nav_state.dart';
import 'nav/speaker.dart';
import 'nav/units.dart';
import 'regions/region_catalogue.dart';
import 'regions/regions_state.dart';
import 'search/core_numbering.dart';
import 'settings/app_settings.dart';
import 'models/model_downloads.dart';
import 'settings/data_policy.dart';
import 'settings/hub.dart';
import 'settings/storage_usage.dart';
import 'settings/web_search_setup.dart';
import 'sharing/sharing_state.dart';
import 'video/token_store.dart';
import 'package:workmanager/workmanager.dart';

import 'weather/alert_notifier.dart';
import 'weather/alert_watch.dart';
import 'weather/background.dart';
import 'weather/live_core.dart';
import 'weather/places.dart';
import 'weather/weather_state.dart';
import 'maps/layers/starter_defs.dart' show readLiveSourceAssets;
import 'search/numbering_state.dart';
import 'search/core_tool_host.dart';
import 'sources/sources_state.dart';
import 'video/video_state.dart';
import 'screens/settings/about_pages.dart' show kCreditsAsset;
import 'screens/shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The credits (native libraries, Rust crates, data sources, art) join the licences Flutter lists for the packages.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Cache: libraries, data and art'], await rootBundle.loadString(kCreditsAsset));
  });
  // Background updates of weather, alerts and fires (scheduled once something is switched on; see scheduleBackgroundUpdates).
  if (Platform.isAndroid || Platform.isIOS) Workmanager().initialize(cacheBackgroundDispatcher);
  runApp(const CacheApp());
}

class CacheApp extends StatefulWidget {
  const CacheApp({super.key});

  @override
  State<CacheApp> createState() => _CacheAppState();
}

class _CacheAppState extends State<CacheApp> {
  late final AppState app = AppState();
  late final SourcesState sources = SourcesState();
  late final BrowseState browse = BrowseState(sources: sources, policy: policy);
  late final LocationService location = LocationService(
    onFix: (f) => chatLocation.update(f),
  );
  late final ChatLocation chatLocation = ChatLocation(
    location: location,
    synchronize: (f) async {
      if (await sources.whenCoreReady() == null) return false;
      return sources.setLocation(f?.lat, f?.lon, accuracyM: f?.accuracyM ?? -1, at: f?.time);
    },
  );
  // The layer engine in the core (cs_layers_*): the catalogue, the tile server the map reads from, area downloads.
  late final AppSettings settings = AppSettings();
  // The rule for mobile data, asked by every download (map areas, ZIMs, videos).
  late final DataPolicy policy = DataPolicy(settings: settings);
  late final ModelDownloads modelDownloads = ModelDownloads(app: app, policy: policy);
  late final MapsState maps = MapsState(
    engine: CoreLayerEngine(
      openCore: sources.whenCoreReady,
      layersConfig: () => sources.layersSection,
      policy: policy,
    ),
  );
  late final VideoState video = VideoState(policy: policy);
  late final WebSearchSetup webSearch = WebSearchSetup(
    settings: settings,
    secrets: const SecureTokenStore(),
    setWeb: (provider, key, online) async =>
        (await sources.whenCoreReady())?.setWeb(provider: provider, key: key, online: online),
    // Checking a key is one real search through the core's own web_search tool, the request the assistant will make.
    searchProbe: (key) async {
      final core = await sources.whenCoreReady();
      if (core == null) throw StateError('The search core is not available');
      await core.setWeb(provider: WebSearchSetup.provider, key: key, online: true);
      final conv = await core.newConversation();
      try {
        return (await conv.tool('web_search', {'query': 'Cache'}, now: isoWithOffset(DateTime.now()))).content;
      } finally {
        await conv.free();
      }
    },
  );
  // Weather, alerts and fires: the sources that are on, their keys, the places watched, and Update now. The search core is told what it
  // may fetch (the policy) and holds the keys in memory only.
  late final WeatherState weather = WeatherState(
    settings: settings,
    policy: policy,
    core: SearchLiveCore(sources.whenCoreReady),
    secrets: const SecureTokenStore(),
    catalogueDir: () async => Directory('${(await getApplicationSupportDirectory()).path}/live-catalogues'),
    liveDir: () async {
      await sources.whenCoreReady();
      final dir = (sources.openedExtra['live'] as Map?)?['sources_dir'];
      return dir is String ? Directory(dir) : null;
    },
    builtIns: readLiveSourceAssets,
    position: () {
      final f = location.fix;
      return f == null ? null : (lat: f.lat, lon: f.lon);
    },
    regions: () => regionsFromAreas([for (final l in maps.catalogueLayers) ...maps.areasOfCard(l)]),
    notifier: LocalAlertNotifier.instance,
    told: ToldStore.lazy(() async => File('${(await getApplicationSupportDirectory()).path}/alerts_told.json')),
  );
  /// The app's support folder, read at start (the alert memory and the last place live there).
  String? _supportPath;
  // Sharing and sync: Cache's own folders, each with a fixed id so the same kind of thing on linked devices is one shared folder.
  late final SharingState sharing = SharingState(
    policy: policy,
    supportDir: getApplicationSupportDirectory,
    deviceName: Platform.isAndroid ? 'Android phone' : (Platform.isIOS ? 'iPhone' : Platform.localHostname),
    kinds: [
      ShareKind('library', 'Library', () => sources.zimsDir),
      ShareKind('maps', 'Maps', () => sources.zimsDir == null ? null : Directory('${sources.zimsDir!.parent.path}/packs')),
      ShareKind('models', 'Models', () => app.modelsDir),
      ShareKind('videos', 'Videos', () => video.dir),
      ShareKind('shared', 'Shared folder', () => sources.zimsDir == null ? null : Directory('${sources.zimsDir!.parent.path}/Shared')),
    ],
  );
  // Regions and downloads: the region catalogue (kept in the support folder so it works offline once seen), the core's road routing
  // tiles and the map layers' area downloads. When the ready regions change, the routing the search core opens with is built again.
  late final RegionsState regions = RegionsState(
    policy: policy,
    supportDir: getApplicationSupportDirectory,
    catalogue: RegionCatalogue(dir: () async => Directory('${(await getApplicationSupportDirectory()).path}/region-catalogue')),
    maps: maps,
  );
  late final SettingsHub hub = SettingsHub(
    settings: settings,
    policy: policy,
    webSearch: webSearch,
    weather: weather,
    sharing: sharing,
    regions: regions,
    storage: StorageUsage(
      library: () => [sources.zimsDir, sources.indexesDir],
      maps: () => [
        if (sources.layersSection['dir'] is String) Directory(sources.layersSection['dir'] as String),
        if (sources.zimsDir != null) Directory('${sources.zimsDir!.parent.path}/packs'),
        if (_supportPath != null) Directory('$_supportPath/regions'),
      ],
      models: () => [app.modelsDir],
      videos: () => [video.dir],
      freeIn: () => app.modelsDir ?? sources.zimsDir,
    ),
  );
  late final LayoutState layout = LayoutState();
  late final ChatController chat = ChatController(
    tools: [SearchTool(sources), ReadTool(sources)],
    newNumbering: () =>
        sources.coreReady ? CoreNumbering(sources.newConversation) : null,
    // Once the core is open every tool it has installed is offered and runs through its dispatch (cs_tool).
    newHost: (numbering) => sources.core == null || numbering is! CoreNumbering
        ? null
        : CoreToolHost(core: sources.core!, numbering: numbering),
    numberingState: CoreNumberingState(() => sources.core),
    locationKnown: () => chatLocation.known,
    prepareTurn: chatLocation.prepare,
    actions: actionRegistry,
    actCore: actCore,
  );
  // What the assistant can do through the act tool: each module's actions, run by the core for read and open and by a tap on a
  // confirm card for change. The core's act hook is not in the FFI yet, so nothing is offered to the model until it is.
  final ActionRegistry actionRegistry = ActionRegistry();
  final ActCore actCore = const ActCoreStandIn();
  late final AppActions appActions = AppActions(
    registry: actionRegistry,
    places: PlacesDeps(
      save: ({required name, required lat, required lon, label}) async {
        final core = await sources.whenCoreReady() ?? (throw StateError('The search core is not available'));
        return core.savePlace(name: name, lat: lat, lon: lon, label: label);
      },
      list: () async => (await sources.whenCoreReady() ?? (throw StateError('The search core is not available'))).savedPlaces(),
    ),
    watch: WatchDeps(choices: weather.placeChoices, watched: () => settings.watchedPlaces, setWatched: settings.setWatched),
    sources: SourceDeps(
      available: (r) => weather.rowSources(r).isNotEmpty,
      needsKey: (r) => weather.rowSources(r).any((c) => !weather.keyReady(c)),
      setOn: weather.setRowOn,
    ),
    navigation: NavigationDeps(
      route: (id) async => (sources.core ?? (throw StateError('The search core is not available'))).mapRouteById(id),
      guiding: () => nav.guiding,
      preview: nav.previewSnapshot,
      start: nav.start,
      show: nav.requestMap,
    ),
  );
  // The map's search, routes and turn-by-turn guidance: on the core when it has them, on recorded answers for screenshots
  // (--dart-define=CACHE_NAV_DEMO=<folder>), never both.
  // The meaning search of the map: the query is embedded on the phone with the same model the places pack was built with.
  late final PhoneQueryEmbedder queryEmbedder = PhoneQueryEmbedder(
    modelsDir: () async => Directory('${((Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory()).path}/models'),
  );
  late final NavState nav = NavState(
    backend: const String.fromEnvironment('CACHE_NAV_DEMO').isNotEmpty
        ? DemoMapBackend(Directory(const String.fromEnvironment('CACHE_NAV_DEMO')))
        : CoreMapBackend(() => sources.core!, embedder: queryEmbedder.call, isAvailable: () => sources.coreReady && sources.openedExtra.containsKey('routing')),
    location: location,
    speaker: FlutterTtsSpeaker(),
    positionSource: GeolocatorNavSource(),
    fmt: Fmt(unitsForLocale(WidgetsBinding.instance.platformDispatcher.locale)),
    onFollow: (m) => maps.setFollow(m),
    notifications: PlatformNotificationAccess(),
  );
  CacheThemeId _applied = CacheThemeId.dark;

  /// The search core has finished starting (opened or failed); with [AppState.started] it ends the launch screen.
  bool _coreDone = false;

  @override
  void initState() {
    super.initState();
    ModelDownloads.shared = modelDownloads;
    app.addListener(_onApp);
    applySystemUi(_applied);
    sources.whenCoreReady().then((_) {
      if (mounted) setState(() => _coreDone = true);
    });
    app.init();
    final settingsRead = settings.init();
    settingsRead.then((_) => webSearch.init());
    // The weather part starts once the settings are read and the core is open; then background updates are kept in step with what is
    // switched on, and the place the background runs use is kept up to date.
    final supportRead = getApplicationSupportDirectory().then((d) => _supportPath = d.path);
    settingsRead.then((_) => supportRead).then((_) => sources.whenCoreReady()).then((core) async {
      if (core == null) return;
      await LocalAlertNotifier.instance.init();
      await weather.start();
      weather.addListener(_onWeather);
      _onWeather();
      actionRegistry.addListener(_installActions);
      await appActions.publishAll();
    });
    // A place saved on the map joins the Places list the watch actions name.
    nav.events.listen((e) {
      if (e is PlaceSaved) appActions.publishWatch();
    });
    location.addListener(_rememberPlace);
    settingsRead.then((_) => sharing.init());
    settingsRead.then((_) => regions.init());
    layout.init();
    sources.init();
    browse.init();
    video.init();
    location.init();
    maps.init();
    _openHistory();
  }

  ConversationStore? _store;
  int? _backendGeneration;
  bool? _scheduledFor;
  bool _askedNotifications = false;
  String? _lastPlaceSaved;

  /// Background updates run while something is switched on; the first time, notification permission is asked for (alert pop-ups).
  Future<void> _onWeather() async {
    final on = weather.enabledSources.isNotEmpty;
    if (_scheduledFor != on) {
      _scheduledFor = on;
      weather.backgroundUpdates = await scheduleBackgroundUpdates(anythingOn: on);
      if (on && !_askedNotifications) {
        _askedNotifications = true;
        await PlatformNotificationAccess().request();
      }
    }
    _rememberPlace();
  }

  void _installActions() {
    actCore.install(actionRegistry.definitions, actionRegistry.run).catchError((_) {});
  }

  /// Keeps the phone's last position and the downloaded regions where a background run can read them.
  void _rememberPlace() {
    final support = _supportPath;
    if (support == null) return;
    final f = location.fix;
    final last = LastPlace(
      here: f == null ? null : (lat: double.parse(f.lat.toStringAsFixed(3)), lon: double.parse(f.lon.toStringAsFixed(3))),
      regions: regionsFromAreas([for (final l in maps.catalogueLayers) ...maps.areasOfCard(l)]),
    );
    final key = jsonEncode(last.toJson());
    if (key == _lastPlaceSaved) return;
    _lastPlaceSaved = key;
    last.write(LastPlace.fileIn(Directory(support)));
  }

  /// The conversations live in the app's private storage.
  Future<void> _openHistory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      _store = ConversationStore.open('${dir.path}/conversations.db');
      chat.attachStore(_store!);
    } catch (_) {
      // Without the database the app still answers; it just keeps no history.
    }
  }

  void _onApp() {
    if (app.theme != _applied) {
      _applied = app.theme;
      applySystemUi(_applied);
    }
    // The chat talks to whatever model is active. A different model carries on the open conversation.
    if (_backendGeneration != app.modelGeneration) {
      _backendGeneration = app.modelGeneration;
      chat.setBackend(
        app.active == null ? null : LocalLlamaBackend(app.session),
        modelName: app.active == null ? '' : app.displayName(app.active!),
      );
    }
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    weather.removeListener(_onWeather);
    location.removeListener(_rememberPlace);
    app.session.dispose();
    browse.dispose();
    nav.dispose();
    queryEmbedder.dispose();
    sources.dispose();
    video.dispose();
    layout.dispose();
    location.dispose();
    regions.dispose();
    maps.dispose();
    webSearch.dispose();
    weather.dispose();
    sharing.dispose();
    settings.dispose();
    _store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'Cache',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(app.theme),
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [
            child!,
            IgnorePointer(
              ignoring: app.started && _coreDone,
              child: AnimatedOpacity(
                opacity: app.started && _coreDone ? 0 : 1,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                child: const LaunchScreen(),
              ),
            ),
          ],
        ),
        home: Shell(
          app: app,
          chat: chat,
          sources: sources,
          location: location,
          maps: maps,
          video: video,
          browse: browse,
          nav: nav,
          layout: layout,
          hub: hub,
        ),
      ),
    );
  }
}

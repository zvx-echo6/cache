import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace;
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'actions/act_core.dart';
import 'actions/action_registry.dart';
import 'actions/app_actions.dart';
import 'actions/setup_reader.dart';
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
import 'nav/notification_access.dart';
import 'nav/nav_position.dart';
import 'nav/nav_state.dart';
import 'nav/speaker.dart';
import 'nav/units.dart';
import 'notebook/notebook_publisher.dart';
import 'notebook/notebook_model.dart';
import 'notebook/notebook_state.dart';
import 'notebook/places.dart';
import 'maps/ui/place_map.dart';
import 'notebook/media.dart' show storePhoto;
import 'notebook/sync/connections.dart';
import 'screens/pin_screen.dart';
import 'settings/app_pin.dart';
import 'maps/user_layers.dart';
import 'screens/notebooks/notebook_screen.dart' show NotebookDeps;
import 'screens/notebooks/notebooks_screen.dart' show NotebooksScreen;
import 'screens/notebooks/places_screen.dart' show PlaceNotebookDeps;
import 'regions/region_catalogue.dart';
import 'regions/regions_state.dart';
import 'search/core_numbering.dart';
import 'settings/app_settings.dart';
import 'models/model_downloads.dart';
import 'models/search_model.dart';
import 'settings/data_kinds.dart';
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
import 'weather/place_alerts.dart';
import 'weather/places.dart';
import 'weather/weather_state.dart';
import 'maps/layers/starter_defs.dart' show readLiveSourceAssets;
import 'search/numbering_state.dart';
import 'search/core_tool_host.dart';
import 'sources/libraries_state.dart';
import 'sources/sources_state.dart';
import 'video/video_state.dart';
import 'screens/settings/about_pages.dart' show kCreditsAsset;
import 'browse/browse_screen.dart';
import 'regions/ui/regions_screen.dart';
import 'screens/models_screen.dart';
import 'screens/shell.dart';
import 'screens/videos/library_screen.dart' as videos show LibraryScreen;
import 'theme.dart';
import 'keyboard.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The credits (native libraries, Rust crates, data sources, art) join the licences Flutter lists for the packages.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Cache: libraries, data and art'], await rootBundle.loadString(kCreditsAsset));
  });
  // Background updates of weather, alerts and fires (scheduled once something is switched on; see scheduleBackgroundUpdates).
  if (Platform.isAndroid || Platform.isIOS) backgroundReady = Workmanager().initialize(cacheBackgroundDispatcher);
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
  late final BrowseState browse = BrowseState(sources: sources, policy: policy, libraries: libraries);
  // Libraries (Qdrant collections the core searches): added from a file or a link, in their own folder beside the ZIMs.
  late final LibrariesState libraries = LibrariesState(
    sources: sources,
    policy: policy,
    // The setup guide ships compressed in the assets; it is copied out to be added like any library file.
    bundledGuide: () async {
      try {
        final bytes = await rootBundle.load('assets/guide/cache-guide.cache-library');
        final f = File('${(await getTemporaryDirectory()).path}/cache-guide.cache-library');
        await f.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
        return f;
      } catch (_) {
        return null;
      }
    },
  );
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
  late final ModelDownloads modelDownloads = ModelDownloads(app: app, policy: policy, searchModel: kSearchModel.file);
  // The search model (bge-m3): one copy embeds the queries of the map search, the library search and the assistant's search.
  // It comes with the first chat model and sits in the models folder.
  late final SearchModel searchModel = SearchModel(
    app: app,
    downloads: modelDownloads,
    modelsDir: () async => Directory('${((Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory()).path}/models'),
  );
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
    onPlacesChanged: () => appActions.publishWatch(),
    told: ToldStore.lazy(() async => File('${(await getApplicationSupportDirectory()).path}/alerts_told.json')),
  )..placeAlerts = placeAlerts;
  /// Each place's own alert rule (Places notebook, the place's gear).
  late final PlaceAlerts placeAlerts = PlaceAlerts(() async => File('${(await getApplicationSupportDirectory()).path}/$kPlaceAlertsFile'));
  /// The app's support folder, read at start (the alert memory and the last place live there).
  String? _supportPath;

  /// The phone's temporary folder, read at start (Clean up empties it).
  String? _tempPath;

  Directory? _support(String name) => _supportPath == null ? null : Directory('$_supportPath/$name');
  Directory? _beside(Directory? dir, String name) => dir == null ? null : Directory('${dir.path}${Platform.pathSeparator}$name');

  /// What Cache keeps on the phone, by kind, and the folders that hold it: Storage measures this list and Sharing shares it, so they
  /// agree. A folder in `shared` has a fixed share id (the same kind on linked devices is one shared folder).
  late final List<DataKind> dataKinds = [
    DataKind(
      id: 'library',
      label: 'Library',
      icon: Icons.menu_book_outlined,
      shared: () => {'library': sources.zimsDir, 'libraries': libraries.dir},
      // Search indexes are built on each device.
      local: () => [sources.indexesDir],
      count: () => sources.zims.length + libraries.libraries.length,
      list: () => BrowseScreen(browse: browse, active: true, layout: layout),
    ),
    DataKind(
      id: 'models',
      label: 'Models',
      icon: Icons.memory,
      shared: () => {'models': app.modelsDir},
      count: () => app.models.length + (app.searchModel == null ? 0 : 1),
      list: () => ModelsScreen(app: app),
    ),
    DataKind(
      id: 'regions',
      label: 'Regions',
      icon: Icons.map_outlined,
      // The layer engine's tiles, the region engine's routing and places, and the legacy hand-placed packs folder.
      shared: () => {
        'maps': sources.layersSection['dir'] is String ? Directory(sources.layersSection['dir'] as String) : null,
        'regions': _support('regions'),
        'packs': _beside(sources.zimsDir?.parent, 'packs'),
      },
      count: () => regions.local.length,
      list: () => RegionsScreen(regions: regions, initialTab: 1),
    ),
    DataKind(
      id: 'videos',
      label: 'Videos and weather',
      icon: Icons.smart_display_outlined,
      shared: () => {'videos': video.dir},
      // Weather is fetched by each device.
      local: () => [_support('live-catalogues'), weather.liveFolder],
      list: () => videos.LibraryScreen(video: video),
    ),
    DataKind(
      id: 'notebooks',
      label: 'Notebooks',
      icon: Icons.book_outlined,
      // The notebooks as Markdown files with their photos, which notebook sync keeps the same on linked devices.
      shared: () => {'notebooks': _support(kNotebookShareDir)},
      // The notebooks themselves: their database, photos and files.
      local: () => [_support('notebook')],
      count: () => notebooks.notebooks.length,
      list: () => NotebooksScreen(deps: notebookDeps),
    ),
    DataKind(
      id: 'shared',
      label: 'Shared folder',
      icon: Icons.folder_shared_outlined,
      shared: () => {'shared': _beside(sources.zimsDir?.parent, 'Shared')},
      inStorage: false,
    ),
  ];

  // Sharing and sync: Cache's own folders, by kind.
  late final SharingState sharing = SharingState(
    policy: policy,
    supportDir: getApplicationSupportDirectory,
    deviceName: Platform.isAndroid ? 'Android phone' : (Platform.isIOS ? 'iPhone' : Platform.localHostname),
    kinds: dataKinds,
  );
  // Regions and downloads: the region catalogue (kept in the support folder so it works offline once seen), the core's road routing
  // tiles and the map layers' area downloads. When the ready regions change, the routing the search core opens with is built again.
  // When a region's places are merged or removed, the search core reads the places again and an open map search runs again.
  late final RegionsState regions = RegionsState(
    policy: policy,
    supportDir: getApplicationSupportDirectory,
    catalogue: RegionCatalogue(dir: () async => Directory('${(await getApplicationSupportDirectory()).path}/region-catalogue')),
    maps: maps,
    onPlacesChanged: () async {
      try {
        await sources.core?.refreshPlaces();
      } catch (_) {
        // A core older than cs_places_refresh reads the merged database on its own.
      }
      await nav.placesChanged();
    },
  );
  late final SettingsHub hub = SettingsHub(
    settings: settings,
    policy: policy,
    webSearch: webSearch,
    weather: weather,
    sharing: sharing,
    regions: regions,
    storage: StorageUsage(
      kinds: [for (final k in dataKinds) if (k.inStorage) k],
      freeIn: () => app.modelsDir ?? sources.zimsDir,
      // Unfinished downloads (ZIMs, libraries, models) and the temporary folder.
      leftovers: () => [
        if (sources.zimsDir != null) sources.partialDir,
        _beside(libraries.dir, '.partial'),
        _beside(app.modelsDir, '.partial'),
        if (_tempPath != null) Directory(_tempPath!),
      ],
      busy: () =>
          browse.transfers.values.any((t) => t.phase != TransferPhase.failed && t.phase != TransferPhase.blockedByMobileData) ||
          modelDownloads.current != null ||
          (libraries.task?.running ?? false) ||
          video.tasks.any((t) => t.isActive),
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
        : CoreToolHost(core: sources.core!, numbering: numbering, queryVector: sources.toolQueryVector, runAction: actionRegistry.run),
    numberingState: CoreNumberingState(() => sources.core),
    locationKnown: () => chatLocation.known,
    prepareTurn: chatLocation.prepare,
    actions: actionRegistry,
    actCore: actCore,
  );
  // What the assistant can do through the act tool: each module's actions, handed back by the core for read and open (host_run) and
  // run by a tap on a confirm card for change. The chat installs a conversation's definitions in the core when it starts.
  final ActionRegistry actionRegistry = ActionRegistry();
  late final ActCore actCore = CoreActCore(() => sources.core);
  late final AppActions appActions = AppActions(
    registry: actionRegistry,
    setup: setupDepsFrom(
      settings: settings,
      policy: policy,
      regions: regions,
      sources: sources,
      libraries: libraries,
      weather: weather,
      webSearch: webSearch,
      app: app,
      location: location,
    ),
    places: PlacesDeps(
      save: ({required name, required lat, required lon, label}) async {
        final core = await sources.whenCoreReady() ?? (throw StateError('The search core is not available'));
        final saved = await core.savePlace(name: name, lat: lat, lon: lon, label: label);
        // The core made its entry in the Places notebook.
        unawaited(notebooks.reload());
        return saved;
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
  // Notebooks: kept by the core (cs_notebook) in the support folder; their Log notebooks and the Journal publish act actions.
  late final NotebookState notebooks = NotebookState(
    backend: CoreNotebookBackend(sources.whenCoreReady),
    mediaDir: () async => Directory('${(await getApplicationSupportDirectory()).path}/notebook'),
  );
  late final NotebookPublisher notebookActions = NotebookPublisher(registry: actionRegistry, notebook: notebooks);
  late final PlaceChoices notebookPlaces = PlaceChoices(
    here: () async => switch (location.fix) {
      final f? => (lat: f.lat, lon: f.lon),
      null => null,
    },
    saved: () async => [
      for (final p in await (await sources.whenCoreReady())?.savedPlaces() ?? const [])
        NbPlace(lat: p.lat, lon: p.lon, label: p.name, key: p.key),
    ],
    search: (q) async {
      if (!nav.backend.available) return const [];
      final f = location.fix;
      final r = await nav.backend.search(q, near: f == null ? null : GeoPoint(f.lat, f.lon));
      return [for (final p in r.results) NbPlace(lat: p.lat, lon: p.lon, label: p.name)];
    },
  );
  late final NotebookDeps notebookDeps = NotebookDeps(
      notebook: notebooks, places: notebookPlaces, layout: layout, placesDeps: placeNotebookDeps, userLayers: userLayers, connections: connections, pin: appPin,
      shareAvailable: () => sharing.enabled);
  // Obsidian, Logseq and notebook sync: the folders the notebooks are kept in step with.
  late final NotebookConnections connections = NotebookConnections(
    notebook: notebooks,
    dir: () async => Directory('${(await getApplicationSupportDirectory()).path}/notebook-sync'),
    shareFolder: () => _supportPath == null ? null : Directory('$_supportPath/$kNotebookShareDir'),
    shareOn: () => sharing.running && sharing.shareOf('notebooks') != null,
    storePhoto: (id, bytes) async {
      await storePhoto(notebooks, bytes, id: id);
    },
  );
  Timer? _shareSync;
  // The optional app PIN: asked when Cache opens.
  late final AppPin appPin = AppPin(const SecureTokenStore());
  // The user's repeater lists and the lines and areas of files imported into Places notebooks (cs_userlayer*).
  late final UserLayersState userLayers = UserLayersState((call, [arg]) async {
    final core = await sources.whenCoreReady() ?? (throw StateError('The search core is not available'));
    return core.userLayers(call, arg);
  });
  // The Places notebooks: the saved places' weather and alert switches (watched-place ids), each place's alert rule, the place map
  // and directions.
  late final PlaceNotebookDeps placeNotebookDeps = PlaceNotebookDeps(
    watched: (id) => settings.watchedPlaces.contains(id),
    setWatched: settings.setWatched,
    alerts: placeAlerts,
    placesChanged: () async {
      await weather.placeChoices();
      weather.positionChanged();
      appActions.publishWatch();
      await nav.refreshSaved();
    },
    alertSetting: () => switch (settings.popUpFor) {
      PopUpFor.serious => 'Serious only, from Notifications',
      PopUpFor.all => 'All alerts, from Notifications',
      PopUpFor.none => 'None, from Notifications',
    },
    alertKinds: () => {for (final c in weather.enabledSources) c.id == 'alerts' ? 'alerts' : c.category}.where(kAlertKinds.containsKey).toList(),
    regions: () async => [for (final p in await weather.placeChoices()) if (p.kind == PlaceKind.region) (id: p.id, name: p.name)],
    hereOnMap: () => location.enabled,
    setHereOnMap: (on) => unawaited(location.setEnabled(on)),
    map: (context, pin, onPick) => PlaceMap(maps: maps, themeId: app.theme, pin: pin, onPick: onPick),
    directions: (p, name) {
      nav.openDirections(MapPlace(id: 'place:${p.lat},${p.lon}', type: 'place', name: name, kind: '', address: p.label ?? '', lat: p.lat, lon: p.lon, matched: '', formats: const {}));
      nav.requestMap();
    },
  );
  // The map's search, routes and turn-by-turn guidance: on the core when it has them, on recorded answers for screenshots
  // (--dart-define=CACHE_NAV_DEMO=<folder>), never both.
  late final NavState nav = NavState(
    backend: const String.fromEnvironment('CACHE_NAV_DEMO').isNotEmpty
        ? DemoMapBackend(Directory(const String.fromEnvironment('CACHE_NAV_DEMO')))
        : CoreMapBackend(() => sources.core!, embedder: searchModel.embedder.call, isAvailable: () => sources.coreReady && sources.openedExtra.containsKey('routing')),
    location: location,
    speaker: FlutterTtsSpeaker(),
    positionSource: GeolocatorNavSource(),
    fmt: Fmt(unitsForLocale(WidgetsBinding.instance.platformDispatcher.locale)),
    onFollow: (m) => maps.setFollow(m),
  );
  CacheThemeId _applied = CacheThemeId.dark;

  /// The search core has finished starting (opened or failed); with [AppState.started] it ends the launch screen.
  bool _coreDone = false;

  @override
  void initState() {
    super.initState();
    ModelDownloads.shared = modelDownloads;
    // The meaning search of the map uses the search model to embed the query; so do the library search and the assistant.
    SearchModel.shared = searchModel;
    sources.embedding = searchModel;
    app.addListener(_onApp);
    // Back on the screen: a weather update that is due runs now (iOS runs background tasks only when it chooses).
    _lifecycle = AppLifecycleListener(onResume: () {
      unawaited(weather.updateIfDue(kBackgroundEvery));
      unawaited(connections.syncAll());
    });
    appPin.init();
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
    getTemporaryDirectory().then((d) => _tempPath = d.path).catchError((_) => '');
    settingsRead.then((_) => supportRead).then((_) => sources.whenCoreReady()).then((core) async {
      if (core == null) return;
      await LocalAlertNotifier.instance.init();
      await weather.start();
      weather.addListener(_onWeather);
      _onWeather();
      unawaited(weather.updateIfDue(kBackgroundEvery));
      await appActions.publishAll();
      // Notebooks are published after the app's own actions, so they are listed last.
      await notebooks.start();
      notebookActions.start();
      unawaited(userLayers.reload());
      // Connected folders follow each saved change; notebook sync also looks for what linked devices sent every 2 minutes.
      final before = notebooks.onChanged;
      notebooks.onChanged = () {
        before?.call();
        connections.changed();
      };
      notebooks.privateSharing = connections;
      unawaited(connections.syncAll());
      _shareSync = Timer.periodic(const Duration(minutes: 2), (_) {
        if (sharing.running && sharing.shareOf('notebooks') != null) unawaited(connections.syncAll());
      });
    });
    // A place saved on the map joins the Places list the watch actions name.
    nav.events.listen((e) {
      if (e is PlaceSaved) {
        appActions.publishWatch();
        unawaited(notebooks.reload());
      }
      // A place removed from its card is no longer watched; the core deleted its entry in the Places notebook.
      if (e is PlaceRemoved) {
        settings.forgetWatched(['place:${e.key}']);
        unawaited(placeAlerts.forget('place:${e.key}'));
        appActions.publishWatch();
        unawaited(notebooks.reload());
      }
    });
    location.addListener(_rememberPlace);
    // Home's Weather and Alerts cards and the place lists follow "Where I am" as its position arrives and moves.
    location.addListener(weather.positionChanged);
    nav.addListener(_onNav);
    settingsRead.then((_) => sharing.init());
    settingsRead.then((_) => regions.init());
    layout.init();
    sources.init();
    libraries.init();
    browse.init();
    video.init();
    location.init();
    maps.init();
    _openHistory();
  }

  ConversationStore? _store;
  late final AppLifecycleListener _lifecycle;
  int? _backendGeneration;
  bool? _scheduledFor;
  bool _askedNotifications = false;
  String? _lastPlaceSaved;

  /// Background updates run while something is switched on; the first time, notification permission is asked for (alert pop-ups).
  Future<void> _onWeather() async {
    final on = weather.enabledSources.isNotEmpty;
    if (_scheduledFor != on) {
      _scheduledFor = on;
      await scheduleBackgroundUpdates(anythingOn: on);
      if (on && !_askedNotifications) {
        _askedNotifications = true;
        await PlatformNotificationAccess().request();
      }
    }
    _rememberPlace();
  }

  /// A map search waiting for its area's places keeps the regions' status read, so it runs again when they land.
  void _onNav() {
    if (nav.placesState == PlacesState.fetching) regions.watchPlaces();
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
    _lifecycle.dispose();
    _shareSync?.cancel();
    connections.dispose();
    app.removeListener(_onApp);
    weather.removeListener(_onWeather);
    location.removeListener(_rememberPlace);
    location.removeListener(weather.positionChanged);
    nav.removeListener(_onNav);
    app.session.dispose();
    browse.dispose();
    nav.dispose();
    searchModel.dispose();
    libraries.dispose();
    sources.dispose();
    video.dispose();
    layout.dispose();
    location.dispose();
    regions.dispose();
    maps.dispose();
    webSearch.dispose();
    weather.dispose();
    sharing.dispose();
    notebookActions.dispose();
    notebooks.dispose();
    settings.dispose();
    _store?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, appPin]),
      builder: (context, _) => MaterialApp(
        title: 'Cache',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(app.theme),
        actions: keyboardActions,
        scrollBehavior: const CacheScrollBehavior(),
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
        home: appPin.locked ? PinLockScreen(pin: appPin) : Shell(
          app: app,
          chat: chat,
          sources: sources,
          location: location,
          chatLocation: chatLocation,
          maps: maps,
          video: video,
          browse: browse,
          nav: nav,
          layout: layout,
          hub: hub,
          notebooks: notebookDeps,
        ),
      ),
    );
  }
}

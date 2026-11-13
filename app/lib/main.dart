import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace, SearchCore;
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actions/act_core.dart';
import 'actions/action_registry.dart';
import 'actions/app_actions.dart';
import 'actions/setup_reader.dart';
import 'app_fs.dart';
import 'app_state.dart';
import 'brand.dart';
import 'browse/browse_state.dart';
import 'car/car_bridge.dart';
import 'car/car_drive.dart';
import 'car/car_pins.dart';
import 'browse/web/device_api.dart';
import 'browse/web/device_fetch.dart';
import 'browse/web/device_library.dart';
import 'browse/web/build_api.dart' show HttpBuildApi;
import 'desktop/desktop_theme.dart';
import 'linked_folders/linked_folders.dart' show LinkedFolderApi, LinkedFolderController;
import 'browse/web/build_state.dart' show BuildController;
import 'browse/web/local_files.dart' show createBrowserUploader, createRawUploader;
import 'chat/ask_focus.dart';
import 'chat/chat_controller.dart';
import 'chat/chat_location.dart';
import 'chat/local_llama_backend.dart';
import 'chat/prompt_read_ahead.dart';
import 'chat/system_prompt.dart' show isoWithOffset;
import 'discover/discover_state.dart' show kDiscoverUrl;
import 'history/conversation_store.dart';
import 'history/store_open.dart';
import 'package:cache_ocr/cache_ocr.dart' show deviceOcrEngine;

import 'library/add_pdf/add_pdf_calls.dart';
import 'library/add_pdf/add_pdf_engines.dart';
import 'library/add_pdf/add_pdf_state.dart';
import 'library/add_pdf/watch_background.dart';
import 'library/add_pdf/watch_folders.dart';
import 'background/background_dispatcher.dart';
import 'background/background_lock.dart';
import 'library/cds_shelf_source.dart' show libraryDeviceIdShared;
import 'library/library_device.dart';
import 'layout/layout_state.dart';
import 'location/location_service.dart';
import 'maps/layers/core_layer_engine.dart';
import 'maps/maps_state.dart';
import 'car/car_overlay.dart';
import 'car/car_support.dart';
import 'car/route_pushes.dart';
import 'nav/demo_backend.dart';
import 'nav/elevation/route_elevation.dart';
import 'nav/guidance_wakelock.dart';
import 'nav/nav_backend.dart';
import 'nav/notification_access.dart';
import 'nav/nav_position.dart';
import 'nav/nav_state.dart';
import 'nav/speaker.dart';
import 'nav/units.dart';
import 'net/fetch.dart' show fetchText;
import 'notebook/notebook_publisher.dart';
import 'notebook/notebook_model.dart';
import 'notebook/notebook_state.dart';
import 'notebook/places.dart';
import 'maps/ui/place_map.dart';
import 'notebook/media.dart' show storePhoto;
import 'notebook/sync/connections.dart';
import 'screens/notebooks/icon_picker.dart' show MapIconSetup;
import 'screens/pin_screen.dart';
import 'settings/app_pin.dart';
import 'maps/user_layers.dart';
import 'screens/notebooks/notebook_screen.dart' show NotebookDeps;
import 'screens/notebooks/notebooks_screen.dart' show NotebooksScreen;
import 'screens/notebooks/places_screen.dart' show PlaceNotebookDeps;
import 'regions/offroad_catalogue.dart';
import 'regions/region_catalogue.dart';
import 'regions/regions_state.dart';
import 'search/core_numbering.dart';
import 'settings/app_settings.dart';
import 'models/model_downloads.dart';
import 'models/hf_hub.dart' show HfFile;
import 'models/recommendations.dart' show RecommendedModels;
import 'models/search_model.dart';
import 'pdf/index/pdf_index_app.dart';
import 'pdf/index/pdf_index_state.dart';
import 'pdf/index/pdf_pages.dart' show pdfStepScale;
import 'settings/data_kinds.dart';
import 'settings/data_policy.dart';
import 'settings/hub.dart';
import 'settings/storage_usage.dart';
import 'settings/web_search_setup.dart';
import 'sharing/link_inbox.dart';
import 'sharing/share_items.dart';
import 'sharing/settings_sync.dart';
import 'sharing/sharing_state.dart';
import 'sharing/synced_settings.dart';
import 'video/token_store.dart';
import 'package:workmanager/workmanager.dart';

import 'weather/alert_notifier.dart';
import 'weather/alert_watch.dart';
import 'weather/background.dart';
import 'weather/foreground_updates.dart';
import 'weather/live_core.dart';
import 'weather/place_alerts.dart';
import 'weather/places.dart';
import 'weather/weather_state.dart';
import 'maps/layers/starter_defs.dart' show readLiveSourceAssets;
import 'search/numbering_state.dart';
import 'search/core_tool_host.dart';
import 'settings/space.dart' show Space;
import 'search/pdf_index_work.dart';
import 'platform/battery.dart' show kBatteryChannel;
import 'search/index_throttle.dart';
import 'search/core_index_calls.dart';
import 'platform/app_log.dart';
import 'platform/app_log_io.dart';
import 'platform/memory.dart';
import 'platform/model_release.dart';
import 'platform/phone_screen.dart';
import 'search/index_scheduler.dart';
import 'search/index_status.dart' show indexItemDetail;
import 'search/indexes_share.dart';
import 'sources/libraries_state.dart';
import 'sources/sources_state.dart';
import 'video/caption_search.dart' show CoreCaptionSearch;
import 'video/video_state.dart';
import 'screens/settings/about_pages.dart' show kCreditsAsset;
import 'browse/browse_screen.dart';
import 'regions/ui/regions_screen.dart';
import 'screens/models_screen.dart';
import 'screens/shell.dart';
import 'screens/videos/library_screen.dart' as videos show LibraryScreen;
import 'theme.dart';
import 'keyboard.dart';
import 'platform.dart' as plat;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Cache's own log (Settings > Storage > Advanced): errors as they happen, and what happened since the last start.
  logDartErrors();
  unawaited(openAppLog());
  // The credits (native libraries, Rust crates, data sources, art) join the licences Flutter lists for the packages.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Cache: libraries, data and art'], await rootBundle.loadString(kCreditsAsset));
  });
  // Background updates of weather, alerts and fires (scheduled once something is switched on; see scheduleBackgroundUpdates).
  if (plat.isAndroid || plat.isIOS) backgroundReady = Workmanager().initialize(cacheBackgroundDispatcher);
  // A cachelink: link the app was opened with, or that arrives while it runs (the native side holds it; see LinkInbox).
  unawaited(linkInbox.start());
  runApp(const CacheApp());
}

class CacheApp extends StatefulWidget {
  const CacheApp({super.key});

  @override
  State<CacheApp> createState() => _CacheAppState();
}

class _CacheAppState extends State<CacheApp> {
  late final AppState app = AppState(
    // No phone screen by the time the start would load the chat model: on Android that is a start by the car with the phone
    // app closed (the engine starts with no screen and only an activity says otherwise). The model then waits for the
    // phone's screen ([_onPhoneScreen]).
    startedWithNoPhoneScreen: () => plat.isAndroid && noPhoneScreen(WidgetsBinding.instance.lifecycleState),
  );
  late final SourcesState sources = SourcesState();
  late final BrowseState browse = BrowseState(sources: sources, policy: policy, libraries: libraries, device: device);
  // In a browser the Library lives on the device the browser is signed in to: what is installed, the downloads it runs (they go on
  // with the tab closed) and the uploads from this computer. Null on a phone.
  late final DeviceLibrary? device = _makeDevice();

  DeviceLibrary? _makeDevice() {
    if (!plat.isWeb) return null;
    final api = HttpDeviceApi();
    deviceFetchApi = api;
    final fs = createAppFs();
    final linkedFolders = LinkedFolderController(api: LinkedFolderApi());
    final d = DeviceLibrary(
      api: api,
      fs: fs,
      uploader: createBrowserUploader(),
      onItemsChanged: () => sources.refresh(),
      build: BuildController(api: HttpBuildApi(), uploader: createRawUploader(), fs: fs, linkedFolders: linkedFolders),
    );
    sources.removeOnDevice = (z) => d.remove('zim', z.fileName);
    d.addListener(() => sources.setDeviceSizes({for (final i in d.items) if (i.kind == 'zim') i.name: i.bytes}));
    return d;
  }
  // Libraries (Qdrant collections the core searches): added from a file or a link, in their own folder beside the ZIMs.
  late final LibrariesState libraries = LibrariesState(
    sources: sources,
    policy: policy,
    device: device,
    // The setup guide ships compressed in the assets; it is copied out to be added like any library file.
    bundledGuide: () async {
      if (plat.isWeb) return null; // a browser has no temporary folder to copy the guide into
      try {
        final bytes = await rootBundle.load('assets/guide/cache-guide.cache-library');
        final f = File('${await appTempPath()}/cache-guide.cache-library');
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
    modelsDir: () async => Directory('${await appFilesPath()}/models'),
  );
  late final PdfIndexState pdfIndex = appPdfIndex(sources: sources);
  late final MapsState maps = MapsState(
    engine: CoreLayerEngine(
      openCore: sources.whenCoreReady,
      layersConfig: () => sources.layersSection,
      policy: policy,
      // Size estimates on a core of their own, so they never queue in front of the map, the Library and the reader.
      openPlanner: (layers) => SearchCore.open(const [], extra: {'layers': layers}),
    ),
  );
  late final VideoState video = VideoState(
    policy: policy,
    captionSearch: CoreCaptionSearch(() => sources.core),
    indexesDir: () async => Directory('${await appSupportPath()}/$kIndexesDirName'),
  );
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
    catalogueDir: () async => Directory('${await appSupportPath()}/live-catalogues'),
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
    regions: () => watchRegionsOf(regions.local),
    notifier: LocalAlertNotifier.instance,
    onPlacesChanged: () => appActions.publishWatch(),
    told: ToldStore.lazy(() async => File('${await appSupportPath()}/alerts_told.json')),
  )..placeAlerts = placeAlerts;
  /// Each place's own alert rule (Places notebook, the place's gear).
  late final PlaceAlerts placeAlerts = PlaceAlerts(() async => File('${await appSupportPath()}/$kPlaceAlertsFile'));
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
      // Search indexes are built on each device: the ZIMs' in a folder of their own, each library's inside the library.
      local: () => [sources.indexesDir, _support(kIndexesDirName)],
      notShared: const {'library': kZimNotShared, 'libraries': kLibraryNotShared},
      count: () => sources.zims.length + libraries.libraries.length,
      list: () => BrowseScreen.inHub(browse: browse, active: true, layout: layout, hub: hub),
      items: () => libraryItems(sources, libraries),
      remoteItem: libraryRemoteItem,
      alongside: libraryAlongside,
    ),
    DataKind(
      id: 'models',
      label: 'Models',
      icon: Icons.memory,
      shared: () => {'models': app.modelsDir},
      count: () => app.models.length + (app.searchModel == null ? 0 : 1),
      list: () => ModelsScreen(app: app),
      items: () => modelItems(app),
      remoteItem: modelRemoteItem,
    ),
    DataKind(
      id: 'regions',
      label: 'Regions',
      icon: Icons.map_outlined,
      // The layer engine's tiles and the region engine's routing, places and off-road.
      shared: () => {
        'maps': sources.layersSection['dir'] is String ? Directory(sources.layersSection['dir'] as String) : null,
        'regions': _support('regions'),
      },
      // What each device makes for itself in those folders (fetched indexes, the viewed-tile cache, SQLite's -shm) never syncs.
      notShared: const {'maps': kMapLayersNotShared, 'regions': kRegionsNotShared},
      count: () => regions.local.length,
      list: () => RegionsScreen(regions: regions, initialTab: 1),
      shareLabel: 'Maps',
      items: () => mapItems(maps.engine, regions),
      itemDepth: const {'maps': 2},
      remoteItem: (share, path, bytes) => mapRemoteItem(maps.engine, share, path, bytes),
    ),
    DataKind(
      id: 'videos',
      label: 'Videos and weather',
      icon: Icons.smart_display_outlined,
      shared: () => {'videos': video.dir},
      // Weather is fetched by each device.
      local: () => [_support('live-catalogues'), weather.liveFolder],
      list: () => videos.LibraryScreen(video: video),
      shareLabel: 'Videos',
      items: () => videoItems(video),
      itemDepth: const {'videos': 3},
      remoteItem: videoRemoteItem,
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
      items: () => notebookItems(notebooks),
      remoteItem: notebookRemoteItem,
      setPrivate: (it, on) => setNotebookShared(notebooks, it, on),
    ),
    // The Shared folder of 1.0 is gone: SharingState stops sharing it at start (retiredShares), and its files stay where they are.
  ];

  // Sharing and sync: Cache's own folders, by kind.
  late final SharingState sharing = SharingState(
    policy: policy,
    supportDir: () async => Directory(await appSupportPath()),
    deviceName: plat.isAndroid ? 'Android device' : (plat.isIOS ? 'iPhone' : plat.hostName),
    kinds: dataKinds,
    // The search indexes sync whenever sharing is set up, whatever kinds are ticked; each linked device fetches only the indexes
    // of the sources it has (setOnly, kept in step with the core's sources: _syncIndexesOnly).
    always: [
      AlwaysShared(
        id: kIndexesShareId,
        name: 'Search indexes',
        dir: () => _support(kIndexesDirName),
        exclude: kIndexesNotShared,
        localDeletes: kIndexesLocalDeletes,
        last: kIndexesLast,
        hidden: kIndexesHidden,
      ),
    ],
    // Kept only with some linked devices and never listed: the settings log (Match and Send mine, governed by each device's page)
    // and the person's Bookshelves log (their own devices: Match only).
    linkShares: [
      LinkShare(id: kSettingsShareId, name: 'Settings', dir: () => _support(kSettingsShareDir), modes: kSettingsShareModes),
      LinkShare(id: kBookshelvesShareId, name: 'Bookshelves', dir: () => _support(kBookshelvesDir), modes: kBookshelvesShareModes),
    ],
  );

  late final PlaceNameCache _placeNames = PlaceNameCache(weather, settings);

  /// Settings between linked devices, per setting (each linked device's page in Sharing and sync): what goes is
  /// sharing/synced_settings.dart; the keys ticked for a device go to it alone, held by the sync engine in memory.
  late final SettingsSync settingsSync = SettingsSync(
    sharing: sharing,
    settings: appSyncedSettings(
      app: app,
      layout: layout,
      settings: settings,
      maps: maps,
      weather: weather,
      placeNames: () => _placeNames.names,
      recommended: () => RecommendedModels.shared.models,
    ),
    keys: () => appSyncedKeys(weather: weather, webSearch: webSearch, secrets: const SecureTokenStore()),
    storeKey: (name, value) => keepSyncedKey(name, value, weather: weather, webSearch: webSearch),
    dir: () async => _support(kSettingsShareDir),
    // Only when the person taps Download: a model a linked device uses is never downloaded on its own.
    downloadModel: (d) => modelDownloads.start(HfFile(
      repo: d['repo'] as String? ?? '',
      path: d['path'] as String? ?? '',
      size: (d['size'] as num?)?.toInt() ?? 0,
      sha256: d['sha256'] as String?,
      revision: d['revision'] as String? ?? 'main',
      url: d['url'] is String ? Uri.tryParse(d['url'] as String) : null,
    )),
    placesHere: () async => {for (final p in await weather.placeChoices()) if (p.id.startsWith('place:')) p.id.substring(6)},
  );

  /// The one scheduler of automatic index work (search/index_scheduler.dart): the core's builds and seals (behind
  /// IndexCoreCalls.none until the core has index_source and index_seal) and the ZIMs' PDFs (the PDF state queues nothing by
  /// itself: its autoStart is null). It runs while the app is open, with the battery and storage rules, against the storage of
  /// the indexes folder.
  /// The core's index work (captions and EPUBs of ZIMs, saved videos' captions) through cs_job_start("index_source").
  late final AppIndexCoreCalls coreIndexCalls = AppIndexCoreCalls(
    statuses: () => sources.statuses,
    videos: () => video.saved,
    startJob: (kind, params) async {
      final core = sources.core;
      return core == null ? null : CoreIndexJob(await core.startJob(kind, params));
    },
    indexesDir: () => _support(kIndexesDirName)?.path,
    videoDir: () => video.dirPath,
    duty: () => indexThrottle.duty,
    // a finished index job: the status is read again, so the Library and the queue say it is built
    onJobDone: () => unawaited(sources.refresh()),
  );

  /// The one throttle for background index work (search/index_throttle.dart): a control loop over heat, battery, the person
  /// using Cache and the model generating, applied to core jobs (cs_job_set) and to the PDF loop (indexPermit).
  late final IndexThrottle indexThrottle = IndexThrottle(
    mobile: !plat.isWeb && (Platform.isAndroid || Platform.isIOS),
    speed: settings.indexingNormal ? IndexSpeed.normal : IndexSpeed.gentle,
  );

  /// The models folder (the search model, bge-m3, is there).
  Future<Directory> _modelsDir() async => Directory('${await appFilesPath()}/models');

  /// Add PDF: one PDF becomes a book in the person's own library, by the core's ingest job, as index work the scheduler runs.
  late final AddPdfState addPdf = AddPdfState(
    calls: const CoreIngestCalls(),
    dir: () async => _support('ingest'),
    engines: _addPdfEngines,
    libraries: libraries,
    ocrEngine: deviceOcrEngine,
    // a background run is adding PDFs: it is asked to stop, and the jobs are offered again at the next look
    mayRun: () async {
      final l = _bgLock;
      return l == null || await l.takeOver(kAddPdfWork, wait: Duration.zero);
    },
    bookshelves: _addPdfShelves,
    // the book is in: the Library, Catalog and Bookshelves read the libraries again
    onDone: (_) => libraries.rescan(),
    wordsPending: (path) => libraries.wordsPendingAt(path),
  );

  /// The `bookshelves` argument of the core's ingest job: the Bookshelves folder, this device's id, the libraries.
  Future<Map<String, dynamic>?> _addPdfShelves() async {
    final dev = await libraryDeviceIdShared?.call();
    final dir = _support(kBookshelvesDir);
    if (dev == null || !validDeviceId(dev) || dir == null) return null;
    return {
      'dir': dir.path,
      'dev': dev,
      'libraries': [
        for (final l in libraries.libraries)
          if (libraries.idOf(l) case final id?) {'library_id': id, 'dir': l.path},
      ],
    };
  }

  /// The one lock with the background runs (background/background_lock.dart), once the support folder is known.
  BackgroundLock? _bgLock;
  Timer? _bgOpenTimer;
  int _bgSeen = 0;
  int _watchCount = -1;

  /// The app is open: the lock says so (and keeps saying so while it is).
  void _bgAppOpen() {
    _bgLock?.appOpened();
    _bgOpenTimer ??= Timer.periodic(BackgroundLock.refreshEvery, (_) => _bgLock?.appOpened());
  }

  /// Back at the front: a background run adding PDFs is stopped first; when one ran meanwhile, Add PDF's jobs and the watched
  /// folders are read again; then index work and the watched folders' check go on.
  Future<void> _backToFront() async {
    _atFront = true;
    final l = _bgLock;
    if (l != null) {
      _bgAppOpen();
      await l.takeOver(kAddPdfWork);
      final g = l.generation;
      if (g != _bgSeen) {
        _bgSeen = g;
        await addPdf.reload();
        await watchFolders.reload();
      }
    }
    if (!mounted) return;
    indexing.setOpen(true);
    // watched folders are checked each time Cache comes back to the front (not again within a minute)
    unawaited(watchFolders.checkAll(minGap: const Duration(minutes: 1)));
  }

  /// Cache is at the front (false from going to the back until it comes back).
  bool _atFront = true;

  /// To the back: once the index work that ran has really stopped and Add PDF's jobs are on disk, background runs may go ahead,
  /// and PDFs a watched folder found that are still to add are added in the background while charging (Android). Letting go
  /// earlier let a background slice start a PDF the app was still pausing (the job folder was still held; Pixel, 2026-11-10).
  void _toBack() {
    _atFront = false;
    unawaited(_toBackAfterPause());
  }

  Future<void> _toBackAfterPause() async {
    try {
      await backgroundHandOff(
        closed: indexing.closed,
        save: () async {
          await addPdf.save();
          await watchFolders.save();
        },
        atFront: () => _atFront,
        release: () {
          _bgOpenTimer?.cancel();
          _bgOpenTimer = null;
          _bgLock?.appClosed();
        },
        hasWork: () => Platform.isAndroid && addPdf.active.any((j) => j.watchId != null && !j.pausedByPerson),
        queueAdd: scheduleWatchAdd,
      );
      await _writeBackgroundContext();
    } catch (e, st) {
      logError('Background hand-off failed', error: e, stack: st);
    }
  }

  Future<void> _writeBackgroundContext() async {
    final s = _supportPath;
    if (s == null || !Platform.isAndroid) return;
    await writeWatchAddContext(support: s, bookshelves: await _addPdfShelves());
  }

  /// The watched folders changed: the background count runs while any are watched (Android).
  void _onWatchFolders() {
    final n = watchFolders.folders.length;
    if (_watchCount >= 0 && (n > 0) == (_watchCount > 0)) {
      _watchCount = n;
      return;
    }
    _watchCount = n;
    unawaited(scheduleWatchDetect(anyFolders: n > 0));
  }

  /// Watch a folder: new PDFs in a folder the person chose go through Add PDF by themselves. Checked when Cache opens; on Android
  /// also every [kWatchEvery] as index work (the indexing rules: charging, battery, heat). iOS checks only when Cache opens.
  late final WatchFoldersState watchFolders = WatchFoldersState(
    addPdf: addPdf,
    dir: () async => _support('ingest'),
    every: !plat.isWeb && Platform.isAndroid ? kWatchEvery : null,
  );

  Future<Map<String, dynamic>> _addPdfEngines() async => addPdfEngines(support: Directory(_supportPath ?? (await appSupportPath())), modelsDir: await _modelsDir());

  late final IndexScheduler indexing = IndexScheduler(
    throttle: indexThrottle,
    sources: [
      CoreIndexWork(coreIndexCalls),
      PdfIndexWork(pdfIndex..autoStart = null, () => [for (final z in sources.zims) pdfZimRef(sources, z)]),
      if (!plat.isWeb) addPdf,
      if (!plat.isWeb) watchFolders,
    ],
    space: () => Space.of(_support(kIndexesDirName)?.path ?? _supportPath ?? '.'),
  );

  void _kickIndexing() {
    if (!plat.isWeb) unawaited(indexing.kick());
  }

  bool _modelRunning = false;

  /// The model loading or writing an answer holds the index work: the scheduler stops what runs, so its memory is back first.
  /// The memory is logged as the model starts, to see what each takes.
  void _onChatForIndexing() {
    final on = chat.busy || app.loading != null;
    if (on && !_modelRunning) logInfo('Model starts (${app.loading != null ? 'loading' : 'answering'}); ${memoryNow()}');
    if (!on && _modelRunning) logInfo('Model done; ${memoryNow()}');
    _modelRunning = on;
    indexThrottle.setGenerating(on);
  }

  void _onSettingsForIndexing() => indexThrottle.setSpeed(settings.indexingNormal ? IndexSpeed.normal : IndexSpeed.gentle);

  /// Tells sharing which indexes this device fetches: those of the sources the core has open.
  void _syncIndexesOnly() {
    if (plat.isWeb) return;
    unawaited(sharing.setOnly(
      kIndexesShareId,
      indexesFetchOnly(sources.statuses, savedVideos: [for (final v in video.saved) v.captionsIndex?.sourceId ?? '${v.instance}/${v.uuid}']),
    ));
    unawaited(sharing.setNeverFetch(kIndexesShareId, indexesNeverFetch(sources.rejected)));
  }
  // Regions and downloads: the region catalogue (kept in the support folder so it works offline once seen), the core's road routing
  // tiles and the map layers' area downloads. When the ready regions change, the routing the search core opens with is built again.
  // When a region's places are merged or removed, the search core reads the places again and an open map search runs again.
  late final RegionsState regions = RegionsState(
    policy: policy,
    focus: askFocus,
    supportDir: () async => Directory(await appSupportPath()),
    catalogue: RegionCatalogue(dir: () async => Directory('${await appSupportPath()}/region-catalogue')),
    // Off-road: the published packs (offroad/current.json), each region downloads the ones that cover it.
    offroadCatalogue: OffroadCatalogue(dir: () async => Directory('${await appSupportPath()}/region-catalogue')),
    maps: maps,
    // A region downloads from where the phone is, outwards.
    position: () {
      final f = location.fix;
      return f == null ? null : (lat: f.lat, lon: f.lon);
    },
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
    settingsSync: settingsSync,
    regions: regions,
    indexing: indexing,
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
      // A ZIM download a crash or a force stop left is a paused download (Resume carries on), not a leftover.
      keep: () => browse.resumableParts,
      // Damaged downloads: the files whose published size and SHA-256 are kept (the off-road packs).
      manifests: () => regions.offroadManifests,
      busy: () =>
          browse.transfers.values.any((t) => t.phase != TransferPhase.failed && t.phase != TransferPhase.blockedByMobileData) ||
          modelDownloads.current != null ||
          (libraries.task?.running ?? false) ||
          video.tasks.any((t) => t.isActive),
    ),
  );
  late final LayoutState layout = LayoutState();
  /// Held while Ask generates an answer: background work (sync, downloads, indexing) starts nothing new meanwhile (chat/ask_focus.dart).
  late final AskFocus askFocus = AskFocus();
  late final ChatController chat = ChatController(
    focus: askFocus,
    // No Dart tools: the model only ever gets the core's. A question asked while the core starts waits for it.
    tools: const [],
    // Try again (or the next question) after the core could not start starts it again.
    waitForCore: () async => await sources.retryCore() != null,
    newNumbering: () =>
        sources.coreReady ? CoreNumbering(sources.newConversation) : null,
    // Once the core is open every tool it has installed is offered and runs through its dispatch (cs_tool).
    newHost: (numbering) => sources.core == null || numbering is! CoreNumbering
        ? null
        : CoreToolHost(core: sources.core!, numbering: numbering, queryVector: sources.toolQueryVector, runAction: actionRegistry.run),
    numberingState: CoreNumberingState(() => sources.core),
    locationKnown: () => chatLocation.turnKnown,
    prepareTurn: chatLocation.prepare,
    actions: actionRegistry,
    actCore: actCore,
  );
  /// Reads the chat prompt's start into the model's cache while Ask is shown (chat/prompt_read_ahead.dart). It reads what the chat
  /// would send, never loads the model, and sits out a hot device by the same heat signal as the index work.
  late final PromptReadAhead promptReadAhead = PromptReadAhead(
    engine: LocalReadAhead(app.session, extras: () => app.activeSettings.requestExtras, busy: () => chat.busy),
    request: (cancelled) => chat.warmRequest(isCancelled: cancelled),
    isHot: () async {
      await indexThrottle.read();
      return indexThrottle.hot;
    },
    waitForFix: chatLocation.waitForFix,
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
    mediaDir: () async => Directory('${await appSupportPath()}/notebook'),
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
      notebook: notebooks, places: notebookPlaces, layout: layout, placesDeps: placeNotebookDeps, userLayers: userLayers, connections: connections, pin: kAppLockEnabled ? appPin : null,
      shareAvailable: () => sharing.enabled, icons: MapIconSetup.of(maps));
  // Obsidian, Logseq and notebook sync: the folders the notebooks are kept in step with.
  late final NotebookConnections connections = NotebookConnections(
    notebook: notebooks,
    dir: () async => Directory('${await appSupportPath()}/notebook-sync'),
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
  /// Where the place map opens with no position: the Maps tab's last camera, else the middle of the saved places, else a downloaded region's centre.
  Future<({double lat, double lon, double zoom})?> _placeMapFallback() async {
    final last = maps.savedCamera;
    if (last != null && last.zoom >= 6) return placeFallbackCamera(last: last);
    return placeFallbackCamera(places: await notebookPlaces.saved(), regions: [for (final a in maps.engine.allAreas) a.bounds]);
  }

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
    map: (context, pin, onPick, look) => PlaceMap(maps: maps, themeId: app.theme, pin: pin, onPick: onPick, look: look, fallback: _placeMapFallback),
    pickerMap: (context, target, onMoving, onCentre, onTap) => PlaceMap(maps: maps, themeId: app.theme, pin: target, onPick: onTap, onMoving: onMoving, onCentre: onCentre, showPin: false, fallback: _placeMapFallback),
    directions: (p, name) {
      // A route being followed is not replaced from a place's screen: it says to finish or end the route first.
      if (nav.guiding) return false;
      nav.openDirections(MapPlace(id: 'place:${p.lat},${p.lon}', type: 'place', name: name, kind: '', address: p.label ?? '', lat: p.lat, lon: p.lon, matched: '', formats: const {}));
      nav.requestMap();
      return true;
    },
  );
  // The map's search, routes and turn-by-turn guidance: on the core when it has them, on recorded answers for screenshots
  // (--dart-define=CACHE_NAV_DEMO=<folder>), never both.
  late final NavState nav = NavState(
    backend: const String.fromEnvironment('CACHE_NAV_DEMO').isNotEmpty
        ? DemoMapBackend(Directory(const String.fromEnvironment('CACHE_NAV_DEMO')))
        : CoreMapBackend(() => sources.core!, embedder: searchModel.embedder.call, isAvailable: () => sources.coreReady && sources.openedExtra.containsKey('routing')),
    location: location,
    speaker: CarAwareSpeaker(FlutterTtsSpeaker(), car: () => _car),
    positionSource: carDrive,
    simulatedDrive: () => carDrive.simulating,
    fmt: Fmt(unitsForLocale(WidgetsBinding.instance.platformDispatcher.locale)),
    onFollow: (m) => maps.setFollow(m),
  );
  // Guidance's position: the phone's GPS, or the car's test drive along the route (Android Auto's onAutoDriveEnabled).
  // The elevation of the route shown: one for the phone's Maps screen and the car's climb card.
  late final RouteElevation routeElevation = RouteElevation(start: tileServerElevationJobs(maps.engine));
  late final CarDriveSource carDrive = CarDriveSource(GeolocatorNavSource(), route: () => nav.route);
  // Android Auto's car screen (lib/car): it shows and drives the guidance above; there is no second guidance.
  CarBridge? _car;
  // The screen stays on while guiding (it dimmed on the dashboard even with the phone set to stay on while charging).
  late final GuidanceWakeLock _guidanceAwake = GuidanceWakeLock(nav);
  CacheThemeId _applied = CacheThemeId.dark;

  /// The search core has finished starting (opened or failed); with [AppState.started] it ends the launch screen.
  bool _coreDone = false;

  final IgnoreRoutePushes _noRoutePushes = IgnoreRoutePushes();

  @override
  void initState() {
    super.initState();
    // Before the app's own navigator starts listening: a page address from the platform is never pushed as a route.
    WidgetsBinding.instance.addObserver(_noRoutePushes);
    ModelDownloads.shared = modelDownloads;
    // A download is named as its row in Models names it (the recommended list's name, once the list is read), not only while
    // Models is open: Settings says "Downloading Gemma 4 E2B", not the file name. Without the list, the file name without .gguf.
    modelDownloads.nameOf = (f) {
      if (modelDownloads.isSearchModel(f)) return 'Search model';
      for (final r in RecommendedModels.shared.models) {
        if (r.file == f.fileName) return r.name;
      }
      return f.fileName.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');
    };
    // A model the recommended list names loads with the settings the list gives it (none today: the usual ones).
    app.settingsFor = (e) {
      for (final r in RecommendedModels.shared.models) {
        if (r.file == e.fileName && r.size == e.size) return r.settings;
      }
      return null;
    };
    // The meaning search of the map uses the search model to embed the query; so do the library search and the assistant.
    SearchModel.shared = searchModel;
    sources.embedding = searchModel;
    // In a browser the search model is the server's: ask whether it is there (meaning search follows the answer).
    if (plat.isWeb) unawaited(searchModel.refreshServer());
    // Making a ZIM's PDFs searchable on this device.
    pdfIndexShared = pdfIndex;
    _guidanceAwake;
    app.addListener(_onApp);
    // Back on the screen: a weather update that is due runs now (iOS runs background tasks only when it chooses).
    _lifecycle = AppLifecycleListener(
      onResume: () {
        device?.onFocus();
        unawaited(weather.updateIfDue(kBackgroundEvery));
        _foregroundUpdates.front();
        if (!plat.isWeb) unawaited(connections.syncAll());
        if (!plat.isWeb) unawaited(_backToFront());
      },
      // The search model is let go when Cache goes to the back. Coming back to the front does not load it: opening Ask or a
      // search box does (SearchModel.aboutToSearch).
      onStateChange: (state) {
        searchModel.onLifecycle(state);
        // The chat model is let go after a grace period in the back with no answer being written; back in front cancels it.
        switch (state) {
          case AppLifecycleState.hidden:
          case AppLifecycleState.paused:
            promptReadAhead.toBackground();
            _modelRelease.toBackground();
          case AppLifecycleState.resumed:
            _modelRelease.toFront();
          case AppLifecycleState.inactive:
          case AppLifecycleState.detached:
            break;
        }
      },
      // Automatic index work runs only while the app is open (the server builds the indexes for a browser).
      onHide: () {
        _foregroundUpdates.back();
        if (!plat.isWeb) indexing.setOpen(false);
        if (!plat.isWeb) _toBack();
      },
      // On the screen again (a desktop window shown without being clicked into does not "resume").
      onShow: () => _foregroundUpdates.front(),
    );
    if (!plat.isWeb) indexing.setOpen(true);
    indexThrottleShared = indexThrottle;
    askFocusShared = askFocus;
    // The workers that hold off while Ask answers (named in the log). Indexing follows the throttle (chat.busy, _onChatForIndexing).
    for (final name in ['Indexing', 'Notebook sync', 'Settings sync', 'Downloads', 'Region downloads']) {
      askFocus.register(name);
    }
    indexSchedulerShared = indexing;
    // A PDF step may take longer in proportion as the throttle slows the work.
    pdfStepScale = () {
      final d = indexThrottle.duty;
      return d.paused || d.share <= 0 ? 1 : 1 / d.share.clamp(0.05, 1.0);
    };
    // Several libraries of one name (the Project Gutenberg ZIMs): the queue tells them apart by the catalogue's summary.
    indexItemDetail = (key) {
      final z = sources.zimById(key.substring(key.indexOf('/') + 1));
      if (z == null) return null;
      final summary = sources.originOf(z)?.summary ?? '';
      return summary.isNotEmpty ? summary : z.fileName.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');
    };
    coreIndexShared = coreIndexCalls;
    // The model generating an answer pauses background index work; the speed setting applies at once.
    chat.addListener(_onChatForIndexing);
    app.addListener(_onChatForIndexing);
    settings.addListener(_onSettingsForIndexing);
    // iOS says when the thermal state changes: read it at once.
    kBatteryChannel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await indexThrottle.read(fresh: true);
      return null;
    });
    // Android says memory is short: the model (the most memory by far) is let go while no answer is being written, and loads
    // again when Ask opens. Holding it is how Cache came to be the app Android killed.
    // The search model is let go at the same levels (and on an iOS memory warning); the next search loads it again.
    listenMemoryTrim((level, reading) {
      // Android 14 and later no longer send levels 10 to 19; older Androids do, and the chat model goes at once.
      // Going to the back (UI_HIDDEN and beyond) starts the grace period of the release below.
      if (trimMeansBackground(level)) _modelRelease.toBackground();
      if (releaseModelOn(level, reading)) searchModel.onTrim(level);
      if (!releaseChatModelNowOn(level)) return;
      if (chat.busy || app.active == null) return;
      logInfo('Model let go (Android trim level $level, ${reading ?? 'memory unknown'}); ${memoryNow()}');
      unawaited(app.release().then((_) => logInfo('Model let go; ${memoryNow()}')));
    }, onWarning: searchModel.onMemoryWarning);
    if (kAppLockEnabled) appPin.init();
    applySystemUi(_applied);
    sources.whenCoreReady().then((_) {
      if (mounted) setState(() => _coreDone = true);
    });
    // Bookshelves writes where a person places a book in this device's own library log.
    if (!plat.isWeb) libraryDeviceIdShared = () => libraryDeviceId(sharing: sharing);
    _appRead = app.init();
    final settingsRead = settings.init();
    settingsRead.then((_) => webSearch.init());
    // The weather part starts once the settings are read and the core is open; then background updates are kept in step with what is
    // switched on, and the place the background runs use is kept up to date.
    // path_provider has no browser side: there the folders stay unknown (null), which the code below already treats as "not here".
    final Future<void> supportRead = plat.isWeb ? Future.value() : appSupportPath().then((p) => _supportPath = p);
    if (!plat.isWeb) appTempPath().then((p) => _tempPath = p).catchError((_) => '');
    if (!plat.isWeb) {
      addPdfShared = addPdf;
      watchFoldersShared = watchFolders;
      // the lock with the background runs: the app is open; a background run adding PDFs is stopped, and what it changed is
      // read again. Then the watched folders are checked, once the libraries can be read (a first PDF may make My books).
      unawaited(supportRead.then((_) async {
        final s = _supportPath;
        if (s == null) return;
        final l = _bgLock = BackgroundLock(Directory(backgroundDir(s)));
        _bgSeen = l.generation;
        _bgAppOpen();
        final ran = l.runs(kAddPdfWork);
        await l.takeOver(kAddPdfWork);
        if (ran) {
          await addPdf.reload();
          await watchFolders.reload();
        }
        watchFolders.addListener(_onWatchFolders);
        await watchFolders.load();
        _onWatchFolders();
        await _writeBackgroundContext();
      }).then((_) => sources.whenCoreReady()).then((_) => watchFolders.checkAll()).catchError((Object e) {
        logError('Watch a folder: the check at start', error: e);
      }));
      // the startup self-check of Add PDF's engines, logged at Standard once Cache has settled
      unawaited(supportRead.then((_) => addPdf.load()).then((_) => Future<void>.delayed(const Duration(seconds: 20))).then((_) async {
        final s = _supportPath;
        if (s == null || !mounted) {
          logInfo('Add PDF self-check: skipped (${s == null ? 'no support folder' : 'the app closed'})');
          return;
        }
        logDetail('Add PDF self-check: reading the engines');
        await addPdfSelfCheck(addPdf.calls, await _addPdfEngines(), memo: File('$s/ingest/probe.json'));
      }).catchError((Object e) {
        logError('Add PDF self-check', error: e);
      }));
    }
    // Weather starts from what it keeps on the phone (the sources that are on, the last data shown, the saved places) as soon as
    // the settings are read, so Home's card and the Weather screen show it before the core is open; the steps that need the core
    // wait for it inside start.
    final weatherStart = settingsRead.then((_) => supportRead).then((_) => weather.start());
    // (its error, if any, is met where it is awaited below)
    unawaited(weatherStart.then((_) {}, onError: (Object _) {}));
    // Once the core is open: at the first start, or after Try again in Ask started it again.
    settingsRead.then((_) => supportRead).then((_) => sources.whenCoreOpen()).then((core) async {
      // In a browser a part that cannot start (it needs a phone feature) is logged and the rest still starts; on a phone nothing changes.
      await _soft('web search', webSearch.apply);
      await _soft('alert notifier', LocalAlertNotifier.instance.init);
      await _soft('weather', () async {
        await weatherStart;
        weather.addListener(_onWeather);
        _onWeather();
        unawaited(weather.updateIfDue(kBackgroundEvery));
        // Left open in front, the app updates by itself from here on (not on Android, whose scheduled job does).
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive) _foregroundUpdates.front();
      });
      await _soft('actions', appActions.publishAll);
      // Notebooks are published after the app's own actions, so they are listed last.
      await _soft('notebooks', () async {
        await notebooks.start();
        notebookActions.start();
      });
      unawaited(userLayers.reload());
      // Settings between linked devices, once every setting it watches has been read.
      if (!plat.isWeb) {
        await _soft('settings sync', () async {
          await Future.wait([_appRead, _layoutRead, _mapsRead]);
          await settingsSync.start();
        });
      }
      // Connected folders follow each saved change; notebook sync also looks for what linked devices sent every 2 minutes.
      final before = notebooks.onChanged;
      notebooks.onChanged = () {
        before?.call();
        if (!plat.isWeb) connections.changed();
      };
      notebooks.privateSharing = connections;
      // Connected folders and device sharing are the phone's own (they need its folders), so a browser starts neither.
      if (!plat.isWeb) {
        unawaited(connections.syncAll());
        _shareSync = Timer.periodic(const Duration(minutes: 2), (_) {
          if (sharing.running && sharing.shareOf('notebooks') != null) unawaited(connections.syncAll());
        });
      }
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
    // What a device-to-device sync brings into the Library's folders shows in the Library list at once.
    sharing.onShareChanged = (ids) {
      if (ids.contains('library') || ids.contains('libraries')) unawaited(libraries.rescan());
      // A snapshot that came by sync is attached when the core is given its sources again.
      if (ids.contains(kIndexesShareId)) {
        unawaited(sources.refresh());
        unawaited(indexing.kick());
      }
      // A linked device's settings changes arrived: applied at once.
      if (ids.contains(kSettingsShareId) && settingsSync.started) unawaited(settingsSync.pull());
    };
    sources.addListener(_syncIndexesOnly);
    // Sources came or went (a ZIM downloaded, its PDFs listed): the scheduler looks for work at once.
    sources.addListener(_kickIndexing);
    // Saved videos came or went: their captions' indexes are fetched and built too.
    video.addListener(_syncIndexesOnly);
    video.addListener(_kickIndexing);
    if (!plat.isWeb) {
      // The folders shared from the start (the indexes, the settings and Bookshelves logs) are in the support folder.
      Future.wait([settingsRead, supportRead]).then((_) => sharing.init());
    }
    // Regions are the server's in a browser (its engine downloads with no tab open), so they start on both.
    settingsRead.then((_) => regions.init());
    _layoutRead = layout.init();
    sources.init();
    if (!plat.isWeb) unawaited(pdfIndex.init());
    if (device != null) unawaited(device!.start());
    libraries.init();
    browse.init();
    video.init();
    location.init();
    _mapsRead = maps.init();
    if (plat.isAndroid) {
      unawaited(readCarScreenSupport().then((v) => carScreenSupported.value = v));
      _car = CarBridge(
        nav: nav,
        maps: maps,
        drive: carDrive,
        elevation: routeElevation,
        theme: () => app.theme,
        overlay: () => carOverlaySwitches(climb: app.carClimbAhead, miniMap: app.carRouteMiniMap),
        settings: app,
        ready: () => sources.whenCoreReady(),
        // The phone map's pins (notebook places, saved places, shown repeater lists) on the car's map.
        pins: CarPins.of(notebooks: notebooks, userLayers: userLayers, maps: maps),
        // A current position for the car (no prompt: the explanation answers no, so only a permission already given is used).
        onConnected: () async {
          await location.request(explain: () async => false);
        },
      );
      // While a car screen is attached the position keeps coming, whatever the phone's screen does (location_service.dart).
      _car!.connected.addListener(_onCarScreen);
      unawaited(_car!.start());
    }
    _openHistory();
  }

  void _onCarScreen() {
    final attached = _car?.connected.value ?? false;
    location.carScreen(attached);
    if (!attached) _carLeft();
  }

  /// The car has left. When Android Auto started Cache with the phone app closed, nothing shows Cache now and nothing will say
  /// so: a start counts as in front, and only a phone screen's lifecycle ends that (before the engine was kept for the life of
  /// the process, the run simply ended here). So Cache goes to the back by itself, as it does when the phone's screen is
  /// hidden: index work stops and is handed to the background, the models are let go after their usual wait, the position
  /// stream stops and the "running" mark is taken away. Nothing is loaded or started. The phone's screen coming to the front
  /// brings it all back the usual way ([_backToFront] and the lifecycle listeners).
  void _carLeft() {
    if (!nothingShowsTheApp(inFront: _atFront, screen: WidgetsBinding.instance.lifecycleState)) return;
    logInfo('The car has left and the phone screen is not open: Cache goes to the back');
    searchModel.onLifecycle(AppLifecycleState.paused);
    promptReadAhead.toBackground();
    _modelRelease.toBackground();
    _foregroundUpdates.back();
    indexing.setOpen(false);
    _toBack();
    location.noScreen();
    markAppNotOpen();
  }

  /// Runs one start-up step. In a browser a step that fails is logged and the next one still runs; elsewhere the error goes on as before.
  Future<void> _soft(String what, Future<void> Function() step) async {
    try {
      await step();
    } catch (e, stack) {
      if (!plat.isWeb) rethrow;
      debugPrint('Start-up step "$what" skipped: $e\n$stack');
    }
  }

  Future<void> _appRead = Future.value();
  Future<void> _layoutRead = Future.value();
  Future<void> _mapsRead = Future.value();

  ConversationStore? _store;
  late final AppLifecycleListener _lifecycle;

  /// The weather update while Cache is left open in front, at the background schedule's interval: the same update a background
  /// run makes (not forced, so each source's refresh time and quota hold), where no scheduled job runs for an app in front.
  late final ForegroundUpdates _foregroundUpdates = ForegroundUpdates(
    every: kBackgroundEvery,
    on: () => weather.enabledSources.isNotEmpty,
    update: () => weather.updateNow(),
    wanted: foregroundUpdatesWanted(),
  );
  late final BackgroundModelRelease _modelRelease = BackgroundModelRelease(
    // A load in flight holds the release like an answer does: it never unloads a model the person just asked for, and when the
    // load ends with Cache still in the back, a new grace period starts.
    busy: () => chat.busy || app.loading != null,
    loaded: () => app.active != null,
    release: () => app.release().then((_) => logInfo('Model let go; ${memoryNow()}')),
    changes: Listenable.merge([chat, app]),
  );
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
      regions: watchRegionsOf(regions.local),
    );
    final key = jsonEncode(last.toJson());
    if (key == _lastPlaceSaved) return;
    _lastPlaceSaved = key;
    last.write(LastPlace.fileIn(Directory(support)));
  }

  /// The conversations live in the app's private storage.
  Future<void> _openHistory() async {
    try {
      _store = await openHistoryStore();
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
        app.active == null ? null : LocalLlamaBackend(app.session, extras: () => app.activeSettings.requestExtras),
        modelName: app.active == null ? '' : app.displayName(app.active!),
        queuePosition: app.active == null ? null : app.session.queuePosition,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_noRoutePushes);
    _lifecycle.dispose();
    _foregroundUpdates.dispose();
    _modelRelease.dispose();
    _shareSync?.cancel();
    connections.dispose();
    app.removeListener(_onApp);
    weather.removeListener(_onWeather);
    location.removeListener(_rememberPlace);
    location.removeListener(weather.positionChanged);
    nav.removeListener(_onNav);
    app.session.dispose();
    browse.dispose();
    _car?.connected.removeListener(_onCarScreen);
    _car?.dispose();
    _guidanceAwake.dispose();
    nav.dispose();
    sources.removeListener(_syncIndexesOnly);
    sources.removeListener(_kickIndexing);
    video.removeListener(_syncIndexesOnly);
    video.removeListener(_kickIndexing);
    chat.removeListener(_onChatForIndexing);
    app.removeListener(_onChatForIndexing);
    settings.removeListener(_onSettingsForIndexing);
    indexing.dispose();
    _bgOpenTimer?.cancel();
    watchFolders.removeListener(_onWatchFolders);
    watchFolders.dispose();
    indexThrottle.dispose();
    if (identical(askFocusShared, askFocus)) askFocusShared = null;
    askFocus.dispose();
    pdfIndex.dispose();
    searchModel.dispose();
    libraries.dispose();
    device?.dispose();
    sources.dispose();
    video.dispose();
    // Settings sync listens to the states below: it lets go of them first.
    settingsSync.dispose();
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

  /// A phone screen has come to the front for the first time: the first one of this run, or a new one after Android closed the
  /// last (on Android the app outlives its screen: platform/phone_screen.dart). What the start did for the screen it expected
  /// is done for this one.
  void _onPhoneScreen() {
    // The system bars are the screen's own (MainActivity): a new screen has not been told how to show them.
    applySystemUi(_applied);
    // The chat model a start by the car left out loads now, as it would have at a start with the phone's screen.
    unawaited(app.phoneScreenAppeared());
  }

  @override
  Widget build(BuildContext context) {
    // Only Android keeps the app running past its screen (the engine is kept for the life of the process).
    if (!plat.isAndroid) return _interface(context);
    // Each phone screen gets the interface built from the start; the state above stays (platform/phone_screen.dart).
    return PhoneScreenScope(
      onScreen: _onPhoneScreen,
      placeholder: ColoredBox(color: cacheTokens[_applied]!.background),
      builder: _interface,
    );
  }

  Widget _interface(BuildContext context) {
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
            // Any touch, scroll or wheel: the person is using Cache, background index work slows down meanwhile.
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => indexThrottle.noteActivity(),
              onPointerMove: (_) => indexThrottle.noteActivity(),
              onPointerSignal: (_) => indexThrottle.noteActivity(),
              // While the log keeps everything, a line at the top says so on every screen.
              child: ListenableBuilder(
                listenable: appLog,
                // one shape whether the banner shows or not, so the app below keeps its state when it comes and goes
                builder: (context, _) => Column(
                  children: [
                    const LogEverythingBanner(),
                    // the banner holds the status bar's room while it shows
                    Expanded(child: MediaQuery.removePadding(context: context, removeTop: appLog.everythingUntil != null, child: DesktopThemeScope(child: child!))),
                  ],
                ),
              ),
            ),
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
        home: appLockAsked(appPin) ? PinLockScreen(pin: appPin) : Shell(
          app: app,
          chat: chat,
          sources: sources,
          location: location,
          chatLocation: chatLocation,
          readAhead: promptReadAhead,
          maps: maps,
          video: video,
          browse: browse,
          nav: nav,
          elevation: routeElevation,
          layout: layout,
          hub: hub,
          notebooks: notebookDeps,
          firstRunWizard: true,
          discoverFetch: () => fetchText(Uri.parse(kDiscoverUrl)),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../browse/browse_screen.dart';
import '../browse/browse_state.dart';
import '../browse/catalogue_screen.dart' show AddToLibraryScreen;
import '../browse/place_about.dart';
import '../browse/reader_screen.dart';
import '../browse/zim_urls.dart';
import '../chat/ask_about.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_location.dart';
import '../chat/prompt_read_ahead.dart';
import '../chat/navigation_action.dart';
import '../discover/discover_device.dart';
import '../discover/discover_state.dart';
import '../discover/ui/discover_screen.dart';
import '../discover/ui/place_page.dart';
import '../guide/app_links.dart';
import '../guide/guide_book.dart';
import '../actions/setup_status.dart' show setupGuideTitle;
import '../guide/guide_reader.dart';
import '../regions/ui/region_actions.dart';
import '../pdf/index/pdf_index_app.dart';
import '../pdf/index/pdf_index_ui.dart' show PdfSearchNote, showPdfPartSheet;
import '../pdf/pdf_settings.dart' show PdfReaderLinks;
import '../desktop/desktop.dart';
import '../desktop/desktop_shell.dart';
import '../desktop/linux_updates.dart';
import '../linux_ui.dart';
import '../layout/adaptive.dart';
import '../layout/layout_state.dart';
import '../layout/modules.dart';
import '../layout/modules_screen.dart';
import '../location/location_service.dart';
import '../maps/maps_state.dart';
import '../maps/user_layers.dart' show Repeater;
import '../models/search_model.dart' show SearchModel;
import '../nav/nav_state.dart';
import '../regions/regions_state.dart';
import '../regions/ui/regions_list_sheet.dart';
import '../search/app_search.dart';
import '../search/app_search_providers.dart';
import '../search/notebook_search_providers.dart';
import '../regions/ui/regions_screen.dart';
import '../settings/hub.dart';
import '../sources/sources_state.dart';
import '../update/app_update.dart' show ReleaseFileSource;
import '../update/update_ui.dart';
import '../video/video_state.dart';
import '../video/zim_video.dart' show openZimMediaInPlayer;
import '../weather/alert_notifier.dart';
import '../weather/alert_watch.dart';
import 'ask_off.dart';
import 'ask_screen.dart';
import 'home_screen.dart';
import 'maps_screen.dart';
import 'models_screen.dart';
import 'download_confirm.dart' show openStorageForSpace;
import '../notebook/notebook_model.dart';
import 'notebooks/notebook_screen.dart';
import 'notebooks/notebooks_screen.dart';
import 'notebooks/quick_add_sheet.dart';
import 'notebooks/repeater_list_screen.dart';
import 'settings/about_pages.dart' show AboutPage;
import 'settings/appearance_page.dart';
import 'settings/assistant_page.dart';
import 'settings/maps_page.dart';
import 'settings/notifications_page.dart';
import 'settings/own_source_pages.dart' show OwnSourceFormPage;
import 'settings/sharing_page.dart';
import 'settings/deps.dart';
import 'settings/storage_page.dart';
import 'settings/weather_page.dart';
import 'settings_screen.dart';
import 'setup_card.dart';
import 'videos/video_nav.dart';
import 'videos/videos_screen.dart';
import 'weather_screen.dart';
import 'weather_turn_on.dart';
import '../platform.dart' as plat;

/// The app's frame: Home first, up to three pinned modules, Modules last. The screens are built the first time they are
/// shown and then kept alive.
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.app,
    required this.chat,
    required this.sources,
    required this.location,
    this.chatLocation,
    this.readAhead,
    required this.maps,
    required this.video,
    required this.browse,
    required this.nav,
    required this.layout,
    required this.hub,
    this.notebooks,
    this.railPrefs,
    this.firstRunWizard = false,
    this.discoverFetch,
  });

  /// On a device set up for the first time, Discover's wizard opens by itself once (the app sets it; tests leave it off).
  final bool firstRunWizard;

  /// Reads the published Discover file (the app's fetch of kDiscoverUrl); null: only the copy in the app.
  final Future<String> Function()? discoverFetch;

  /// Where the rail's hidden-in-portrait choice is kept (the app's support folder when null).
  final RailPrefs? railPrefs;

  final AppState app;
  final ChatController chat;
  final SourcesState sources;
  final LocationService location;
  final ChatLocation? chatLocation;

  /// Reads the chat prompt's start ahead once Ask is shown with the model loaded; null in tests that do not need it.
  final PromptReadAhead? readAhead;
  final MapsState maps;
  final VideoState video;
  final BrowseState browse;
  final NavState nav;
  final LayoutState layout;
  final SettingsHub hub;

  /// Notebooks (null: the module shows that it is not available).
  final NotebookDeps? notebooks;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// The module on screen; null with [_onModules] false is Home.
  ModuleId? _module;
  bool _onModules = false;
  final Set<ModuleId> _built = {};
  StreamSubscription<NavEvent>? _navEvents;
  StreamSubscription<AlertFocus>? _alertTaps;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _onResume);

  /// Back in front with Ask shown: the chosen model, let go while Cache was in the back, loads again, under the same memory gate
  /// as opening Ask (not forced). Nothing else loads on resume.
  void _onResume() {
    if (_module == ModuleId.ask) unawaited(_wakeAsk());
  }

  /// Ask is shown: the chosen model loads if it was let go ([AppState.wake], under the memory gate), and with the model loaded
  /// the chat prompt's start is read ahead. The read never loads the model: after a wake that did not load it (no room) there is
  /// none. Not when Ask was left while the model loaded; leaving Ask later, with Cache in front, does not stop a read.
  Future<void> _wakeAsk() async {
    _openingRead = false; // a new opening of Ask: it may have its read ahead
    _endReadWait(); // an earlier opening's wait is over
    _readEnded = Completer<void>();
    await widget.app.wake();
    _readAhead();
    // No read is coming (the model did not load, there is no read ahead): nothing to wait for.
    if (!_openingRead && widget.app.loading == null) _endReadWait();
  }

  /// This opening of Ask has had its read ahead (or has none to have).
  bool _openingRead = false;
  int _seenGeneration = 0;

  /// Completes when this opening's read ahead has finished, been skipped or stopped, or none is coming (the test APK's switch that
  /// defers the search model's load until then reads it).
  Completer<void> _readEnded = Completer<void>()..complete();

  void _endReadWait() {
    if (!_readEnded.isCompleted) _readEnded.complete();
  }

  /// Reads the prompt start ahead, once per opening of Ask, when Ask is shown and the model is loaded. When the model is still loading
  /// as Ask opens (the app start's load, which [AppState.wake] does not wait for) nothing is read yet, and [_onApp] asks again when
  /// the load completes, so a cold start with Ask open still gets its read.
  void _readAhead() {
    if (!mounted || _module != ModuleId.ask) {
      _endReadWait(); // Ask was left: no read to wait for
      return;
    }
    if (_openingRead) return;
    final app = widget.app;
    if (app.active == null || app.loading != null) return;
    _openingRead = true;
    final ahead = widget.readAhead;
    if (ahead == null) {
      _endReadWait();
    } else {
      unawaited(ahead.start().whenComplete(_endReadWait));
    }
  }

  /// Ask is available: a chat model is on this device (AppState.askAvailable). Without one Cache is search only: Ask leaves the bar
  /// and the rail (its pin is kept and it takes its old place when a model comes), and every way into Ask is closed or explained.
  late bool _askOn = widget.app.askAvailable;

  /// The models folder has been read and held no chat model: the next one to arrive turns Ask on, and says so.
  /// Set in initState (a lazy initializer would first run after the model had already arrived).
  bool _noModelSeen = false;

  void _onApp() {
    final app = widget.app;
    if (app.modelGeneration != _seenGeneration) {
      _seenGeneration = app.modelGeneration;
      _openingRead = false; // another model is loaded while Ask stays open: it gets its read ahead
    }
    _readAhead(); // Ask was opened while the model loaded: its read starts when the load is done
    final arrived = _noModelSeen && app.started && app.models.isNotEmpty;
    if (app.started) _noModelSeen = app.models.isEmpty;
    final on = app.askAvailable;
    if (on != _askOn && mounted) {
      setState(() => _askOn = on);
      askCacheInstead = on ? _askFromGuide : null;
    }
    if (arrived && mounted) _askIsOn();
  }

  /// The first model has arrived: "Ask is on." with Open. Nothing moves by itself.
  void _askIsOn() {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      key: const ValueKey('ask-is-on'),
      persist: false,
      content: const Text('Ask is on.'),
      action: SnackBarAction(label: 'Open', onPressed: _openAskNow),
    ));
  }

  /// "Open" on "Ask is on.": Ask, with the new model loading (nothing else is loaded).
  void _openAskNow() {
    final app = widget.app;
    if (app.active == null && app.loading == null) {
      final usable = [for (final e in app.models) if (!app.isUnsupported(e)) e];
      if (usable.isNotEmpty) unawaited(app.activate(usable.first));
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    _goModule(ModuleId.ask);
  }

  @override
  void initState() {
    super.initState();
    // PDF indexing's messages ("Another device finished this. Using its index.").
    pdfIndexShared?.say = _sayIfMounted;
    _noModelSeen = widget.app.started && widget.app.models.isEmpty;
    _seenGeneration = widget.app.modelGeneration;
    widget.app.addListener(_onApp);
    _lifecycle;
    _navEvents = widget.nav.events.listen((e) {
      if (e is AddToHomeRequested && mounted) addToHome(context, widget.layout, Shortcut.place(e.place));
      if (e is MapRequested && mounted) _goModule(ModuleId.maps);
    });
    // An alert pop-up tapped while the app runs, or the one that started it: open the Weather screen on that alert.
    _alertTaps = LocalAlertNotifier.instance.taps.listen(_openAlert);
    LocalAlertNotifier.instance.launchFocus().then((f) {
      if (f != null && mounted) _openAlert(f);
    }).catchError((_) {});
    widget.maps.addListener(_onMaps);
    openAppPlace = _goToPlace;
    appPlaceScreen = _placeScreen;
    askCacheInstead = _askOn ? _askFromGuide : null;
    // The PDF reader's "Open Library" (its file is gone from a library): the Library, over everything.
    PdfReaderLinks.openLibrary = (context) {
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      _goModule(ModuleId.library);
    };
    // A link to a ZIM's video entry in the reader plays in the app's player.
    openZimMediaInPlayer = (address) {
      if (!mounted) return;
      unawaited(playZimVideo(context, widget.video, _zimVideos, address: address).catchError((Object _) => _say("This video can't be played.")));
    };
    // "Free up space" in any download pop-up opens Settings > Storage.
    openStorageForSpace = (context) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoragePage(deps: _settingsDeps)));
    // Is a newer build out for this phone (cached.info's release file)? iPhone: TestFlight; Android: the Play Store app.
    currentAppUpdates = _updates;
    unawaited(_updates?.check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _whatsNew());
    _railPrefs.hidden().then((h) {
      if (mounted && h != _railHidden) setState(() => _railHidden = h);
    });
    DiscoverState.shared = _discover;
    discoverLinks = _discoverLinks;
    unawaited(_startDiscover());
  }

  /// Discover: what activities added, and whether first run is done. A device with a model, a library or a region on it already
  /// was set up before Discover came: its first run counts as done (no wizard).
  late final DiscoverState _discover = DiscoverState(
    device: AppDiscoverDevice(
      browse: widget.browse,
      settings: widget.hub.settings,
      weather: widget.hub.weather,
      layout: widget.layout,
      regions: widget.hub.regions,
      notebooks: widget.notebooks?.notebook,
      location: widget.location,
      indexing: widget.hub.indexing,
    ),
    fetch: widget.discoverFetch,
  );

  Future<void> _startDiscover() async {
    final app = widget.app;
    if (!app.started) {
      final started = Completer<void>();
      void on() {
        if (app.started && !started.isCompleted) started.complete();
      }

      app.addListener(on);
      await started.future;
      app.removeListener(on);
    }
    final libs = widget.browse.libraries;
    final setUpBefore = app.models.isNotEmpty ||
        widget.sources.zims.isNotEmpty ||
        (widget.hub.regions?.local.isNotEmpty ?? false) ||
        (libs != null && libs.libraries.any((l) => !libs.isGuide(l)));
    await _discover.init(setUpBefore: setUpBefore);
    if (widget.firstRunWizard && !_discover.firstRunDone && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(openDiscover(context, _discover));
      });
    }
  }

  /// Where Discover's links go.
  DiscoverLinks get _discoverLinks => DiscoverLinks(
    allLibraries: (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => AddToLibraryScreen(browse: widget.browse))),
    allMaps: widget.hub.regions == null ? null : (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => RegionsScreen(regions: widget.hub.regions!))),
    ownSource: (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => OwnSourceFormPage(deps: _settingsDeps))),
    linkDevice: widget.hub.sharing == null
        ? null
        : (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => SharingPage(sharing: widget.hub.sharing!, settingsSync: widget.hub.settingsSync))),
    searchLibraries: (c, q) {
      unawaited(widget.browse.setFilter(query: q));
      Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => AddToLibraryScreen(browse: widget.browse)));
    },
    askLocation: (c) async {
      await widget.location.request(explain: () async => true);
    },
    choosePlace: widget.hub.regions == null
        ? null
        : (c) => Navigator.of(c).push<DiscoverPlace>(MaterialPageRoute<DiscoverPlace>(builder: (_) => PlacePage(catalogue: widget.hub.regions!.catalogue))),
  );

  late final AppUpdates? _updates = plat.isIOS || plat.isAndroid
      ? AppUpdates(source: ReleaseFileSource(installedBuild: installedBuild), openUrl: widget.hub.openUrl, android: plat.isAndroid, dismissed: DismissedUpdate())
      // Cache on Linux: a newer release is a new tarball for the server, which the banner on Home explains.
      : linuxUi
      ? linuxAppUpdates(openUrl: widget.hub.openUrl)
      : null;

  bool _whatsNewAsked = false;

  /// The rail (a tablet held sideways) is hidden: the person's choice on this device.
  bool _railHidden = false;
  late final RailPrefs _railPrefs = widget.railPrefs ?? RailPrefs();

  void _setRailHidden(bool hidden) {
    setState(() => _railHidden = hidden);
    _railPrefs.setHidden(hidden);
  }

  /// "What's new" once after an update, on Home only, never over another screen or pop-up (it waits until Home is back).
  Future<void> _whatsNew() async {
    if (_whatsNewAsked || !mounted || _module != null || _onModules || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _whatsNewAsked = true;
    await maybeShowWhatsNew(context, seen: WhatsNewSeen(), firstInstall: widget.app.models.isEmpty);
  }

  void _openAlert(AlertFocus f) {
    widget.hub.weather.focus.value = f;
    _goModule(ModuleId.weather);
  }

  /// "Draw your own area instead" in the Regions sheet asks the map for a drawn area; from Home (Set up Cache's "Get your area")
  /// the map is not on screen, so the request went nowhere: the Maps tab is opened for it.
  void _onMaps() {
    if (widget.maps.drawRequest && _module != ModuleId.maps && mounted) _goModule(ModuleId.maps);
  }

  @override
  void dispose() {
    if (pdfIndexShared?.say == _sayIfMounted) pdfIndexShared?.say = null;
    widget.maps.removeListener(_onMaps);
    widget.app.removeListener(_onApp);
    if (openAppPlace == _goToPlace) openAppPlace = null;
    if (appPlaceScreen == _placeScreen) appPlaceScreen = null;
    if (askCacheInstead == _askFromGuide) askCacheInstead = null;
    if (DiscoverState.shared == _discover) DiscoverState.shared = null;
    _navEvents?.cancel();
    _alertTaps?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _goHome() {
    setState(() {
      _module = null;
      _onModules = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _whatsNew());
  }

  void _goModules() => setState(() {
        _module = null;
        _onModules = true;
      });

  void _goModule(ModuleId m) {
    // Ask opens: the chosen model, let go to leave memory free, loads again.
    if (m == ModuleId.ask) unawaited(_wakeAsk());
    // Ask is shown (with a chat model to ask): its search tool will want the search model, which loads now, not at app start.
    if (m == ModuleId.ask && _askOn) SearchModel.aboutToSearch(after: _readEnded.future);
    setState(() {
      _module = m;
      _onModules = false;
      _built.add(m);
    });
  }

  void _openNavigation(NavigationAction action) {
    final route = action.route;
    if (route == null) {
      _say('Navigation unavailable: this route snapshot is no longer available.');
      return;
    }
    if (widget.nav.guiding) {
      _say('Finish or end the route first');
      return;
    }
    if (widget.nav.previewSnapshot(route)) _goModule(ModuleId.maps);
  }

  void _openSource(String address, [String? quote]) {
    // A citation of the guide opens the guide's reader at that section.
    if (address.startsWith('lib:$kGuideLibrary/')) {
      unawaited(_openGuideAt(address));
      return;
    }
    // A citation of the phone's setup (app.setup_status) opens the guide section that part of the setup names. It went to the
    // Library before, which has no such address, so the chip did nothing.
    final setupGuide = setupGuideTitle(address);
    if (setupGuide != null) {
      unawaited(openGuide(context, title: setupGuide));
      return;
    }
    _goModule(ModuleId.library);
    widget.browse.openAddress(address, quote: quote);
  }

  Future<void> _openGuideAt(String address) async {
    final book = await GuideBook.load();
    if (!mounted) return;
    await openGuide(context, title: book.byAddress(address)?.title, book: book);
  }

  /// The screen a guide link (cache://) opens over the reader; null for a place this phone does not have.
  Widget? _placeScreen(AppPlace p) {
    final regions = widget.hub.regions;
    final nb = widget.notebooks;
    final d = _settingsDeps;
    return switch (p) {
      AppPlace.home => _home(),
      // With no model, a link to Ask opens the note Modules shows (Choose a model / Close): a tapped link is never silent.
      AppPlace.ask => _askOn
          ? _moduleScreen(ModuleId.ask)
          : Builder(
              builder: (c) => AskOffPage(
                app: widget.app,
                chat: widget.chat,
                onChooseModel: () => openModels(c, widget.app),
                onClose: () => Navigator.of(c).pop(),
              ),
            ),
      AppPlace.maps => _moduleScreen(ModuleId.maps),
      AppPlace.regions => regions == null ? null : RegionsScreen(regions: regions),
      AppPlace.library => _moduleScreen(ModuleId.library),
      AppPlace.addToLibrary => AddToLibraryScreen(browse: widget.browse),
      AppPlace.notebooks => nb == null ? null : NotebooksScreen(deps: nb),
      AppPlace.placesNotebook => switch ((nb, nb?.notebook.notebooks.where((n) => n.isPlaces).firstOrNull)) {
          (final deps?, final n?) => NotebookScreen(deps: deps, notebookId: n.id),
          _ => null,
        },
      AppPlace.settings => SettingsScreen(deps: d),
      AppPlace.assistantSettings => AssistantPage(deps: d),
      AppPlace.mapsSettings => MapsPage(deps: d),
      AppPlace.weatherSettings => WeatherPage(deps: d),
      AppPlace.notifications => NotificationsPage(deps: d),
      AppPlace.storage => StoragePage(deps: d),
      AppPlace.sharing => widget.hub.sharing == null ? null : SharingPage(sharing: widget.hub.sharing!, settingsSync: widget.hub.settingsSync),
      AppPlace.appearance => AppearancePage(app: widget.app),
      AppPlace.credits => const AboutPage(),
      AppPlace.models => ModelsScreen(app: widget.app),
      AppPlace.drawArea => null,
    };
  }

  /// A guide link that does not open over the reader: drawing an area happens on the map.
  void _goToPlace(AppPlace p) {
    if (p != AppPlace.drawArea) return;
    _goModule(ModuleId.maps);
    widget.maps.requestDraw();
  }

  /// A video citation: the player at the cited moment (the saved copy when there is one).
  void _openVideo(String link, double time, String? lang) =>
      openVideoCitation(context, widget.video, video: link, offsetS: time, lang: lang, zims: _zimVideos, openInReader: _openSource);

  /// A ZIM's videos for the player: read with the reader's own entry read; named by the ZIM's title.
  late final ZimVideoReader _zimVideos = ZimVideoReader(
    read: widget.sources.zimGet,
    titleOf: (id) {
      final z = widget.sources.zimById(id);
      return z == null ? 'the Library' : widget.sources.titleOf(z);
    },
  );

  SettingsDeps get _settingsDeps => SettingsDeps(
    app: widget.app,
    chat: widget.chat,
    sources: widget.sources,
    maps: widget.maps,
    video: widget.video,
    browse: widget.browse,
    location: widget.location,
    hub: widget.hub,
    onOpenAsk: _openAskFromSettings,
  );

  /// "Set up Cache" on Home: each line opens the screen the feature uses everywhere.
  late final SetupCache _setup = SetupCache(
    app: widget.app,
    weather: widget.hub.weather,
    sources: widget.sources,
    regions: widget.hub.regions,
    browse: widget.browse,
    chooseModel: (context) => openModels(context, widget.app),
    getArea: _getArea,
    turnOnWeather: (context) => turnOnWeather(context, _weatherTurnOn),
    addLibrary: (context) => showAddToLibrary(context, widget.browse),
    openGuide: (context, title) => openGuide(context, title: title),
    openWeatherSettings: (_) => _openWeatherSettings(),
  );

  /// "Get your area": the Regions sheet for where the phone is; without a position, the regions to search.
  void _getArea(BuildContext context) {
    final regions = widget.hub.regions;
    if (regions == null) {
      _say('Regions are not available on this device');
      return;
    }
    // A download that stopped (on iPhone, Cache was closed or put away while it ran) is carried on, not offered again.
    if (_setup.stoppedRegion case final stopped?) {
      unawaited(_carryOn(regions, stopped));
      return;
    }
    final here = _here;
    if (here != null) {
      showRegionsSheet(context, regions, lat: here.lat, lon: here.lon);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionsScreen(regions: regions, initialTab: 0)));
    }
  }

  Future<void> _carryOn(RegionsState regions, LocalRegion l) =>
      carryOnNow(ScaffoldMessenger.of(context), regions, l.id, name: l.name, again: l.phase == RegionPhase.failed);

  /// Home's search across Cache: one provider per module (Notebooks add theirs here).
  late final AppSearch _search = AppSearch([
    LibrarySearchProvider(
      sources: widget.sources,
      openZim: (z) async {
        final id = widget.sources.idOf(z);
        if (id != null) _openSource(await widget.sources.zimMainPage(id));
      },
      openAddress: _openSource,
      // Words said in a video and passages of EPUB books open as their citations in Ask do.
      openVideo: _openVideo,
      openPassage: _openSource,
    ),
    PlacesSearchProvider(
      backend: widget.nav.backend,
      near: () => _here,
      distance: widget.nav.fmt.distance,
      open: (p) {
        if (widget.nav.phase != NavPhase.browsing) {
          _say('Finish or end the route first');
          return;
        }
        widget.nav.select(p);
        _goModule(ModuleId.maps);
      },
    ),
    LayersSearchProvider(
      maps: widget.maps,
      open: (l) {
        widget.maps.setOn(l.id, true);
        _goModule(ModuleId.maps);
      },
    ),
    if (widget.notebooks case final nb?) ...[
      NotebooksSearchProvider(
        notebook: nb.notebook,
        openNotebook: (n) {
          _goModule(ModuleId.notebooks);
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookScreen(deps: nb, notebookId: n.id)));
        },
        openEntry: (n, e) => openNotebookEntry(context, nb, n, e),
      ),
      NotebookPlacesSearchProvider(
        notebook: nb.notebook,
        here: () => switch (widget.location.fix) {
          final f? => (lat: f.lat, lon: f.lon),
          null => null,
        },
        distance: widget.nav.fmt.distance,
        open: (n, e) => openNotebookEntry(context, nb, n, e),
      ),
    ],
  ]);

  /// "Ask Cache instead" under a guide search that found nothing: the guide closes and Ask asks what was searched for.
  void _askFromGuide(String text) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    _askFromHome(text);
  }

  /// Enter in Home's search: a new chat that asks exactly what was typed.
  void _askFromHome(String text) {
    if (!_askOn) return;
    widget.chat.newChat();
    _goModule(ModuleId.ask);
    widget.chat.send(text);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsScreen(deps: _settingsDeps)),
    );
  }

  /// A saved conversation was chosen in Settings: leave Settings and show Ask.
  void _openAskFromSettings() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    _goModule(ModuleId.ask);
  }

  /// "Ask about this" on the Weather screen: a new chat that asks the question straight away, seeded with the item's live data.
  void _askAbout(AskAbout about) {
    if (!_askOn) return;
    widget.chat.newChat();
    _goModule(ModuleId.ask);
    widget.chat.send(about.question, seed: about);
  }

  void _openWeatherSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WeatherPage(deps: _settingsDeps)));
  }

  void _sayIfMounted(String text) {
    if (mounted) _say(text);
  }

  void _say(String text) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(text)));
  }

  /// A Home shortcut was tapped: open what it points at.
  void _openShortcut(Shortcut s) {
    switch (s.kind) {
      case ShortcutKind.module:
        final m = s.module;
        if (m != null) _goModule(m);
      case ShortcutKind.place:
        final p = s.place;
        if (p == null) return;
        if (widget.nav.phase != NavPhase.browsing) {
          _say('Finish or end the route first');
          return;
        }
        widget.nav.select(p);
        _goModule(ModuleId.maps);
      case ShortcutKind.page:
        final address = s.address;
        final id = address == null ? null : zimIdOfAddress(address);
        final z = id == null ? null : widget.sources.zimById(id);
        if (address == null || z == null) {
          _say('That page is not on this device any more');
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ZimReaderScreen(sources: widget.sources, zim: z, address: address, layout: widget.layout),
          ),
        );
      case ShortcutKind.chat:
        final id = s.chatId;
        if (id == null || widget.chat.store?.get(id) == null) {
          _say('That chat is gone');
          return;
        }
        widget.chat.openConversation(id);
        _goModule(ModuleId.ask);
      case ShortcutKind.notebook:
        _openNotebook(s);
    }
  }

  /// A notebook pin's Open: the entry in its editor (a log entry in its quick add sheet).
  void _openEntry(NbEntry e) {
    final deps = widget.notebooks;
    final book = deps?.notebook.notebook(e.notebookId);
    if (deps == null || book == null) return;
    openNotebookEntry(context, deps, book, e);
  }

  /// The map's ring menu: a new entry of [book] at a held spot.
  void _newEntryAt(Notebook book, NbPlace at) {
    final deps = widget.notebooks;
    if (deps != null) newNotebookEntryAt(context, deps, book, at);
  }

  /// A notebook's Home card: a log's opens its quick add over Home (tap, Save); any other opens the notebook. A notebook that
  /// was deleted drops its card.
  Future<void> _openNotebook(Shortcut s) async {
    final deps = widget.notebooks;
    final id = s.notebookId;
    if (deps == null || id == null) return;
    await deps.notebook.start();
    final n = deps.notebook.notebook(id);
    if (!mounted) return;
    if (n == null) {
      widget.layout.removeShortcut(s);
      _say('That notebook is gone');
      return;
    }
    if (n.isLog && s.data['log'] == true) {
      showQuickAdd(context, notebook: deps.notebook, log: n, places: deps.places, now: deps.now);
      return;
    }
    _goModule(ModuleId.notebooks);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookScreen(deps: deps, notebookId: id)));
  }

  /// "Turn on weather": the location, and the map's place search and saved places for "Choose a place instead".
  WeatherTurnOn get _weatherTurnOn => WeatherTurnOn(
    weather: widget.hub.weather,
    location: widget.location,
    searchPlaces: widget.nav.backend.available ? (q) async => (await widget.nav.backend.search(q, near: _here)).results : null,
    savePlace: (p) => widget.nav.backend.savePlace(name: p.name, lat: p.lat, lon: p.lon, label: p.address.isEmpty ? null : p.address),
  );

  GeoPoint? get _here => switch (widget.location.fix) {
    final f? => GeoPoint(f.lat, f.lon),
    null => null,
  };

  /// The Notebooks' deps with the repeater lists' map actions (a row opens Maps on its repeater).
  late final NotebookDeps? _notebookDeps = widget.notebooks?.withRepeaterActions(onShow: _showRepeater, onDirections: _repeaterDirections, fmt: widget.nav.fmt);

  /// A repeater list's row: Maps, on the repeater, with its card.
  void _showRepeater(Repeater r) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    widget.notebooks?.userLayers?.showRepeater(r);
    _goModule(ModuleId.maps);
  }

  /// Directions to a repeater (its row's menu): the way there on the map, as from its card.
  void _repeaterDirections(Repeater r) {
    if (!r.located) return;
    if (widget.nav.phase != NavPhase.browsing) {
      _say('Finish or end the route first');
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    _goModule(ModuleId.maps);
    widget.nav.openDirections(MapPlace.pin(r.lat!, r.lon!, name: r.name));
  }

  /// "Open in notebook" on a repeater's card: its list notebook, at its row.
  void _openRepeaterList(Repeater r) {
    final deps = _notebookDeps;
    if (deps == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RepeaterListScreen(deps: deps, listId: r.listId, focusItem: r.item)));
  }

  /// "Read about it" on a place card: the place's article in the phone's Wikipedia, in the Library's reader.
  late final PlaceAbout _about = LibraryPlaceAbout(
    sources: widget.sources,
    openReader: (z, address) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ZimReaderScreen(sources: widget.sources, zim: z, address: address, layout: widget.layout)),
    ),
    onGetWikipedia: () => showAddToLibrary(context, widget.browse),
    onOpenLibrary: () => _goModule(ModuleId.library),
  );

  Widget _moduleScreen(ModuleId m) => switch (m) {
        ModuleId.ask => AskGate(
            app: widget.app,
            chat: widget.chat,
            onChooseModel: () => openModels(context, widget.app),
            onLeave: _goHome,
            ask: ({required bool readOnly, VoidCallback? onBack}) => AskScreen(app: widget.app, chat: widget.chat, location: widget.location, chatLocation: widget.chatLocation, onOpenSource: _openSource, onOpenPassage: _openSource, onOpenVideo: _openVideo, onOpenNavigation: _openNavigation, layout: widget.layout, readOnly: readOnly, onBack: onBack),
          ),
        ModuleId.library => BrowseScreen(browse: widget.browse, active: _module == ModuleId.library, layout: widget.layout, regions: widget.hub.regions, sharing: widget.hub.sharing),
        ModuleId.maps => MapsScreen(location: widget.location, maps: widget.maps, nav: widget.nav, themeId: widget.app.theme, regions: widget.hub.regions, notebooks: widget.notebooks?.notebook, onOpenEntry: _openEntry, onNewEntryAt: _newEntryAt, userLayers: widget.notebooks?.userLayers, onOpenRepeaterList: _openRepeaterList, about: _about),
        ModuleId.videos => VideosScreen(video: widget.video, zims: _zimVideos),
        // "Ask about this" is not drawn with no model (hidden, not greyed: Modules is the one place that explains).
        ModuleId.weather => WeatherScreen(weather: widget.hub.weather, onAsk: _askOn ? _askAbout : null, onOpenSettings: _openWeatherSettings, turnOn: _weatherTurnOn),
        ModuleId.discover => DiscoverScreen(discover: _discover),
        ModuleId.notebooks => widget.notebooks == null ? const Scaffold(body: Center(child: Text('Notebooks are not available on this device'))) : NotebooksScreen(deps: _notebookDeps!),
        ModuleId.settings => SettingsScreen(deps: _settingsDeps),
      };

  Widget _home() => HomeScreen(
    layout: widget.layout,
    weather: widget.hub.weather,
    onOpenWeather: () => _goModule(ModuleId.weather),
    turnOn: _weatherTurnOn,
    setup: _setup,
    search: _search,
    searchFootnote: pdfIndexShared == null
        ? null
        : PdfSearchNote(
            state: pdfIndexShared!,
            open: (z) => unawaited(showPdfPartSheet(context, pdfIndexShared!, z)),
          ),
    onAsk: _askFromHome,
    askOn: _askOn,
    onChooseModel: () => openModels(context, widget.app),
    onOpenSettings: _openSettings,
    onOpenShortcut: _openShortcut,
    updates: _updates,
    onOpenWeatherSettings: _openWeatherSettings,
    discover: _discover,
    onOpenDiscover: () => openDiscover(context, _discover),
  );

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final layout = widget.layout;
    return ListenableBuilder(
      listenable: layout,
      builder: (context, _) {
        // With no model Ask is left out of the bar and the rail (its pin is kept), with no gap.
        final pinned = [for (final m in layout.pinned) if (m != ModuleId.ask || _askOn) m];
        // The bar: Home, the pinned modules, Modules. A module that is open but not pinned shows under Modules.
        final int selected;
        if (_onModules) {
          selected = pinned.length + 1;
        } else if (_module == null) {
          selected = 0;
        } else {
          final i = pinned.indexOf(_module!);
          selected = i < 0 ? pinned.length + 1 : i + 1;
        }
        final show = _onModules ? 1 : (_module == null ? 0 : 2 + ModuleId.values.indexOf(_module!));
        void go(int i) {
          if (i == 0) {
            _goHome();
          } else if (i == pinned.length + 1) {
            _goModules();
          } else {
            _goModule(pinned[i - 1]);
          }
        }

        final stack = IndexedStack(
          index: show,
          children: [
            _home(),
            ModulesScreen(layout: layout, app: widget.app, onOpen: _goModule),
            for (final m in ModuleId.values) _built.contains(m) ? _moduleScreen(m) : const SizedBox.shrink(),
          ],
        );
        // A regular window (640 wide and up, iPad and Android tablets, either way round): the same destinations in a rail on the
        // left, in the bar's order; a stable frame that stays with the keyboard open.
        // A tablet held sideways: the main destinations in a rail at the side, which slides away to give the page the whole
        // width (a menu button at the top left brings it back). Upright, the bottom bar, as on a phone.
        // A short window (a phone held sideways, 390 high) keeps the rail, which scrolls when its destinations do not fit.
        // Cache on Linux in a window 1024 wide or more: the desktop sidebar, whichever way round the window is.
        if (isLinuxDesktop(context)) {
          return ListenableBuilder(
            listenable: widget.app,
            builder: (context, _) => DesktopShell(
              atHome: !_onModules && _module == null,
              module: _onModules ? null : _module,
              askOn: _askOn,
              askDetail: _askOn ? null : askOffDetail(widget.app),
              onHome: _goHome,
              onModule: _goModule,
              onModuleOptions: (c, m) => ModulesScreen(layout: layout, app: widget.app, onOpen: _goModule).moduleOptions(c, m),
              child: stack,
            ),
          );
        }
        if (hasRailWidth(context) && !isPortrait(context)) {
          final hidden = _railHidden;
          final reduce = MediaQuery.disableAnimationsOf(context);
          final rail = SafeArea(
            right: false,
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: IntrinsicHeight(
                    child: NavigationRail(
                    key: const ValueKey('nav-rail'),
                    minWidth: kRailWidth,
                    labelType: NavigationRailLabelType.all,
                    selectedIndex: selected,
                    onDestinationSelected: go,
                    destinations: [
                      const NavigationRailDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: Text('Home')),
                      for (final m in pinned) NavigationRailDestination(icon: Icon(m.icon), selectedIcon: Icon(m.selectedIcon), label: Text(m.label)),
                      const NavigationRailDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps), label: Text('Modules')),
                    ],
                    leading: IconButton(
                      key: const ValueKey('rail-hide'),
                      tooltip: 'Hide menu',
                      icon: const Icon(Icons.menu_open),
                      onPressed: () => _setRailHidden(true),
                    ),
                  ),
                  ),
                ),
              ),
            ),
          );
          return Scaffold(
            body: Row(
              children: [
                ClipRect(
                  child: AnimatedAlign(
                    duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.centerRight,
                    widthFactor: hidden ? 0 : 1,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [rail, VerticalDivider(width: 1, thickness: 1, color: Theme.of(context).dividerColor.withValues(alpha: 0.3))],
                    ),
                  ),
                ),
                Expanded(
                  child: hidden
                      ? Stack(
                          children: [
                            // The pages' top bars make room for the menu button at the top left.
                            MediaQuery(
                              data: MediaQuery.of(context).copyWith(
                                padding: MediaQuery.paddingOf(context).copyWith(left: MediaQuery.paddingOf(context).left + 52),
                                viewPadding: MediaQuery.viewPaddingOf(context).copyWith(left: MediaQuery.viewPaddingOf(context).left + 52),
                              ),
                              child: stack,
                            ),
                            Positioned(
                              left: 4,
                              top: MediaQuery.paddingOf(context).top + 4,
                              child: Material(
                                color: Theme.of(context).colorScheme.surface,
                                shape: CircleBorder(side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.4))),
                                child: IconButton(
                                  key: const ValueKey('rail-show'),
                                  tooltip: 'Show menu',
                                  icon: const Icon(Icons.menu),
                                  onPressed: () => _setRailHidden(false),
                                ),
                              ),
                            ),
                          ],
                        )
                      : stack,
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: stack,
          bottomNavigationBar: keyboardOpen
              ? null
              : NavigationBar(
                  selectedIndex: selected,
                  onDestinationSelected: go,
                  destinations: [
                    const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
                    for (final m in pinned) NavigationDestination(icon: Icon(m.icon), selectedIcon: Icon(m.selectedIcon), label: m.label),
                    const NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps), label: 'Modules'),
                  ],
                ),
        );
      },
    );
  }
}

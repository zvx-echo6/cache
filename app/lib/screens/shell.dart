import 'dart:async';
import 'dart:io' show Platform;

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
import '../chat/navigation_action.dart';
import '../guide/app_links.dart';
import '../guide/guide_book.dart';
import '../actions/setup_status.dart' show setupGuideTitle;
import '../guide/guide_reader.dart';
import '../regions/ui/region_actions.dart';
import '../pdf/index/pdf_index_app.dart';
import '../pdf/index/pdf_index_ui.dart' show PdfSearchNote, showPdfPartSheet;
import '../pdf/pdf_settings.dart' show PdfReaderLinks;
import '../layout/adaptive.dart';
import '../layout/layout_state.dart';
import '../layout/modules.dart';
import '../layout/modules_screen.dart';
import '../location/location_service.dart';
import '../maps/maps_state.dart';
import '../maps/user_layers.dart' show Repeater;
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
    required this.maps,
    required this.video,
    required this.browse,
    required this.nav,
    required this.layout,
    required this.hub,
    this.notebooks,
    this.railPrefs,
  });

  /// Where the rail's hidden-in-portrait choice is kept (the app's support folder when null).
  final RailPrefs? railPrefs;

  final AppState app;
  final ChatController chat;
  final SourcesState sources;
  final LocationService location;
  final ChatLocation? chatLocation;
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

  /// Ask is available: a chat model is on this device (AppState.askAvailable). Without one Cache is search only: Ask leaves the bar
  /// and the rail (its pin is kept and it takes its old place when a model comes), and every way into Ask is closed or explained.
  late bool _askOn = widget.app.askAvailable;

  /// The models folder has been read and held no chat model: the next one to arrive turns Ask on, and says so.
  /// Set in initState (a lazy initializer would first run after the model had already arrived).
  bool _noModelSeen = false;

  void _onApp() {
    final app = widget.app;
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
    widget.app.addListener(_onApp);
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
  }

  late final AppUpdates? _updates = Platform.isIOS || Platform.isAndroid
      ? AppUpdates(source: ReleaseFileSource(installedBuild: installedBuild), openUrl: widget.hub.openUrl, android: Platform.isAndroid, dismissed: DismissedUpdate())
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
    _navEvents?.cancel();
    _alertTaps?.cancel();
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

  void _goModule(ModuleId m) => setState(() {
        _module = m;
        _onModules = false;
        _built.add(m);
      });

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
      AppPlace.sharing => widget.hub.sharing == null ? null : SharingPage(sharing: widget.hub.sharing!),
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
  void _openVideo(String link, double time) => openVideoCitation(context, widget.video, video: link, offsetS: time);

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
        ModuleId.library => BrowseScreen(browse: widget.browse, active: _module == ModuleId.library, layout: widget.layout),
        ModuleId.maps => MapsScreen(location: widget.location, maps: widget.maps, nav: widget.nav, themeId: widget.app.theme, regions: widget.hub.regions, notebooks: widget.notebooks?.notebook, onOpenEntry: _openEntry, onNewEntryAt: _newEntryAt, userLayers: widget.notebooks?.userLayers, onOpenRepeaterList: _openRepeaterList, about: _about),
        ModuleId.videos => VideosScreen(video: widget.video),
        // "Ask about this" is not drawn with no model (hidden, not greyed: Modules is the one place that explains).
        ModuleId.weather => WeatherScreen(weather: widget.hub.weather, onAsk: _askOn ? _askAbout : null, onOpenSettings: _openWeatherSettings, turnOn: _weatherTurnOn),
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
        if (isRegular(context) && !isPortrait(context)) {
          final hidden = _railHidden;
          final reduce = MediaQuery.disableAnimationsOf(context);
          final rail = SafeArea(
            right: false,
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

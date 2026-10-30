import 'dart:async';

import 'package:cache_search/cache_search.dart' show GeoPoint;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../browse/browse_screen.dart';
import '../browse/browse_state.dart';
import '../browse/reader_screen.dart';
import '../browse/zim_urls.dart';
import '../chat/ask_about.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_location.dart';
import '../chat/navigation_action.dart';
import '../layout/layout_state.dart';
import '../layout/modules.dart';
import '../layout/modules_screen.dart';
import '../location/location_service.dart';
import '../maps/maps_state.dart';
import '../nav/nav_state.dart';
import '../regions/ui/regions_list_sheet.dart';
import '../search/app_search.dart';
import '../search/app_search_providers.dart';
import '../search/notebook_search_providers.dart';
import '../regions/ui/regions_screen.dart';
import '../settings/hub.dart';
import '../sources/sources_state.dart';
import '../video/video_state.dart';
import '../weather/alert_notifier.dart';
import '../weather/alert_watch.dart';
import 'ask_screen.dart';
import 'home_screen.dart';
import 'maps_screen.dart';
import 'models_screen.dart';
import 'download_confirm.dart' show openStorageForSpace;
import '../notebook/notebook_model.dart';
import 'notebooks/notebook_screen.dart';
import 'notebooks/notebooks_screen.dart';
import 'notebooks/quick_add_sheet.dart';
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
  });

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

  @override
  void initState() {
    super.initState();
    _navEvents = widget.nav.events.listen((e) {
      if (e is AddToHomeRequested && mounted) addToHome(context, widget.layout, Shortcut.place(e.place));
      if (e is MapRequested && mounted) _goModule(ModuleId.maps);
    });
    // An alert pop-up tapped while the app runs, or the one that started it: open the Weather screen on that alert.
    _alertTaps = LocalAlertNotifier.instance.taps.listen(_openAlert);
    LocalAlertNotifier.instance.launchFocus().then((f) {
      if (f != null && mounted) _openAlert(f);
    }).catchError((_) {});
    // "Free up space" in any download pop-up opens Settings > Storage.
    openStorageForSpace = (context) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoragePage(deps: _settingsDeps)));
  }

  void _openAlert(AlertFocus f) {
    widget.hub.weather.focus.value = f;
    _goModule(ModuleId.weather);
  }

  @override
  void dispose() {
    _navEvents?.cancel();
    _alertTaps?.cancel();
    super.dispose();
  }

  void _goHome() => setState(() {
        _module = null;
        _onModules = false;
      });

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

  void _openSource(String address) {
    _goModule(ModuleId.library);
    widget.browse.openAddress(address);
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
  );

  /// "Get your area": the Regions sheet for where the phone is; without a position, the regions to search.
  void _getArea(BuildContext context) {
    final regions = widget.hub.regions;
    if (regions == null) {
      _say('Regions are not available on this phone');
      return;
    }
    final here = _here;
    if (here != null) {
      showRegionsSheet(context, regions, lat: here.lat, lon: here.lon);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionsScreen(regions: regions, initialTab: 0)));
    }
  }

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

  /// Enter in Home's search: a new chat that asks exactly what was typed.
  void _askFromHome(String text) {
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
    widget.chat.newChat();
    _goModule(ModuleId.ask);
    widget.chat.send(about.question, seed: about);
  }

  void _openWeatherSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WeatherPage(deps: _settingsDeps)));
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
          _say('That page is not on this phone any more');
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

  Widget _moduleScreen(ModuleId m) => switch (m) {
        ModuleId.ask => AskScreen(app: widget.app, chat: widget.chat, location: widget.location, chatLocation: widget.chatLocation, onOpenSource: _openSource, onOpenVideo: _openVideo, onOpenNavigation: _openNavigation, layout: widget.layout),
        ModuleId.library => BrowseScreen(browse: widget.browse, active: _module == ModuleId.library, layout: widget.layout),
        ModuleId.maps => MapsScreen(location: widget.location, maps: widget.maps, nav: widget.nav, themeId: widget.app.theme, regions: widget.hub.regions, notebooks: widget.notebooks?.notebook, onOpenEntry: _openEntry, onNewEntryAt: _newEntryAt, userLayers: widget.notebooks?.userLayers),
        ModuleId.videos => VideosScreen(video: widget.video),
        ModuleId.weather => WeatherScreen(weather: widget.hub.weather, onAsk: _askAbout, onOpenSettings: _openWeatherSettings, turnOn: _weatherTurnOn),
        ModuleId.notebooks => widget.notebooks == null ? const Scaffold(body: Center(child: Text('Notebooks are not available on this phone'))) : NotebooksScreen(deps: widget.notebooks!),
        ModuleId.settings => SettingsScreen(deps: _settingsDeps),
      };

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final layout = widget.layout;
    return ListenableBuilder(
      listenable: layout,
      builder: (context, _) {
        final pinned = layout.pinned;
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
        return Scaffold(
          body: IndexedStack(
            index: show,
            children: [
              HomeScreen(
                layout: layout,
                weather: widget.hub.weather,
                onOpenWeather: () => _goModule(ModuleId.weather),
                turnOn: _weatherTurnOn,
                setup: _setup,
                search: _search,
                onAsk: _askFromHome,
                onOpenSettings: _openSettings,
                onOpenShortcut: _openShortcut,
              ),
              ModulesScreen(layout: layout, app: widget.app, onOpen: _goModule),
              for (final m in ModuleId.values) _built.contains(m) ? _moduleScreen(m) : const SizedBox.shrink(),
            ],
          ),
          bottomNavigationBar: keyboardOpen
              ? null
              : NavigationBar(
                  selectedIndex: selected,
                  onDestinationSelected: (i) {
                    if (i == 0) {
                      _goHome();
                    } else if (i == pinned.length + 1) {
                      _goModules();
                    } else {
                      _goModule(pinned[i - 1]);
                    }
                  },
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

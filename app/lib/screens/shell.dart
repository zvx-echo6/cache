import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../browse/browse_screen.dart';
import '../browse/browse_state.dart';
import '../browse/reader_screen.dart';
import '../browse/zim_urls.dart';
import '../chat/chat_controller.dart';
import '../chat/navigation_action.dart';
import '../layout/layout_state.dart';
import '../layout/modules.dart';
import '../layout/modules_screen.dart';
import '../location/location_service.dart';
import '../maps/maps_state.dart';
import '../nav/nav_state.dart';
import '../settings/hub.dart';
import '../sources/sources_state.dart';
import '../video/video_state.dart';
import 'ask_screen.dart';
import 'home_screen.dart';
import 'maps_screen.dart';
import 'settings/deps.dart';
import 'settings/weather_page.dart';
import 'settings_screen.dart';
import 'videos/videos_screen.dart';
import 'weather_screen.dart';

/// The app's frame: Home first, up to three pinned modules, Modules last. The screens are built the first time they are
/// shown and then kept alive.
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.app,
    required this.chat,
    required this.sources,
    required this.location,
    required this.maps,
    required this.video,
    required this.browse,
    required this.nav,
    required this.layout,
    required this.hub,
  });

  final AppState app;
  final ChatController chat;
  final SourcesState sources;
  final LocationService location;
  final MapsState maps;
  final VideoState video;
  final BrowseState browse;
  final NavState nav;
  final LayoutState layout;
  final SettingsHub hub;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// The module on screen; null with [_onModules] false is Home.
  ModuleId? _module;
  bool _onModules = false;
  final Set<ModuleId> _built = {};
  StreamSubscription<NavEvent>? _navEvents;

  @override
  void initState() {
    super.initState();
    _navEvents = widget.nav.events.listen((e) {
      if (e is AddToHomeRequested && mounted) addToHome(context, widget.layout, Shortcut.place(e.place));
    });
  }

  @override
  void dispose() {
    _navEvents?.cancel();
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

  /// "Ask about this" on the Weather screen: a new chat that asks the question straight away.
  void _askAbout(String question) {
    widget.chat.newChat();
    _goModule(ModuleId.ask);
    widget.chat.send(question);
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
    }
  }

  Widget _moduleScreen(ModuleId m) => switch (m) {
        ModuleId.ask => AskScreen(app: widget.app, chat: widget.chat, location: widget.location, onOpenSource: _openSource, onOpenNavigation: _openNavigation, layout: widget.layout),
        ModuleId.library => BrowseScreen(browse: widget.browse, active: _module == ModuleId.library, layout: widget.layout),
        ModuleId.maps => MapsScreen(location: widget.location, maps: widget.maps, nav: widget.nav, themeId: widget.app.theme),
        ModuleId.videos => VideosScreen(video: widget.video),
        ModuleId.weather => WeatherScreen(weather: widget.hub.weather, onAsk: _askAbout, onOpenSettings: _openWeatherSettings),
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
                onOpenAsk: () => _goModule(ModuleId.ask),
                onOpenSettings: _openSettings,
                onOpenShortcut: _openShortcut,
              ),
              ModulesScreen(layout: layout, onOpen: _goModule),
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

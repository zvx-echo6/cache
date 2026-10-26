import 'package:flutter/material.dart';

import '../app_state.dart';
import '../browse/browse_state.dart';
import '../chat/chat_controller.dart';
import '../location/location_service.dart';
import '../maps/maps_state.dart';
import '../nav/nav_state.dart';
import '../sources/sources_state.dart';
import '../video/video_state.dart';
import 'browse_screen.dart';
import 'ask_screen.dart';
import 'home_screen.dart';
import 'maps_screen.dart';

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
  });

  final AppState app;
  final ChatController chat;
  final SourcesState sources;
  final LocationService location;
  final MapsState maps;
  final VideoState video;
  final BrowseState browse;
  final NavState nav;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  void _openSource(String address) {
    setState(() => _index = 2);
    widget.browse.openAddress(address);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(
            app: widget.app,
            sources: widget.sources,
            chat: widget.chat,
            onOpenAsk: () => setState(() => _index = 1),
          ),
          AskScreen(
            app: widget.app,
            chat: widget.chat,
            onOpenSource: _openSource,
          ),
          BrowseScreen(
            video: widget.video,
            browse: widget.browse,
            active: _index == 2,
          ),
          MapsScreen(
            location: widget.location,
            maps: widget.maps,
            nav: widget.nav,
            themeId: widget.app.theme,
          ),
        ],
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Ask',
                ),
                NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book),
                  label: 'Browse',
                ),
                NavigationDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: 'Maps',
                ),
              ],
            ),
    );
  }
}

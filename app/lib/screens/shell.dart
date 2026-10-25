import 'package:flutter/material.dart';

import '../app_state.dart';
import '../chat/chat_controller.dart';
import 'ask_screen.dart';
import 'home_screen.dart';
import 'placeholder_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.app, required this.chat});

  final AppState app;
  final ChatController chat;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(app: widget.app, onOpenAsk: () => setState(() => _index = 1)),
          AskScreen(app: widget.app, chat: widget.chat),
          const PlaceholderScreen(title: 'Browse', message: 'Browse comes in step 3'),
          const PlaceholderScreen(title: 'Maps', message: 'Maps comes in step 8'),
        ],
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Ask'),
                NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: 'Browse'),
                NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Maps'),
              ],
            ),
    );
  }
}

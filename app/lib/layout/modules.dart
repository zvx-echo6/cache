import 'package:flutter/material.dart';

import '../brand.dart';

/// The big pieces of the app. Each has a screen of its own; the bottom bar pins up to [kMaxPinned] of them.
/// (Games, Journal, Weather and Alerts join this list when their screens exist.)
enum ModuleId {
  ask('Ask', Icons.chat_bubble_outline, Icons.chat_bubble, BrandTile.ask),
  library('Library', Icons.menu_book_outlined, Icons.menu_book, BrandTile.library),
  maps('Maps', Icons.map_outlined, Icons.map, BrandTile.maps),
  videos('Videos', Icons.play_circle_outline, Icons.play_circle, BrandTile.videos),
  settings('Settings', Icons.settings_outlined, Icons.settings, BrandTile.settings);

  const ModuleId(this.label, this.icon, this.selectedIcon, this.tile);

  final String label;

  /// The simple line icon used in the bottom bar (recoloured by the theme).
  final IconData icon;
  final IconData selectedIcon;

  /// The painted tile used on the Modules screen and on Home shortcuts.
  final BrandTile tile;

  static ModuleId? byName(String? n) {
    for (final m in ModuleId.values) {
      if (m.name == n) return m;
    }
    return null;
  }
}

/// The most modules the bottom bar holds between Home and Modules.
const int kMaxPinned = 3;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_fs.dart';

/// How Bookshelves looks: the call-number list with class bands (the default on every screen size), card-catalogue drawers, or
/// spines on a shelf.
enum ShelfLook {
  list('List'),
  drawers('Drawers'),
  spines('Spines');

  const ShelfLook(this.label);
  final String label;
}

/// The Bookshelves look chosen on this device, remembered across restarts (a small file next to the settings).
class ShelfLookPrefs extends ChangeNotifier {
  ShelfLookPrefs({Directory? dirOverride}) : _dir = dirOverride ?? testDir;

  /// Tests: the folder every ShelfLookPrefs uses when none is given.
  static Directory? testDir;

  static const String fileName = 'bookshelves.json';

  final Directory? _dir;
  ShelfLook _look = ShelfLook.list;
  bool _read = false;

  AppFs get _fs => createAppFs(supportOverride: _dir);

  ShelfLook get look => _look;

  /// Reads the look kept on this device (List when nothing is kept, or the file cannot be read).
  Future<ShelfLook> load() async {
    if (_read) return _look;
    _read = true;
    try {
      final text = await _fs.readString(AppRoot.support, fileName);
      if (text != null) {
        final j = jsonDecode(text);
        final name = j is Map ? j['look'] : null;
        final found = ShelfLook.values.where((l) => l.name == name).firstOrNull;
        if (found != null && found != _look) {
          _look = found;
          notifyListeners();
        }
      }
    } catch (_) {}
    return _look;
  }

  Future<void> set(ShelfLook look) async {
    if (look == _look) return;
    _look = look;
    notifyListeners();
    try {
      await _fs.writeString(AppRoot.support, fileName, jsonEncode({'look': look.name}));
    } catch (_) {}
  }
}

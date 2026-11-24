import 'dart:convert';
import 'dart:io';

import '../app_fs.dart';

/// What the directions screen remembers across restarts (a small file next to the settings): the way of travel and its options.
/// Only the person's own taps are kept; a route the assistant planned is shown, never remembered.
class TravelChoices {
  const TravelChoices({
    this.mode = 'drive',
    this.avoidHighways = false,
    this.avoidTolls = false,
    this.landAccess = 'pragmatic',
    this.walkOffroad = false,
    this.bikeDirt = false,
    this.atvSideBySide = false,
  });

  /// The engine's id of the choice shown: drive, walk, bike, offroad_foot, offroad_moto, offroad_4w or offroad_sxs.
  final String mode;
  final bool avoidHighways;
  final bool avoidTolls;

  /// `pragmatic` (Standard) or `emergency`.
  final String landAccess;

  /// The option each way of travel comes back to: Walk's Off-road, Bike's Dirt bike, ATV's Side-by-side.
  final bool walkOffroad;
  final bool bikeDirt;
  final bool atvSideBySide;

  static const List<String> modes = ['drive', 'walk', 'bike', 'offroad_foot', 'offroad_moto', 'offroad_4w', 'offroad_sxs'];

  Map<String, dynamic> toJson() => {
        'mode': mode,
        'avoid_highways': avoidHighways,
        'avoid_tolls': avoidTolls,
        'land_access': landAccess,
        'walk_offroad': walkOffroad,
        'bike_dirt': bikeDirt,
        'atv_side_by_side': atvSideBySide,
      };

  /// What a file says; anything unknown or damaged is left at its default.
  static TravelChoices fromJson(dynamic j) {
    if (j is! Map) return const TravelChoices();
    bool b(String k) => j[k] == true;
    final mode = j['mode'];
    final land = j['land_access'];
    return TravelChoices(
      mode: mode is String && modes.contains(mode) ? mode : 'drive',
      avoidHighways: b('avoid_highways'),
      avoidTolls: b('avoid_tolls'),
      landAccess: land == 'emergency' ? 'emergency' : 'pragmatic',
      walkOffroad: b('walk_offroad'),
      bikeDirt: b('bike_dirt'),
      atvSideBySide: b('atv_side_by_side'),
    );
  }
}

/// Reads and writes [TravelChoices] in `directions.json` of the support folder. Failing to read or write is never an error:
/// the screen then starts at Drive, as it always did.
class TravelPrefs {
  TravelPrefs({Directory? dirOverride}) : _dir = dirOverride ?? testDir;

  /// Tests: the folder every TravelPrefs uses when none is given.
  static Directory? testDir;

  static const String fileName = 'directions.json';

  final Directory? _dir;

  AppFs get _fs => createAppFs(supportOverride: _dir);

  Future<TravelChoices> load() async {
    try {
      final text = await _fs.readString(AppRoot.support, fileName);
      if (text != null) return TravelChoices.fromJson(jsonDecode(text));
    } catch (_) {}
    return const TravelChoices();
  }

  Future<void> save(TravelChoices c) async {
    try {
      await _fs.writeString(AppRoot.support, fileName, jsonEncode(c.toJson()));
    } catch (_) {}
  }
}

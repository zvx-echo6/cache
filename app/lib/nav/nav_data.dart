import 'dart:io';

/// The files the map's search and routing read, found in the packs folder (`<files>/packs/<region>/`):
///
///  * `places.sqlite`: the places pack (names, categories, phone, hours, summaries, and the vectors for meaning search);
///  * `valhalla/tiles.tar` with the Valhalla shim library: road routing;
///  * `offroad.sqlite` and `elevation.pmtiles`: off-road legs.
///
/// Each is optional; the core offers what is installed. This builds the `places`, `routing` and `user` sections of the core's
/// config from what it finds.
class NavData {
  const NavData({this.places = const [], this.tiles, this.shim, this.offroadPack, this.elevation, this.userDb});

  final List<String> places;
  final String? tiles;
  final String? shim;
  final String? offroadPack;
  final String? elevation;
  final String? userDb;

  bool get hasPlaces => places.isNotEmpty;
  bool get hasRouting => tiles != null && shim != null;

  Map<String, dynamic> toConfig() => {
        if (hasPlaces) 'places': {'packs': places},
        if (hasRouting)
          'routing': {
            'valhalla': {'tiles': tiles, 'shim': shim},
            if (offroadPack != null && elevation != null) 'offroad': {'pack': offroadPack, 'elevation': elevation},
          },
        if (userDb != null) 'user': {'db_path': userDb},
      };

  /// Looks in [packsDir]. [shim] is the full path of the Valhalla shim library, [userDb] where saved places live.
  static NavData find(Directory packsDir, {String? shim, String? userDb}) {
    final places = <String>[];
    String? tiles, offroad, elevation;
    if (packsDir.existsSync()) {
      final regions = packsDir.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final r in regions) {
        final p = File('${r.path}/places.sqlite');
        if (p.existsSync()) places.add(p.path);
        final t = File('${r.path}/valhalla/tiles.tar');
        if (tiles == null && t.existsSync()) tiles = t.path;
        final o = File('${r.path}/offroad.sqlite');
        final e = File('${r.path}/elevation.pmtiles');
        if (offroad == null && o.existsSync() && e.existsSync()) {
          offroad = o.path;
          elevation = e.path;
        }
      }
    }
    return NavData(places: places, tiles: tiles, shim: shim, offroadPack: offroad, elevation: elevation, userDb: userDb);
  }
}

/// The folder an Android app's native libraries were installed in, found from `/proc/self/maps` (the core refuses a library
/// name without a path, and Dart has no direct way to ask). Null when it cannot be told.
String? nativeLibraryPath(String libraryName, {String maps = '/proc/self/maps', bool Function(String path)? exists}) {
  final has = exists ?? (String p) => File(p).existsSync();
  try {
    final f = File(maps);
    if (!f.existsSync()) return null;
    for (final line in f.readAsLinesSync()) {
      final m = RegExp(r'\s(/\S*)$').firstMatch(line);
      if (m == null) continue;
      final path = m.group(1)!;
      final slash = path.lastIndexOf('/');
      if (slash > 0 && path.substring(slash + 1) == 'libcache_search.so') {
        final candidate = '${path.substring(0, slash)}/$libraryName';
        return has(candidate) ? candidate : null;
      }
    }
  } catch (_) {}
  return null;
}

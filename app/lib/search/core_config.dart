import 'dart:io';

/// The sections of the cs_open config besides the ZIM sources (cache_search.h): saved places (`user`), live data
/// (`live`), the places packs (`places`: nearby and locate) and routing (`routing`: navigate).
///
/// Data lives in the app's external files folder ([filesDir], `Android/data/APP/files`), where it can be pushed
/// with adb or copied in by the app:
///   packs/REGION/places.sqlite            places packs (every region folder that has one)
///   packs/REGION/valhalla/tiles.tar       road routing tiles (libvalhalla_shim.so is packaged in the APK)
///   packs/REGION/offroad.sqlite, elevation.pmtiles   off-road routing
///   live-sources/*.json                     live data source definitions
/// The databases the app writes (saved places, downloaded live data) are in [supportDir].
Map<String, dynamic> buildCoreExtras({required Directory filesDir, required Directory supportDir, String shim = 'libvalhalla_shim.so'}) {
  final packsDir = Directory('${filesDir.path}/packs');
  final places = <String>[];
  String? tiles, offroadPack, elevation;
  if (packsDir.existsSync()) {
    final regions = packsDir.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final r in regions) {
      final p = File('${r.path}/places.sqlite');
      if (p.existsSync()) places.add(p.path);
      final t = File('${r.path}/valhalla/tiles.tar');
      if (tiles == null && t.existsSync()) tiles = t.path;
      final o = File('${r.path}/offroad.sqlite');
      final e = File('${r.path}/elevation.pmtiles');
      if (offroadPack == null && o.existsSync() && e.existsSync()) {
        offroadPack = o.path;
        elevation = e.path;
      }
    }
  }
  return {
    'user': {'db_path': '${supportDir.path}/user.sqlite'},
    'live': {'db_path': '${supportDir.path}/live.sqlite', 'sources_dir': '${filesDir.path}/live-sources'},
    'places': {'packs': places},
    if (tiles != null || offroadPack != null)
      'routing': {
        if (tiles != null) 'valhalla': {'tiles': tiles, 'shim': shim},
        if (offroadPack != null) 'offroad': {'pack': offroadPack, 'elevation': elevation},
      },
  };
}

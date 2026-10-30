import 'dart:io';

/// Where Cache's published data lives (road routing, places, the region catalogue). `https://cache.echo6.co` serves the same
/// bucket with the same paths: build with `--dart-define=CACHE_DATA_BASE=https://cache.echo6.co` to use it. No trailing slash.
const String kDataBaseUrl = String.fromEnvironment('CACHE_DATA_BASE', defaultValue: 'https://data.cached.info');

/// Where the core's region engine fetches road routing tiles from.
const String kRoutingBaseUrl = '$kDataBaseUrl/routing/';

/// Where the core's region engine fetches places tiles from (docs/PLACES-TILES.md).
const String kPlacesBaseUrl = '$kDataBaseUrl/places/';

/// The single-region places packs copied in by hand: `packs/*/places.sqlite` under [filesDir], sorted. Called again when the
/// sources are refreshed, so a pack pushed with adb is searched without a restart.
List<String> legacyPlacesPacks(Directory filesDir) {
  final packsDir = Directory('${filesDir.path}/packs');
  if (!packsDir.existsSync()) return [];
  final regions = packsDir.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final r in regions)
      if (File('${r.path}/places.sqlite').existsSync()) File('${r.path}/places.sqlite').path,
  ];
}

/// The sections of the cs_open config besides the ZIM sources (cache_search.h): saved places (`user`), live data
/// (`live`), the places packs (`places`: nearby and locate) and routing (`routing`: navigate).
///
/// Data lives in the app's external files folder ([filesDir], `Android/data/APP/files`), where it can be pushed
/// with adb or copied in by the app:
///   packs/REGION/places.sqlite            single-region places packs (every region folder that has one)
///   packs/REGION/valhalla/tiles.tar       road routing tiles (libvalhalla_shim.so is packaged in the APK)
///   packs/REGION/offroad.sqlite, elevation.pmtiles   off-road routing
///   live-defs/*.json                        definitions of the live data sources that are switched on (the app keeps them)
/// The databases the app writes (saved places, downloaded live data) are in [supportDir].
///
/// Road routing from downloaded regions: the core's region engine (the `regions` section) keeps its tiles in
/// `SUPPORT/regions/tiles/BUILD` and fetches a route's tiles when online; the navigate tool routes on that folder whenever no
/// packs/*/valhalla/tiles.tar is there, so routing is always configured (with the shim) and a region that finishes downloading
/// is used by the next route. Places from downloaded regions are merged by the same engine into one database under
/// `SUPPORT/regions/places` (`merged_dir`), which the core reads next to the single-region packs.
Map<String, dynamic> buildCoreExtras({
  required Directory filesDir,
  required Directory supportDir,
  String shim = 'libvalhalla_shim.so',
  Directory? layerDefsDir,
  bool? useLinkedRouter,
  String regionsBaseUrl = kRoutingBaseUrl,
  String placesBaseUrl = kPlacesBaseUrl,
}) {
  final packsDir = Directory('${filesDir.path}/packs');
  String? tiles, offroadPack, elevation;
  if (packsDir.existsSync()) {
    final regions = packsDir.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final r in regions) {
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
    'live': {'db_path': '${supportDir.path}/live.sqlite', 'sources_dir': '${filesDir.path}/live-defs'},
    'places': {'packs': legacyPlacesPacks(filesDir), 'merged_dir': '${supportDir.path}/regions/places'},
    // The map layer engine: its folder (tile stores, cache, user definitions) and the starter definitions. The
    // catalogue address is the core's default (https://cache.echo6.co/catalogue.json).
    'layers': {
      'dir': '${supportDir.path}/layers',
      'defs_dirs': [(layerDefsDir ?? Directory('${supportDir.path}/layer-defs')).path],
    },
    'routing': {
      // No tiles.tar: the region engine's folder (an empty `tiles`).
      'valhalla': {'tiles': tiles ?? '', 'shim': (useLinkedRouter ?? Platform.isIOS) ? 'linked' : shim},
      if (offroadPack != null) 'offroad': {'pack': offroadPack, 'elevation': elevation},
    },
    // Notebooks: their database and the folder of their photos and attached files.
    'notebook': notebookConfig(supportDir),
    // The region engine (cs_open's regions section): where it keeps its tiles and where it fetches road routing and places from.
    'regions': regionsConfig(supportDir, routingBaseUrl: regionsBaseUrl, placesBaseUrl: placesBaseUrl),
  };
}

/// The Notebooks section of cs_open: notebook.sqlite and its media folder (photos/, thumbs/, files/).
Map<String, String> notebookConfig(Directory supportDir) =>
    {'db_path': '${supportDir.path}/notebook/notebook.sqlite', 'media_dir': '${supportDir.path}/notebook'};

/// The region engine's config, the same for the search core and the regions screen (one engine per folder in the process).
Map<String, Object?> regionsConfig(Directory supportDir, {String routingBaseUrl = kRoutingBaseUrl, String placesBaseUrl = kPlacesBaseUrl}) =>
    {'dir': '${supportDir.path}/regions', 'base_url': routingBaseUrl, 'places_base_url': placesBaseUrl};

/// The folder Android unpacked this app's native libraries to (where libvalhalla_shim.so is), found from where
/// libflutter.so is mapped (it is loaded before any Dart runs, unlike the core library, which the core's own isolate opens
/// after these settings are built). The core checks the shim with a plain file test, so it needs this full path, not a
/// bare library name. Null when it cannot be found (not Android, or the library is not mapped).
String? nativeLibraryDir({String mapsFile = '/proc/self/maps', String library = 'libflutter.so'}) {
  try {
    for (final line in File(mapsFile).readAsLinesSync()) {
      final i = line.indexOf('/');
      if (i < 0 || !line.endsWith('/$library')) continue;
      final path = line.substring(i);
      if (path.contains('!')) continue; // inside the apk, not a folder
      return path.substring(0, path.length - library.length - 1);
    }
  } catch (_) {}
  return null;
}

/// The shim's full path in [dir] ([nativeLibraryDir]), or the bare name when [dir] is null.
String shimPath(String? dir, {String name = 'libvalhalla_shim.so'}) => dir == null ? name : '$dir/$name';

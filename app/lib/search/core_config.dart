import 'dart:io';

/// Where Cache's published data lives (road routing, places, the region catalogue). `https://cache.echo6.co` serves the same
/// bucket with the same paths: build with `--dart-define=CACHE_DATA_BASE=https://cache.echo6.co` to use it. No trailing slash.
const String kDataBaseUrl = String.fromEnvironment('CACHE_DATA_BASE', defaultValue: 'https://data.cached.info');

/// Where the core's region engine fetches road routing tiles from.
const String kRoutingBaseUrl = '$kDataBaseUrl/routing/';

/// Where the core's region engine fetches places tiles from (docs/PLACES-TILES.md).
const String kPlacesBaseUrl = '$kDataBaseUrl/places/';

/// The sections of the cs_open config besides the ZIM sources (cache_search.h): saved places (`user`), live data (`live`), places
/// (`places`: nearby and locate), routing (`routing`: navigate) and the region engine (`regions`).
///
/// Everything comes from region downloads (there is no folder of hand-placed packs any more): the region engine keeps road routing
/// tiles in `SUPPORT/regions/tiles/BUILD` (the navigate tool routes on that folder, so routing is always configured, with the shim,
/// and a region that finishes downloading is used by the next route), merges places into one database under
/// `SUPPORT/regions/places`, and the app keeps the off-road packs in `SUPPORT/regions/offroad` (regions_state.dart), read with
/// the map's elevation layer. `live-defs/*.json` under [filesDir] are the live data sources that are switched on (the app keeps
/// them). The databases the app writes (saved places, downloaded live data) are in [supportDir].
Map<String, dynamic> buildCoreExtras({
  required Directory filesDir,
  required Directory supportDir,
  String shim = 'libvalhalla_shim.so',
  Directory? layerDefsDir,
  bool? useLinkedRouter,
  String regionsBaseUrl = kRoutingBaseUrl,
  String placesBaseUrl = kPlacesBaseUrl,
}) {
  return {
    'user': {'db_path': '${supportDir.path}/user.sqlite'},
    'live': {'db_path': '${supportDir.path}/live.sqlite', 'sources_dir': '${filesDir.path}/live-defs'},
    'places': {'packs': const <String>[], 'merged_dir': '${supportDir.path}/regions/places'},
    // The map layer engine: its folder (tile stores, cache, user definitions) and the starter definitions. The
    // catalogue address is the core's default (https://cache.echo6.co/catalogue.json).
    'layers': {
      'dir': '${supportDir.path}/layers',
      'defs_dirs': [(layerDefsDir ?? Directory('${supportDir.path}/layer-defs')).path],
    },
    'routing': {
      // The region engine's folder (an empty `tiles`).
      'valhalla': {'tiles': '', 'shim': (useLinkedRouter ?? Platform.isIOS) ? 'linked' : shim},
      // Off-road: the region packs downloaded with regions (regions_state.dart), with elevation from the map's elevation layer.
      'offroad': {'dir': '${supportDir.path}/regions/offroad'},
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

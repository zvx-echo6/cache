// FAKE: stand-in catalogue until the layer engine (branch layers-core) provides the real one.
//
// The project publishes its catalogue at [kCatalogueUrl]; the fake engine fetches it when it can and keeps the
// last copy, and its layers (BLM routes, MVUM, Forest Service trails, public lands, ...) replace or add to the
// definitions below. These are what the app has before the first fetch, plus the layers the published catalogue
// does not carry yet: the base map, elevation, contours, land cover and satellite.
//
// Entries marked `fake_unavailable` need the Rust core (on-phone contours, area cuts) and cannot be served by
// the Dart fake; they show up in the catalogue so the screens can be built and tested.

const String kCatalogueUrl = 'https://cache.echo6.co/catalogue.json';

const Map<String, dynamic> _ofmLimits = {
  // OpenFreeMap's terms for offline downloads: each download at most 3,000 tiles or 50 MB.
  'download_limit_tiles': 3000,
  'download_limit_bytes': 50 * 1024 * 1024,
};

const List<Map<String, dynamic>> fakeCatalogue = [
  {
    // The project's own base map: the Protomaps v4 planet in its storage bucket, z0-15, the same for everyone.
    // The published catalogue carries the real entry (same id, with its source address) and replaces this one
    // as soon as it is fetched. This copy is only the offline-first fallback: it has no address, and the Maps
    // tab says the base map is not published yet instead of drawing a blank.
    'id': 'basemap',
    'fallback': true,
    'title': 'Base map',
    'description': 'Roads, places, water and land from OpenStreetMap, drawn in the app\'s own colours.',
    'license': 'Map data ODbL 1.0 (OpenStreetMap contributors); Protomaps basemap tiles',
    'attribution': '© OpenStreetMap contributors · Protomaps',
    'coverage': 'Worldwide',
    'kind': 'basemap',
    'layout': 'protomaps-v4',
    'default_on': true,
    'source': {
      'type': 'pmtiles',
      'url': '',
      'minzoom': 0,
      'maxzoom': 15,
      'tile_format': 'mvt',
    },
    'offline': {'allowed': true},
    'recipe': 'tiles_as_is',
    'approx_tile_bytes': 60000,
    'download_limit_tiles': 3000,
    'download_limit_bytes': 50 * 1024 * 1024,
  },
  {
    // Kept for servers that use the OpenMapTiles layout and for the framework itself; off until switched on
    // under Advanced.
    'id': 'openfreemap',
    'title': 'Base map (OpenFreeMap)',
    'description': 'OpenStreetMap from OpenFreeMap\'s public servers, in the OpenMapTiles layout. Off unless you switch it on.',
    'license': 'Map data ODbL 1.0 (OpenStreetMap); design CC BY 4.0 (OpenMapTiles)',
    'attribution': '© OpenFreeMap © OpenMapTiles Data from OpenStreetMap',
    'coverage': 'Worldwide',
    'kind': 'basemap',
    'layout': 'openmaptiles',
    'enabled_by_default': false,
    'source': {'type': 'tilejson', 'url': 'https://tiles.openfreemap.org/planet', 'minzoom': 0, 'maxzoom': 14},
    'recipe': 'tiles_as_is',
    'updates': 'weekly',
    'approx_tile_bytes': 60000,
    ..._ofmLimits,
  },
  {
    'id': 'landcover',
    'title': 'Land cover',
    'description': 'Forest, grass, crops, water and built-up land from satellite images, cut to your area on the phone.',
    'license': 'CC BY 4.0 (ESA WorldCover 2021)',
    'attribution': '© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium',
    'coverage': 'Worldwide',
    'kind': 'raster',
    'source': {'type': 'cog', 'url': '', 'minzoom': 0, 'maxzoom': 12, 'tile_size': 256},
    'recipe': 'raster_cut',
    'fake_unavailable': true,
  },
  {
    'id': 'satellite',
    'title': 'Satellite',
    'description': 'Aerial photos. Needs a connection; its terms do not allow keeping it offline.',
    'license': 'Esri World Imagery terms (to be checked)',
    'attribution': 'Esri, Maxar, Earthstar Geographics',
    'coverage': 'Worldwide',
    'kind': 'raster',
    'online_only': true,
    'source': {'type': 'xyz', 'url': '', 'minzoom': 0, 'maxzoom': 18, 'tile_size': 256},
    'recipe': 'online_only',
    'fake_unavailable': true,
  },
  {
    'id': 'hillshade',
    'title': 'Hillshade',
    'description': 'Shaded relief drawn on the phone from elevation data. Worldwide at 30 m, the USA at 10 m.',
    'license': 'Open data from many national sources (see mapterhorn.com/attribution)',
    'attribution': '© Mapterhorn',
    'coverage': 'Worldwide',
    'kind': 'hillshade',
    'encoding': 'terrarium',
    'source': {
      'type': 'xyz',
      'url': 'https://tiles.mapterhorn.com/{z}/{x}/{y}.webp',
      'minzoom': 0,
      'maxzoom': 12,
      'tile_size': 512,
    },
    'recipe': 'elevation_to_hillshade',
    'updates': 'never',
    'approx_tile_bytes': 40000,
    'download_limit_tiles': 3000,
    'download_limit_bytes': 120 * 1024 * 1024,
  },
  {
    'id': 'contours',
    'title': 'Contours',
    'description': 'Elevation lines with heights in feet, made on the phone from the elevation data.',
    'license': 'Open data from many national sources (see mapterhorn.com/attribution)',
    'attribution': '© Mapterhorn',
    'coverage': 'Worldwide',
    'kind': 'contours',
    'plural': true,
    'source_layer': 'contours',
    'source': {'type': 'elevation', 'url': '', 'minzoom': 9, 'maxzoom': 14},
    'recipe': 'elevation_to_contours',
    'fake_unavailable': true,
  },
];

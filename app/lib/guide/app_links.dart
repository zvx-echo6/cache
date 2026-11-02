/// The places in Cache the guide can link to: `cache://<path>` in the guide's Markdown (the reader opens them; the guide's search
/// library keeps only the link's words, tools/guide/split.py). One table, so every link the guide writes has a place to go.
enum AppPlace {
  home,
  ask,
  maps,
  regions,
  drawArea,
  library,
  addToLibrary,
  notebooks,
  placesNotebook,
  settings,
  assistantSettings,
  mapsSettings,
  weatherSettings,
  notifications,
  storage,
  sharing,
  appearance,
  credits,
  models,
}

/// `cache://<path>`: the path, without a leading or trailing slash.
const Map<String, AppPlace> kAppLinks = {
  'home': AppPlace.home,
  'ask': AppPlace.ask,
  'maps': AppPlace.maps,
  'maps/regions': AppPlace.regions,
  'maps/draw': AppPlace.drawArea,
  'library': AppPlace.library,
  'library/add': AppPlace.addToLibrary,
  'notebooks': AppPlace.notebooks,
  'notebooks/places': AppPlace.placesNotebook,
  'settings': AppPlace.settings,
  'settings/assistant': AppPlace.assistantSettings,
  'settings/maps': AppPlace.mapsSettings,
  'settings/weather': AppPlace.weatherSettings,
  'settings/notifications': AppPlace.notifications,
  'settings/storage': AppPlace.storage,
  'settings/sharing': AppPlace.sharing,
  'settings/appearance': AppPlace.appearance,
  'settings/credits': AppPlace.credits,
  'settings/models': AppPlace.models,
};

/// Said for a link to a place this version does not have.
const String kUnknownAppLink = "This part of Cache isn't in this version";

/// The place a `cache://` link goes to, or null (not an app link, or one this version does not know).
AppPlace? appPlaceOf(String href) {
  final u = Uri.tryParse(href);
  if (u == null || u.scheme != 'cache') return null;
  final path = [u.host, ...u.pathSegments].where((s) => s.isNotEmpty).join('/');
  return kAppLinks[path];
}

bool isAppLink(String href) => href.startsWith('cache://');

/// Opens [place]; set by the app's shell (null in a test that does not need it).
void Function(AppPlace place)? openAppPlace;

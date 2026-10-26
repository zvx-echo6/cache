import 'dart:convert';
import 'dart:io';

import 'package:cache/weather/catalogue_store.dart';
import 'package:cache/weather/live_core.dart';
import 'package:cache_search/cache_search.dart';

/// A tiny definition. The app reads only its words; the core (a fake here) is what parses the rest.
String miniDefinition(String id, {String? title, String provider = 'Provider', int refresh = 15, String? keyAlias, String description = 'what it gives'}) =>
    jsonEncode({
      'format': 2,
      'id': id,
      'title': title ?? id,
      'provider': provider,
      'description': description,
      'attribution': 'Data by $provider',
      'refresh_minutes': refresh,
      if (keyAlias != null) 'api_key': {'alias': keyAlias, 'required': true},
      'request': {'url': 'https://example.org/$id?lat={lat}&lon={lon}'},
      'items': [],
    });

Map<String, dynamic> entry(
  String id,
  String category,
  String title, {
  String provider = 'Provider',
  String coverage = 'US',
  String? keyAlias,
  String? docs,
  String? path,
  int refresh = 15,
}) => {
  'id': id,
  'title': title,
  'description': 'what $title gives',
  'category': category,
  'provider': provider,
  'coverage': coverage,
  'needs_key': keyAlias != null,
  'key_alias': ?keyAlias,
  'default_on': keyAlias == null,
  'path': path ?? '$category/$id.json',
  'attribution': 'Data by $provider',
  'license': 'Public domain',
  'refresh': refresh,
  'docs': ?docs,
};

/// The files of a catalogue, by path relative to its base address: catalogue.json and one definition per connector.
Map<String, String> buildCatalogue({
  String id = 'cache-connectors',
  String title = 'Cache connectors',
  String base = 'https://cache.echo6.co/connectors/',
  int format = 1,
  required List<Map<String, dynamic>> connectors,
  Map<String, String> definitions = const {},
  String updated = '2026-10-26',
}) {
  final files = <String, String>{
    'catalogue.json': jsonEncode({
      'format': format,
      'id': id,
      'title': title,
      'maintainer': 'Cache project',
      'homepage': 'https://github.com/zvx-echo6/cache-packs/tree/main/connectors',
      'base_url': base,
      'updated': updated,
      'connectors': connectors,
    }),
  };
  for (final c in connectors) {
    final p = c['path'] as String;
    if (p.startsWith('https://') || p.startsWith('http://')) continue;
    files[p] = definitions[c['id']] ??
        miniDefinition(c['id'] as String, title: c['title'] as String, provider: c['provider'] as String, keyAlias: c['key_alias'] as String?, refresh: (c['refresh'] as int?) ?? 15);
  }
  return files;
}

/// The catalogue of the main tests: the sources the Weather and alerts page switches between, one that needs a key, and others.
Map<String, String> standardCatalogue() => buildCatalogue(connectors: [
  entry('nws-alerts-point', 'alerts', 'Weather alerts (NWS, by point)', provider: 'NWS'),
  entry('openmeteo-forecast', 'weather', 'Weather forecast (Open-Meteo)', provider: 'Open-Meteo', coverage: 'worldwide', refresh: 180),
  entry('wfigs-incidents-near', 'fire', 'Wildfires near the place (WFIGS)', provider: 'NIFC WFIGS', refresh: 30),
  entry('wfigs-perimeters-near', 'fire', 'Wildfire perimeters near the place (WFIGS)', provider: 'NIFC WFIGS', refresh: 30),
  entry('usgs-quakes-near', 'earthquakes', 'Earthquakes near the place (USGS)', provider: 'USGS', coverage: 'worldwide'),
  entry('nwps-gauges-near', 'hydrology', 'River gauges near the place (NWPS)', provider: 'NOAA NWPS', refresh: 30),
  entry('avalanche-forecast-zones', 'avalanche', 'Avalanche danger near the place (avalanche.org)', provider: 'avalanche.org', refresh: 60),
  entry('swpc-kp', 'space-weather', 'Space weather: Kp index', provider: 'NOAA SWPC', coverage: 'worldwide'),
  entry('firms-viirs-near', 'fire', 'Satellite fire detections near the place (NASA FIRMS)', provider: 'NASA FIRMS', coverage: 'worldwide', keyAlias: 'firms', docs: 'https://firms.modaps.eosdis.nasa.gov/api/area/'),
  entry('idaho511-events', 'roads', 'Road conditions (Idaho 511)', provider: 'Idaho 511', coverage: 'Idaho', keyAlias: 'idaho511', docs: 'https://511.idaho.gov/developers'),
  entry('idaho511-winter-roads', 'roads', 'Winter road conditions (Idaho 511)', provider: 'Idaho 511', coverage: 'Idaho', keyAlias: 'idaho511'),
]);

/// The built-in definitions (what the app ships): weather and alerts.
List<String> builtInDefinitions() => [
  miniDefinition('alerts', title: 'Emergency alerts', provider: 'NWS', refresh: 15),
  miniDefinition('weather', title: 'Weather forecast', provider: 'Open-Meteo', refresh: 180),
];

/// A web server in memory: addresses to files, a list of what was asked, and a connection that can be down.
class FakeWeb {
  final Map<String, List<int>> files = {};
  final List<Uri> requested = [];
  bool offline = false;

  /// Serves [catalogue] (see [buildCatalogue]) under [base].
  void serve(String base, Map<String, String> catalogue) {
    for (final e in catalogue.entries) {
      files['$base${e.key}'] = utf8.encode(e.value);
    }
  }

  Future<List<int>> fetch(Uri u) async {
    requested.add(u);
    if (offline) throw const NetworkProblem("Couldn't reach the server.");
    final b = files[u.toString()];
    if (b == null) throw NetworkProblem('${u.host} answered with an error (HTTP 404).');
    return b;
  }
}

/// The search core's live part, in memory. It registers whatever definition files are in the folder (as the real core does), refuses
/// the ids in [invalid], and records every call. [keys] is what the core holds: the app never reads a key back from it.
class FakeLiveCore implements LiveCore {
  FakeLiveCore(this.liveDir);

  final Directory liveDir;
  final List<Map<String, dynamic>?> policies = [];
  final Map<String, String?> keys = {};
  final List<Map<String, dynamic>> fetches = [];
  final List<Map<String, dynamic>> previews = [];
  final List<String> checked = [];
  final Set<String> invalid = {};
  final Map<String, CacheSearchException> fetchErrors = {};
  final Map<String, Map<String, dynamic>> stored = {};
  CacheSearchException? previewError;
  Map<String, dynamic> previewResult = {'valid': true, 'item_count': 1};
  List<SavedPlaceRecord> saved = [];
  bool fetchedNew = true;

  @override
  Future<Map<String, dynamic>> sources() async {
    final out = <Map<String, dynamic>>[];
    if (liveDir.existsSync()) {
      for (final f in liveDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        out.add({'id': j['id'], 'title': j['title'], 'provider': j['provider'], 'refresh_minutes': j['refresh_minutes']});
      }
    }
    return {'sources': out, 'errors': []};
  }

  @override
  Future<Map<String, dynamic>> fetch(Map<String, dynamic> request) async {
    fetches.add(request);
    final e = fetchErrors[request['source']];
    if (e != null) throw e;
    return {'fetched': fetchedNew};
  }

  @override
  Future<Map<String, dynamic>> get(Map<String, dynamic> request) async {
    final s = stored['${request['source']}'];
    if (s == null) throw const CacheSearchException('not_found', 'nothing downloaded');
    return s;
  }

  @override
  Future<void> setFetchPolicy(Map<String, dynamic>? policy) async => policies.add(policy);

  @override
  Future<void> setKey(String sourceId, String? key) async => keys[sourceId] = key;

  @override
  Future<void> check(String definitionText) async {
    checked.add(definitionText);
    final Object? j;
    try {
      j = jsonDecode(definitionText);
    } catch (_) {
      throw const CacheSearchException('bad_json', 'definition: not JSON');
    }
    if (j is Map && invalid.contains(j['id'])) {
      throw const CacheSearchException('bad_json', 'items[0].label: missing the field "path"');
    }
  }

  @override
  Future<Map<String, dynamic>> preview(Map<String, dynamic> request) async {
    previews.add(request);
    final e = previewError;
    if (e != null) throw e;
    return previewResult;
  }

  @override
  Future<List<SavedPlaceRecord>> savedPlaces() async => saved;

  /// Everything the core was told or asked, as text: for the test that no key shows up in anything.
  String everythingSeen() => [policies, fetches, checked, ...previews.map((p) => {...p, 'api_key': null})].map((e) => jsonEncode(e)).join('\n');
}

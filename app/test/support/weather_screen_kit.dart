import 'dart:convert';

import 'package:cache/actions/setup_status.dart' show setupAge;
import 'package:cache/settings/data_policy.dart' show ConnectionKind;
import 'package:cache_search/cache_search.dart' show SavedPlaceRecord;
import 'package:flutter_test/flutter_test.dart';

import 'settings_rig.dart';
import 'weather_fakes.dart';

// Sample data for the Weather screen's tests and review pictures: a source list with the published titles and credits, and what
// the core would have stored for a place. Every place, office and event in it is made up.

/// The key the core stores "Where I am" under at the rig's position ([SettingsRig.here]).
const String kHereKey = 'at:42.54,-113.79';

/// The sources of the sample list: id, category, title, provider, credit, license and (when it needs one) the key's name. Titles,
/// credits and licenses are the published list's own words (data.cached.info/connectors, list of 2026-11-03).
const List<(String, String, String, String, String, String, String?)> _sources = [
  ('openmeteo-forecast', 'weather', 'Weather forecast (Open-Meteo)', 'Open-Meteo', 'Weather data by Open-Meteo.com (CC BY 4.0)', 'CC BY 4.0 (free API: non-commercial use)', null),
  ('nws-forecast-point', 'weather', 'Weather forecast (NWS, by point)', 'NWS', 'Forecasts from the US National Weather Service (weather.gov)', 'US Government work, public domain', null),
  ('nws-alerts-point', 'alerts', 'Weather alerts (NWS, by point)', 'NWS', 'Alerts from the US National Weather Service (weather.gov)', 'US Government work, public domain', null),
  (
    'ipaws-alerts-near',
    'alerts',
    'Emergency alerts',
    'FEMA IPAWS',
    "Alerts from the issuing officials through FEMA's Integrated Public Alert and Warning System (IPAWS); county lookup from the US National Weather Service (weather.gov)",
    "Public alert messages of the issuing US officials, distributed by FEMA's public IPAWS-OPEN EAS feed (no key or account)",
    null,
  ),
  (
    'wfigs-incidents-near',
    'fire',
    'Wildfires near the place (WFIGS)',
    'NIFC WFIGS',
    'Wildfire incidents from the National Interagency Fire Center WFIGS (data-nifc.opendata.arcgis.com), public domain',
    'Public domain (NIFC open data)',
    null,
  ),
  (
    'wfigs-perimeters-near',
    'fire',
    'Wildfire perimeters near the place (WFIGS)',
    'NIFC WFIGS',
    'Wildfire perimeters from the National Interagency Fire Center WFIGS (data-nifc.opendata.arcgis.com), public domain',
    'Public domain (NIFC open data)',
    null,
  ),
  (
    'firms-viirs-near',
    'fire',
    'Satellite fire detections near the place (NASA FIRMS)',
    'NASA FIRMS',
    'Active fire data from NASA LANCE / FIRMS (firms.modaps.eosdis.nasa.gov), VIIRS; a detection is a hot spot seen from orbit, not a confirmed fire',
    'NASA open data; the FIRMS API needs a free MAP_KEY',
    'firms',
  ),
  ('usgs-quakes-near', 'earthquakes', 'Earthquakes near the place (USGS)', 'USGS', 'Earthquake data from the US Geological Survey (earthquake.usgs.gov), public domain', 'US Government work, public domain', null),
];

/// The sample source list, as the files of a catalogue (see [buildCatalogue]).
Map<String, String> screenCatalogue() {
  final connectors = <Map<String, dynamic>>[];
  final definitions = <String, String>{};
  for (final (id, category, title, provider, credit, license, key) in _sources) {
    connectors.add({...entry(id, category, title, provider: provider, keyAlias: key), 'attribution': credit, 'license': license});
    final def = jsonDecode(miniDefinition(id, title: title, provider: provider, keyAlias: key)) as Map<String, dynamic>;
    definitions[id] = jsonEncode({...def, 'attribution': credit});
  }
  return buildCatalogue(connectors: connectors, definitions: definitions);
}

/// Makes [screenCatalogue] the rig's source list and switches the sources [on] on (by id).
Future<void> useScreenSources(WidgetTester tester, SettingsRig r, Iterable<String> on) async {
  r.web.files.clear();
  r.web.serve('https://data.cached.info/connectors/', screenCatalogue());
  await tester.runAsync(() async {
    await r.weather.refreshCatalogues();
    await r.weather.setSourcesOn([for (final id in on) r.weather.sourceById(id)!], true);
  });
}

const List<String> _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-11-11".
String dateOf(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// "Wed Nov 11", as the forecast source labels a day.
String dayLabel(DateTime d) => '${_weekdays[d.weekday - 1]} ${_months[d.month - 1]} ${d.day}';

/// "2026-11-12 21:00", as an alert's "Expires" is written (the place's own clock).
String expiresAt(DateTime t) => '${dateOf(t)} ${_two(t.hour)}:${_two(t.minute)}';

/// What the core answers for a source: [items] downloaded at [fetched], asked at [now]. Times carry no zone, so the device's clock
/// is the place's clock, whatever zone the tests run in.
Map<String, dynamic> storedAnswer(DateTime now, DateTime fetched, List<Map<String, dynamic>> items, {bool expired = false, String? error}) => {
  'fetched_at': fetched.toIso8601String(),
  'age': setupAge(now.difference(fetched)),
  'expired': expired,
  'items': items,
  'last_error': ?(error == null ? null : {'code': 'fetch_failed', 'message': error, 'at': now.toIso8601String()}),
};

/// The forecast's "Now", taken at [taken].
Map<String, dynamic> nowItem(DateTime taken, {required int temperature, required int feels, required String wind, required String conditions}) => {
  'address': 'live:openmeteo-forecast/x/now',
  'label': 'Now',
  'time': taken.toIso8601String(),
  'fields': {'Temperature': '$temperature °F', 'Feels like': '$feels °F', 'Wind': wind, 'Conditions': conditions},
};

/// One day of the forecast, with the values in the order the source lists them.
Map<String, dynamic> dayItem(DateTime d, String conditions, int high, int low, int rain, {String precipitation = '0.0 in over 0 h', String snow = '0.0 in', int windMax = 9}) => {
  'address': 'live:openmeteo-forecast/x/${dateOf(d)}',
  'label': dayLabel(d),
  'time': dateOf(d),
  'fields': {
    'Daytime high': '$high °F',
    'Low (early morning)': '$low °F',
    'Chance of rain': '$rain%',
    'Precipitation': precipitation,
    'Snow': snow,
    'Wind max': '$windMax mph',
    'Conditions': conditions,
  },
};

/// The weather of sixteen made-up days: conditions, high, low, chance of rain.
const List<(String, int, int, int)> _sixteen = [
  ('partly cloudy', 52, 31, 10),
  ('light rain', 49, 34, 60),
  ('light snow', 34, 21, 70),
  ('overcast', 36, 19, 20),
  ('mainly clear', 41, 22, 5),
  ('clear sky', 45, 24, 0),
  ('partly cloudy', 47, 27, 10),
  ('light rain', 46, 30, 45),
  ('overcast', 43, 28, 25),
  ('fog', 40, 26, 15),
  ('mainly clear', 44, 25, 5),
  ('clear sky', 48, 27, 0),
  ('thunderstorm', 51, 33, 80),
  ('rain showers', 47, 31, 65),
  ('partly cloudy', 45, 29, 20),
  ('clear sky', 46, 26, 0),
];

/// Sixteen days from [first] ([skip] of them left out at the start, as when days have passed). [today] is the first day's
/// conditions, high, low and chance of rain, in place of the table's.
List<Map<String, dynamic>> sixteenDays(DateTime first, {int skip = 0, (String, int, int, int)? today}) {
  final out = <Map<String, dynamic>>[];
  for (var n = skip; n < _sixteen.length; n++) {
    final (conditions, high, low, rain) = (n == 0 ? today : null) ?? _sixteen[n];
    out.add(dayItem(
      DateTime(first.year, first.month, first.day + n),
      conditions,
      high,
      low,
      rain,
      precipitation: rain >= 45 ? '0.1 in over 5 h' : '0.0 in over 0 h',
      snow: conditions.contains('snow') ? '1.2 in' : '0.0 in',
      windMax: 9 + n,
    ));
  }
  return out;
}

/// A weather alert as the Weather Service source lists it.
Map<String, dynamic> nwsAlert(String id, String event, String? severity, DateTime sent, DateTime expires, String area) => {
  'address': 'live:nws-alerts-point/x/urn:oid:2.49.0.1.840.0.$id.001.1',
  'label': event,
  'time': sent.toIso8601String(),
  'fields': {
    'Severity': ?severity,
    'Urgency': 'expected',
    'Area': area,
    'Distance': 'inside the area',
    'Expires': expiresAt(expires),
    'Headline': '$event in effect',
    'Instructions': 'Follow the advice of local officials.',
  },
  'distances': {
    'Distance': {'km': 0.0, 'inside': true},
  },
};

/// An emergency alert as the FEMA IPAWS source lists it: its label is the headline, its "Event" the kind.
Map<String, dynamic> ipawsAlert(String id, String headline, String event, String severity, DateTime sent, DateTime expires, {required String by, required String area}) => {
  'address': 'live:ipaws-alerts-near/x/$id',
  'label': headline,
  'time': sent.toIso8601String(),
  'fields': {'Event': event, 'Severity': severity, 'Issued by': by, 'Area': area, 'Expires': expiresAt(expires), 'Instructions': 'Leave now by the marked routes.'},
};

/// A named fire as the incident source lists it, [miles] from the place ([from] is how the source words it: "6.2 mi NE").
Map<String, dynamic> fireItem(String id, String name, double miles, String from, {String size = '266 acres', String contained = '60%', String source = 'wfigs-incidents-near'}) => {
  'address': 'live:$source/x/$id',
  'label': source == 'wfigs-perimeters-near' ? '$name fire perimeter' : '$name fire',
  'fields': source == 'wfigs-perimeters-near'
      ? {'Distance to fire edge': from, 'Mapped size': size, 'Contained': contained}
      : {'Size': size, 'Contained': contained, 'From the place': from, 'County': 'Tamber'},
  'distances': {
    (source == 'wfigs-perimeters-near' ? 'Distance to fire edge' : 'From the place'): {'km': miles * 1.609344, 'inside': miles == 0},
  },
};

/// A satellite detection: every one has the same label.
Map<String, dynamic> detectionItem(int n, double miles, String from) => {
  'address': 'live:firms-viirs-near/x/d$n',
  'label': 'Satellite fire detection (high confidence)',
  'fields': {'From the place': from, 'Detected': '3:${_two(10 + n)} AM', 'Fire radiative power': '${12 + n} MW'},
  'distances': {
    'From the place': {'km': miles * 1.609344, 'inside': false},
  },
};

/// An earthquake as the USGS source lists it.
Map<String, dynamic> quakeItem(String id, String title, String magnitude, String when, double miles, String from) => {
  'address': 'live:usgs-quakes-near/x/$id',
  'label': title,
  'fields': {'Magnitude': magnitude, 'When': when, 'From the place': from, 'Depth': '6.2 mi'},
  'distances': {
    'From the place': {'km': miles * 1.609344, 'inside': false},
  },
};

// ---- scenes: what the screen is shown with, for the tests and the pictures ------------------------------------------------

/// The sources most people have on: the forecast, weather and emergency alerts, and wildfires with their perimeters.
const List<String> kUsualSources = ['openmeteo-forecast', 'nws-alerts-point', 'ipaws-alerts-near', 'wfigs-incidents-near', 'wfigs-perimeters-near'];

/// The made-up Wednesday the scenes happen on (2026-11-11), at [hour]:[minute].
DateTime wednesday(int hour, int minute) => DateTime(2026, 11, 11, hour, minute);

/// Stores [answer] as what the core holds for [source]: for every place, or for the one place stored under [placeKey].
void store(SettingsRig r, String source, Map<String, dynamic> answer, {String? placeKey}) {
  if (placeKey == null) {
    r.liveCore.stored[source] = answer;
  } else {
    r.liveCore.storedAt['$source $placeKey'] = answer;
  }
}

/// An update at the rig's clock, then the clock moved on to [shown] (when the screen is looked at).
Future<void> updatedThenShownAt(WidgetTester tester, SettingsRig r, DateTime shown) async {
  await tester.runAsync(() => r.weather.updateNow());
  r.clock = shown;
}

/// A quiet Wednesday at "Where I am": 2:26 PM, updated at 2:14 PM, nothing in force.
Future<void> sceneQuietDay(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(14, 14), shown = wednesday(14, 26);
  r.clock = updated;
  await useScreenSources(tester, r, kUsualSources);
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, [
    nowItem(updated, temperature: 45, feels: 41, wind: '8 mph NW, gusts 15 mph', conditions: 'partly cloudy'),
    ...sixteenDays(updated),
  ]));
  for (final id in kUsualSources.skip(1)) {
    store(r, id, storedAnswer(shown, updated, const []));
  }
  await updatedThenShownAt(tester, r, shown);
}

/// What is in force on the serious Wednesday, as each source lists it at a place.
Map<String, List<Map<String, dynamic>>> seriousItems(DateTime updated) {
  final thursday = DateTime(updated.year, updated.month, updated.day + 1);
  DateTime at(DateTime day, int hour) => DateTime(day.year, day.month, day.day, hour);
  final sent = updated.subtract(const Duration(minutes: 34));
  return {
    'nws-alerts-point': [
      nwsAlert('rf1', 'Red Flag Warning', 'severe', sent, at(thursday, 21), 'Tamber County; Alder Valley'),
      nwsAlert('wa1', 'Wind Advisory', 'moderate', sent, at(updated, 23), 'Tamber County'),
    ],
    'ipaws-alerts-near': [
      ipawsAlert('ev1', 'Evacuation order for the Tamber Flat area', 'Evacuation Immediate', 'extreme', sent, at(thursday, 6), by: 'Tamber County Sheriff', area: 'Tamber Flat'),
    ],
    'wfigs-incidents-near': [
      fireItem('f1', 'East Fork', 31, '31 mi N'),
      fireItem('f2', 'Tamber Flat', 6.2, '6.2 mi NE', size: '1,240 acres', contained: '10%'),
    ],
    'wfigs-perimeters-near': [
      fireItem('p2', 'Tamber Flat', 5.8, '5.8 mi NE', size: '1,180 acres', contained: '10%', source: 'wfigs-perimeters-near'),
    ],
    'usgs-quakes-near': [
      quakeItem('q1', 'M 2.1 - 14 km N of Wrenhollow', '2.1', 'today 9:14 AM', 38, '38 mi NW'),
      quakeItem('q2', 'M 2.4 - 30 km E of Wrenhollow', '2.4', 'yesterday 4:02 PM', 51, '51 mi N'),
    ],
  };
}

/// A serious Wednesday at "Where I am": 3:26 PM, updated at 3:14 PM. An evacuation order, a warning and a fire within 10 miles;
/// an advisory, a far fire, and a kind the app does not rank (earthquakes).
Future<void> sceneSeriousDay(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(15, 14), shown = wednesday(15, 26);
  r.clock = updated;
  await useScreenSources(tester, r, [...kUsualSources, 'usgs-quakes-near']);
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, [
    nowItem(updated, temperature: 58, feels: 51, wind: '24 mph W, gusts 41 mph', conditions: 'mainly clear'),
    ...sixteenDays(updated, today: ('mainly clear', 61, 38, 0)),
  ]));
  for (final e in seriousItems(updated).entries) {
    store(r, e.key, storedAnswer(shown, updated, e.value));
  }
  await updatedThenShownAt(tester, r, shown);
}

/// The rig's connection goes away.
Future<void> goOffline(WidgetTester tester, SettingsRig r) async {
  await tester.runAsync(() async {
    r.probe.change(ConnectionKind.none);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

/// No connection since Wednesday 2:14 PM, looked at on Friday 2:30 PM: the reading has ended, the forecast for the days that
/// remain is stored, and the last check of alerts and fires is too old to speak for now. One fire was known then.
Future<void> sceneOfflineDays(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(14, 14), shown = DateTime(2026, 11, 13, 14, 30);
  r.clock = updated;
  await useScreenSources(tester, r, kUsualSources);
  // as the core answers on Friday: what has ended is left out, and what is past its time is flagged
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, sixteenDays(updated, skip: 2)));
  for (final id in kUsualSources.skip(1)) {
    store(r, id, storedAnswer(shown, updated, id == 'wfigs-incidents-near' ? [fireItem('f1', 'East Fork', 31, '31 mi N')] : const [], expired: true));
  }
  await updatedThenShownAt(tester, r, shown);
  await goOffline(tester, r);
}

/// The serious Wednesday with three more watched places: Cabin (an advisory), Trailhead (nothing in force) and Lake house
/// (nothing downloaded yet).
Future<void> sceneSeveralPlaces(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(15, 14), shown = wednesday(15, 26);
  r.clock = updated;
  await useScreenSources(tester, r, [...kUsualSources, 'usgs-quakes-near']);
  r.liveCore.saved = const [
    SavedPlaceRecord(key: 'cabin', name: 'Cabin', lat: 43.10, lon: -114.20),
    SavedPlaceRecord(key: 'trailhead', name: 'Trailhead', lat: 43.60, lon: -114.90),
    SavedPlaceRecord(key: 'lake-house', name: 'Lake house', lat: 44.10, lon: -115.40),
  ];
  for (final s in r.liveCore.saved) {
    r.settings.setWatched('place:${s.key}', true);
  }
  // where the phone is: the serious day
  final here = [
    nowItem(updated, temperature: 58, feels: 51, wind: '24 mph W, gusts 41 mph', conditions: 'mainly clear'),
    ...sixteenDays(updated, today: ('mainly clear', 61, 38, 0)),
  ];
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, here), placeKey: kHereKey);
  for (final e in seriousItems(updated).entries) {
    store(r, e.key, storedAnswer(shown, updated, e.value), placeKey: kHereKey);
  }
  // Cabin: overcast, one advisory
  final cabin = [
    nowItem(updated, temperature: 49, feels: 44, wind: '18 mph W, gusts 30 mph', conditions: 'overcast'),
    ...sixteenDays(updated, today: ('overcast', 52, 35, 20)),
  ];
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, cabin), placeKey: 'cabin');
  // Trailhead: snow, nothing in force
  final trailhead = [
    nowItem(updated, temperature: 31, feels: 24, wind: '9 mph N, gusts 14 mph', conditions: 'light snow'),
    ...sixteenDays(updated, today: ('light snow', 33, 19, 70)),
  ];
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, trailhead), placeKey: 'trailhead');
  for (final id in [...kUsualSources.skip(1), 'usgs-quakes-near']) {
    final advisory = id == 'nws-alerts-point'
        ? [nwsAlert('wa2', 'Wind Advisory', 'moderate', updated.subtract(const Duration(minutes: 34)), DateTime(updated.year, updated.month, updated.day, 23), 'Harrow County')]
        : const <Map<String, dynamic>>[];
    store(r, id, storedAnswer(shown, updated, advisory), placeKey: 'cabin');
    store(r, id, storedAnswer(shown, updated, const []), placeKey: 'trailhead');
  }
  await updatedThenShownAt(tester, r, shown);
}

/// Wednesday 3:26 PM with satellite detections on (a key saved) and five fires far away: the detections share one name and
/// their nearest is within 10 miles; of the named fires the nearest three are listed and two wait behind "2 more fires".
Future<void> sceneManyFires(WidgetTester tester, SettingsRig r) async {
  final updated = wednesday(15, 14), shown = wednesday(15, 26);
  r.clock = updated;
  await useScreenSources(tester, r, kUsualSources);
  final detections = r.weather.sourceById('firms-viirs-near')!;
  await tester.runAsync(() => r.weather.saveKey(detections, 'made-up-key-for-a-test'));
  store(r, 'openmeteo-forecast', storedAnswer(shown, updated, [
    nowItem(updated, temperature: 71, feels: 69, wind: '14 mph SW, gusts 22 mph', conditions: 'clear sky'),
    ...sixteenDays(updated, today: ('clear sky', 74, 48, 0)),
  ]));
  for (final id in ['nws-alerts-point', 'ipaws-alerts-near', 'wfigs-perimeters-near']) {
    store(r, id, storedAnswer(shown, updated, const []));
  }
  store(r, 'wfigs-incidents-near', storedAnswer(shown, updated, [
    fireItem('f1', 'Harrow', 95, '95 mi S', size: '8,410 acres', contained: '35%'),
    fireItem('f2', 'East Fork', 31, '31 mi N'),
    fireItem('f3', 'Wren', 60, '60 mi W', size: '120 acres', contained: '90%'),
    fireItem('f4', 'Quill', 20, '20 mi SE', size: '44 acres', contained: '0%'),
    fireItem('f5', 'Osprey Bend', 44, '44 mi E', size: '2,050 acres', contained: '15%'),
  ]));
  store(r, 'firms-viirs-near', storedAnswer(shown, updated, [detectionItem(1, 44, '44 mi W'), detectionItem(2, 8, '8 mi NE'), detectionItem(3, 41, '41 mi W')]));
  await updatedThenShownAt(tester, r, shown);
}

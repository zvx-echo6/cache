import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/elevation/elevation_profile.dart';
import 'package:cache/nav/elevation/route_elevation.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache_search/cache_search.dart';

import '../nav_fakes.dart';

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

class DriveNav extends NavState {
  DriveNav(FakeBackend b, LocationService l)
      : super(
          backend: b,
          location: l,
          speaker: FakeSpeaker(),
          positionSource: FakeNavPosition(),
          fmt: const Fmt(UnitSystem.imperial),
          searchDebounce: const Duration(milliseconds: 1),
          meaningDebounce: const Duration(milliseconds: 2),
        );

  void poke() => notifyListeners();
}

const driveDestination = MapPlace(id: 'place:test:fern', type: 'place', name: 'Fernwood Trailhead', kind: 'Park', address: '', lat: 42.5, lon: -113.5, distanceM: 24600, direction: 'E');
const driveStop = MapPlace(id: 'place:test:market', type: 'place', name: 'Corner Market', kind: 'Shop', address: '', lat: 42.5, lon: -113.65);

/// The made-up sample route of the drive screen's pictures and tests: east along 42.5N, 40 points, with these maneuvers (index:
/// type, words): 0 start, 1 left onto Alder Street, 2 right onto Birch Hollow Road, 3 the stop (only when [withStop]),
/// then a merge onto Route 9, an exit onto Quarry Lane, a left onto Fernwood Lane, and the arrival.
Map<String, dynamic> driveRouteJson({bool withStop = true, String id = 'drive1'}) {
  const n = 40;
  final pts = [for (var i = 0; i <= n; i++) GeoPoint(42.5, -113.8 + 0.3 * i / n)];
  final total = metersBetween(pts.first, pts.last);
  final steps = <(String, String, String?, int)>[
    ('start', 'Drive east on Millbrook Avenue.', 'Millbrook Avenue', 0),
    ('left', 'Turn left onto Alder Street.', 'Alder Street', 4),
    ('right', 'Turn right onto Birch Hollow Road.', 'Birch Hollow Road', 9),
    if (withStop) ('via', 'You have reached a stop.', null, 13),
    ('merge', 'Merge onto Route 9.', 'Route 9', 18),
    ('exit_right', 'Take the exit on the right onto Quarry Lane.', 'Quarry Lane', 26),
    ('left', 'Turn left onto Fernwood Lane.', 'Fernwood Lane', 32),
    ('destination', 'You have arrived at your destination.', null, 36),
  ];
  final maneuvers = <Map<String, dynamic>>[];
  for (var i = 0; i < steps.length; i++) {
    final b = steps[i].$4;
    final e = i + 1 < steps.length ? steps[i + 1].$4 : n;
    maneuvers.add({
      'index': i, 'kind': 'road', 'type': steps[i].$1, 'instruction': steps[i].$2, 'street_names': [if (steps[i].$3 != null) steps[i].$3],
      'distance_m': total * (e - b) / n, 'duration_s': (total * (e - b) / n / 20).round(), 'lat': pts[b].lat, 'lon': pts[b].lon,
      'begin_index': b, 'end_index': e, 'bearing_deg': 90, 'cardinal': 'E', 'travel': 'drive',
    });
  }
  return {
    'ok': true, 'route_id': id, 'mode': 'drive', 'land_access': 'pragmatic', 'routing': 'road',
    'from': {'id': null, 'name': 'Your location', 'lat': 42.5, 'lon': -113.8, 'snap_distance_m': 3},
    'via': <Object>[],
    'to': {'id': 'place:test:fern', 'name': 'Fernwood Trailhead', 'lat': 42.5, 'lon': -113.5, 'snap_distance_m': 5},
    'distance_m': total, 'duration_s': (total / 20).round(),
    'totals': {'distance_m': total, 'duration_s': (total / 20).round(), 'road_m': total, 'offroad_m': 0.0, 'ascent_m': 0, 'descent_m': 0},
    'geometry': encodePolyline6(pts), 'point_count': pts.length,
    'segments': [{'kind': 'road', 'travel': 'drive', 'start_index': 0, 'end_index': n, 'distance_m': total}],
    'maneuvers': maneuvers,
    'major_roads': [{'name': 'Route 9', 'distance_km': total / 1000}], 'warnings': <Object>[], 'alternatives': <Object>[],
  };
}

/// Progress on [route] with maneuver [next] [metersToNext] ahead (the one before it is the current one); [lanes] are on the next.
Map<String, dynamic> driveProgressJson(Map<String, dynamic> route, int next, double metersToNext, {List<Map<String, dynamic>> lanes = const [], int stopsReached = 0, bool arrived = false}) {
  final total = (route['distance_m'] as num).toDouble();
  final mans = (route['maneuvers'] as List).cast<Map<String, dynamic>>();
  double begin(int i) => (mans[i]['begin_index'] as int) / 40 * total;
  final along = begin(next) - metersToNext;
  Map<String, dynamic> view(int i, double d, {List<Map<String, dynamic>> lanes = const []}) {
    final m = mans[i];
    return {'index': i, 'kind': m['kind'], 'type': m['type'], 'instruction': m['instruction'], 'street_names': m['street_names'], 'travel': m['travel'], 'lat': m['lat'], 'lon': m['lon'], 'distance_m': d, 'length_m': m['distance_m'], 'cardinal': 'E', 'bearing_deg': 90, 'lanes': lanes};
  }

  final remaining = total - along;
  return {
    'route_id': route['route_id'], 'fix': 1,
    'matched': {'lat': 42.5, 'lon': -113.8 + 0.3 * (along / total), 'distance_along_m': along, 'offset_m': 0.0, 'segment': 1, 'route_bearing_deg': 90},
    'on_route': true, 'off_route': false, 'off_route_count': 0, 'arrived': arrived, 'stops_reached': stopsReached, 'progress': along / total,
    'remaining': {'distance_m': remaining, 'duration_s': (remaining / 20).round(), 'eta': '2026-11-12T19:02:00'},
    'total': {'distance_m': total, 'duration_s': route['duration_s']},
    'current': view(next - 1, 0),
    'next': view(next, metersToNext, lanes: lanes),
    'then': next + 1 < mans.length ? view(next + 1, begin(next + 1) - begin(next)) : null,
  };
}

/// A profile along the sample route (24.6 km): a gentle rise, a steep climb about two thirds of the way along, then down.
ElevationProfile driveProfile() {
  final d = <double>[], e = <double>[];
  for (var x = 0.0; x <= 24600; x += 40) {
    d.add(x);
    e.add(1200 + (x < 9000 ? x * 0.02 : x < 11000 ? 180 + (x - 9000) * 0.09 : x < 16000 ? 360 : 360 - (x - 16000) * 0.02));
  }
  return ElevationProfile.fromSamples(d, e, totalM: 24600);
}

/// A guiding navigation state over the sample route, to put a progress on.
class DriveRig {
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late DriveNav nav;
  late Map<String, dynamic> route;
  late RouteElevation elevation;

  Future<void> setUp() async {
    dir = Directory.systemTemp.createTempSync('drive');
    location = LocationService(source: _NoSource(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend();
    nav = DriveNav(backend, location);
    elevation = RouteElevation(loader: (r) async => driveProfile());
  }

  void tearDown() {
    nav.dispose();
    elevation.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  }

  /// Guidance has started on the sample route, [withStop] with a stop on it, and no position yet.
  Future<void> guide({bool withStop = true}) async {
    route = driveRouteJson(withStop: withStop);
    backend.onRoute = (to, m, from) async => MapRoute.fromJson(route);
    backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(driveProgressJson(route, 1, 400));
    await nav.openDirections(driveDestination);
    if (withStop) nav.stops = const [driveStop];
    await nav.start();
    nav.progress = null;
    elevation.request(nav.route);
  }

  /// The drive as it is when maneuver [next] is [metersToNext] ahead.
  void at(int next, double metersToNext, {List<Map<String, dynamic>> lanes = const [], int stopsReached = 0}) {
    nav.progress = MapProgress.fromJson(driveProgressJson(route, next, metersToNext, lanes: lanes, stopsReached: stopsReached));
    nav.poke();
  }
}

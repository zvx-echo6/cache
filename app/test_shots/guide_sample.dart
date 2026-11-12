// The sample place of the guide's pictures: Arches National Park, Utah. Every map view stays inside the park, north of the
// Colorado River, so no town, business, home or street address is in a picture. Public features of the park appear under their own
// names; the saved places are made up and have plain names.
//
// The coordinates were read from the app's own base map tiles (zoom 14, protomaps-planet-20261103): the position and the routes
// lie on the road and trail lines the map draws. The routes and the progress answer (test_shots/guide_data/drive_route.json,
// drive_progress.json, offroad_route.json) have the shapes of the core's cs_map_route and cs_map_progress answers, but they were
// made by hand along those lines, not recorded from the core; a recorded answer replaces the files as they are. The heights
// along each route (drive_elevation.json, offroad_elevation.json) were read from the elevation tiles the map's hillshade is drawn
// from, the way the app samples them; each file says where its heights came from.

import 'dart:convert';
import 'dart:io';

import 'package:cache/nav/elevation/elevation_profile.dart' show ElevationProfile;
import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace, MapProgress, MapRoute;

class GuideSample {
  GuideSample._(this.driveRoute, this.driveProgress, this.publicLands, this.driveElevation, this.offroadRoute, this.offroadElevation);

  factory GuideSample.load() {
    Map<String, dynamic> read(String name) => (jsonDecode(File('test_shots/guide_data/$name').readAsStringSync()) as Map).cast<String, dynamic>();
    return GuideSample._(
      read('drive_route.json'),
      read('drive_progress.json'),
      read('public_lands_layer.json'),
      read('drive_elevation.json'),
      read('offroad_route.json'),
      read('offroad_elevation.json'),
    );
  }

  /// The phone: on Main Park Road just north of the Windows Road turning, by Balanced Rock, heading north.
  static const GeoPoint here = GeoPoint(38.704392, -109.562911);
  static const double hereHeading = 14;

  /// The place the place card is of: a public feature of the park, at the end of its trail.
  static const MapPlace arch = MapPlace(
    id: 'place:osm:w11',
    type: 'place',
    name: 'Double Arch',
    kind: 'Arch',
    category: 'attraction',
    address: 'Arches National Park, UT',
    lat: 38.69181,
    lon: -109.54063,
    distanceM: 2400,
    direction: 'SE',
    hours: 'Open all day',
    summary: 'Two arches that stand on one footing, at the end of a short trail.',
    matched: 'name',
  );

  /// What a search for "arch" finds from [here]: arches of the park, nearest first (the distances are from [here]).
  static const List<MapPlace> arches = [
    arch,
    MapPlace(id: 'place:osm:n21', type: 'place', name: 'Delicate Arch', kind: 'Arch', category: 'attraction', address: 'Arches National Park, UT', lat: 38.74347, lon: -109.49932, distanceM: 7000, direction: 'NE', matched: 'name'),
    MapPlace(id: 'place:osm:n22', type: 'place', name: 'Landscape Arch', kind: 'Arch', category: 'attraction', address: 'Arches National Park, UT', lat: 38.7911, lon: -109.6067, distanceM: 10400, direction: 'N', matched: 'name'),
  ];

  /// A saved place (made up): where the drive ends, at the start of the Delicate Arch trail. Shaped as the Maps screen makes a
  /// notebook's place into a destination.
  static const MapPlace trailhead = MapPlace(id: 'notebook:trailhead', type: 'place', name: 'Trailhead', kind: 'Places', lat: 38.73562, lon: -109.52059);

  /// The drive from the phone to [trailhead]: east on Main Park Road, then left onto Delicate Arch Road. It comes from the
  /// north-west so that both of its ends are clear of the buttons and chips when the screen fits it into view.
  final Map<String, dynamic> driveRoute;

  /// Where the phone is on that drive in the guidance picture: 0.1 mi before the left turn, so the junction is in view.
  final Map<String, dynamic> driveProgress;

  /// The public lands layer as the published catalogue defines it (read 2026-11-11), so the layers sheet lists it and the style
  /// draws it as on a phone.
  final Map<String, dynamic> publicLands;

  /// The heights along the drive (see the file's own note).
  final Map<String, dynamic> driveElevation;

  /// The walk of the off-road picture: from the Windows parking along the Double Arch Trail to [arch], one stretch that follows a
  /// mapped trail. Its line is the trail's own line in the base map tiles.
  final Map<String, dynamic> offroadRoute;

  /// The heights along that trail.
  final Map<String, dynamic> offroadElevation;

  /// The spot pressed for the ring, with the drive in view (as the screen fits it: the whole width, in the strip under the
  /// position chip and the map's buttons and above the scale): open ground north of the turn, where the ring is clear of the
  /// position chip, the map's buttons and the scale.
  static const GeoPoint ringSpot = GeoPoint(38.73322, -109.53624);

  /// The three points measured, in the place card's view ([arch] in the middle, zoom 14): where the trail leaves the parking,
  /// the arch, and the end of the viewpoint trail west of the parking.
  static const List<GeoPoint> measured = [GeoPoint(38.68827, -109.53833), GeoPoint(38.69181, -109.54063), GeoPoint(38.68821, -109.54301)];
  static const double measureZoom = 14;

  String get publicLandsId => publicLands['id'] as String;

  MapRoute route() => MapRoute.fromJson(driveRoute);

  MapProgress progress() => MapProgress.fromJson(driveProgress);

  /// Where the drive starts (the phone, when directions are asked for) and the way the road heads there.
  GeoPoint get routeStart => route().points.first;
  double get routeStartHeading => (((driveRoute['maneuvers'] as List).first as Map)['bearing_deg'] as num).toDouble();

  /// The phone in the guidance picture, and its heading (along the road).
  GeoPoint get guidanceFix => progress().matched;
  double get guidanceHeading => progress().routeBearingDeg.toDouble();

  /// The route the core's answer stands for: the walk for the off-road modes, else the drive.
  Map<String, dynamic> routeFor(String mode) => mode.startsWith('offroad') ? offroadRoute : driveRoute;

  /// Where the walk starts (the phone, when off-road directions are asked for) and the way the trail heads there.
  GeoPoint get offroadStart => MapRoute.fromJson(offroadRoute).points.first;
  double get offroadStartHeading => (((offroadRoute['maneuvers'] as List).first as Map)['bearing_deg'] as num).toDouble();

  /// The elevation profile of [route] (the drive or the walk), from the heights read along it.
  ElevationProfile elevationOf(MapRoute route) {
    final e = route.routeId == offroadRoute['route_id'] ? offroadElevation : driveElevation;
    List<double> numbers(String key) => [for (final v in e[key] as List) (v as num).toDouble()];
    final dist = numbers('dist_m');
    return ElevationProfile.fromSamples(dist, numbers('height_m'), totalM: dist.last);
  }
}

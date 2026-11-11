// The sample place of the guide's Maps pictures: Arches National Park, Utah. Every view stays inside the park, north of the
// Colorado River, so no town, business, home or street address is in a picture. Public features of the park appear under their own
// names; the saved place is made up and has a plain name.
//
// The coordinates were read from the app's own base map tiles (zoom 14, protomaps-planet-20261103): the position and the route
// lie on the road lines the map draws. The route and its progress answer (test_shots/guide_data/drive_route.json,
// drive_progress.json) have the shapes of the core's cs_map_route and cs_map_progress answers, but they were traced by hand along
// those road lines, not recorded from the core; a recorded answer replaces the files as they are.

import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace, MapProgress, MapRoute;

class GuideSample {
  GuideSample._(this.driveRoute, this.driveProgress, this.publicLands);

  factory GuideSample.load() {
    Map<String, dynamic> read(String name) => (jsonDecode(File('test_shots/guide_data/$name').readAsStringSync()) as Map).cast<String, dynamic>();
    return GuideSample._(read('drive_route.json'), read('drive_progress.json'), read('public_lands_layer.json'));
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

  /// A saved place (made up): where the drive ends, at the start of the Delicate Arch trail. Shaped as the Maps screen makes a
  /// notebook's place into a destination.
  static const MapPlace trailhead = MapPlace(id: 'notebook:trailhead', type: 'place', name: 'Trailhead', kind: 'Places', lat: 38.73562, lon: -109.52059);

  /// The drive from the phone to [trailhead]: Main Park Road, then right onto Delicate Arch Road.
  final Map<String, dynamic> driveRoute;

  /// Where the phone is on that drive in the guidance picture: 0.4 mi before the right turn.
  final Map<String, dynamic> driveProgress;

  /// The public lands layer as the published catalogue defines it (read 2026-11-11), so the layers sheet lists it and the style
  /// draws it as on a phone.
  final Map<String, dynamic> publicLands;

  String get publicLandsId => publicLands['id'] as String;

  MapRoute route() => MapRoute.fromJson(driveRoute);

  MapProgress progress() => MapProgress.fromJson(driveProgress);

  /// Where the drive starts (the phone, when directions are asked for) and the way the road heads there.
  GeoPoint get routeStart => route().points.first;
  double get routeStartHeading => (((driveRoute['maneuvers'] as List).first as Map)['bearing_deg'] as num).toDouble();

  /// The phone in the guidance picture, and its heading (along the road).
  GeoPoint get guidanceFix => progress().matched;
  double get guidanceHeading => progress().routeBearingDeg.toDouble();
}

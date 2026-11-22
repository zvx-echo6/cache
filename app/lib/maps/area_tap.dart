import 'dart:math' as math;

import 'package:cache_search/cache_search.dart' show MapPlace;

import '../nav/units.dart';
import '../regions/area_lookup.dart';
import '../regions/region_catalogue.dart';

/// A tap on a town's label or on empty ground opens the card of the town or county there, and draws its outline (DESIGN.md, "The
/// outline" and "The cards"). Everything here is pure; the Maps screen asks [AreaSource] and shows the result.

/// The id of the place card of a catalogue region: `area:<region id>`.
const String kAreaPlacePrefix = 'area:';

/// The `matched` mark of an area's card.
const String kAreaMatched = 'area';

bool isAreaPlace(MapPlace p) => p.id.startsWith(kAreaPlacePrefix);

/// The facts an area's card shows beyond a place's own: they come from the region catalogue.
class AreaCardInfo {
  const AreaCardInfo({this.people, this.squareArea, this.largestTowns, required this.directions});

  /// "About 49,800 people".
  final String? people;

  /// "About 1,930 square miles" (a county).
  final String? squareArea;

  /// "Largest towns: Twin Falls, Kimberly, Buhl" (a county).
  final String? largestTowns;

  /// A town has Directions; a county does not.
  final bool directions;
}

/// What a tap opens: the card's place, its extra facts and the outline's geometry (null when the polygon is not on the phone: the card then
/// opens with the selection dot alone).
class AreaChoice {
  const AreaChoice({required this.place, required this.info, required this.region, this.geometry});

  final MapPlace place;
  final AreaCardInfo info;
  final RegionRecord region;
  final Map<String, dynamic>? geometry;

  bool get isTown => region.kind == 'locality';
}

/// The town if the point is in one, else the county; null for neither.
RegionRecord? areaOf(AreaHit? hit) => hit?.town ?? hit?.county;

/// The two-letter state of a record ("US-ID" -> "ID"), or the state's own name.
String stateShort(RegionRecord? r, AreaHit? hit) {
  final code = r?.regionCode ?? hit?.state?.regionCode;
  if (code != null && code.contains('-')) return code.split('-').last;
  return hit?.state?.name ?? '';
}

/// "City", "Town", "Village", or "City or town" when the catalogue does not say.
String townKindLabel(RegionRecord r) => switch (r.placeClass) {
      'city' => 'City',
      'town' => 'Town',
      'village' => 'Village',
      'hamlet' => 'Hamlet',
      _ => 'City or town',
    };

/// The card of a tapped area. [pack] is the places data's own record of the town (its summary and Wikipedia title, its point), when
/// the search found one; null when it has none.
AreaChoice areaChoice(AreaHit hit, {MapPlace? pack, Map<String, dynamic>? geometry, required Fmt fmt, List<RegionRecord> towns = const []}) {
  final town = hit.town;
  final r = town ?? hit.county!;
  final b = r.bbox;
  final lat = pack?.lat ?? (b == null ? 0.0 : (b[1] + b[3]) / 2);
  final lon = pack?.lon ?? (b == null ? 0.0 : (b[0] + b[2]) / 2);
  final people = areaPopulationLine(r);
  if (town != null) {
    final county = hit.county?.name;
    final st = stateShort(town, hit);
    final inLine = [if (county != null) county, if (st.isNotEmpty) st].join(', ');
    return AreaChoice(
      region: town,
      geometry: geometry,
      info: AreaCardInfo(people: people, directions: true),
      place: MapPlace(
        id: '$kAreaPlacePrefix${town.id}',
        type: 'place',
        name: town.name,
        kind: townKindLabel(town),
        address: inLine,
        lat: lat,
        lon: lon,
        summary: pack?.summary,
        wikipediaTitle: pack?.wikipediaTitle,
        wikidataId: pack?.wikidataId,
        matched: kAreaMatched,
      ),
    );
  }
  final state = hit.state?.name;
  return AreaChoice(
    region: r,
    geometry: geometry,
    info: AreaCardInfo(
      people: people,
      squareArea: areaSquareLine(r.areaKm2, fmt),
      largestTowns: towns.isEmpty ? null : 'Largest towns: ${towns.map((t) => t.name).join(', ')}',
      directions: false,
    ),
    place: MapPlace(
      id: '$kAreaPlacePrefix${r.id}',
      type: 'place',
      name: r.name,
      kind: state == null ? 'County' : 'County in $state',
      lat: lat,
      lon: lon,
      matched: kAreaMatched,
    ),
  );
}

/// "About 1,930 square miles" (or square kilometers, by the app's unit setting); null when the catalogue has no area.
String? areaSquareLine(double? km2, Fmt fmt) {
  if (km2 == null || km2 <= 0) return null;
  final imperial = fmt.units == UnitSystem.imperial;
  final v = imperial ? km2 * 0.386102 : km2;
  final n = _roundedTo(v);
  return 'About ${_grouped(n)} square ${imperial ? 'miles' : 'kilometers'}';
}

int _roundedTo(double v) {
  final step = v >= 1000 ? 10 : v >= 100 ? 10 : 1;
  return ((v / step).round() * step).toInt();
}

String _grouped(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// The GeoJSON the outline layers draw: one feature, or none.
Map<String, dynamic> areaOutlineGeoJson(Map<String, dynamic>? geometry) => {
      'type': 'FeatureCollection',
      'features': [
        if (geometry != null) {'type': 'Feature', 'properties': const <String, dynamic>{}, 'geometry': geometry},
      ],
    };

/// The box of a polygon geometry, [west, south, east, north]; null when it has no points.
List<double>? geometryBounds(Map<String, dynamic> g) {
  double w = double.infinity, s = double.infinity, e = -double.infinity, n = -double.infinity;
  void walk(Object? c) {
    if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
      final x = (c[0] as num).toDouble(), y = (c[1] as num).toDouble();
      w = math.min(w, x);
      e = math.max(e, x);
      s = math.min(s, y);
      n = math.max(n, y);
    } else if (c is List) {
      c.forEach(walk);
    }
  }

  walk(g['coordinates']);
  return w.isFinite ? [w, s, e, n] : null;
}

/// The zoom at which [b] ([west, south, east, north]) just fits a free rectangle of [width] x [height] points: where the outline's fill
/// starts to fade (the whole area is on screen there).
double fitZoomFor(List<double> b, double width, double height) {
  const tile = 512.0;
  double y(double lat) {
    final r = lat.clamp(-85.0, 85.0) * math.pi / 180;
    return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2;
  }

  final dx = math.max((b[2] - b[0]).abs() / 360, 1e-9);
  final dy = math.max((y(b[1]) - y(b[3])).abs(), 1e-9);
  final zx = math.log(width / (tile * dx)) / math.ln2;
  final zy = math.log(height / (tile * dy)) / math.ln2;
  return math.min(zx, zy).clamp(0.0, 20.0);
}

/// The fill's opacity: [fill] while the whole area is in view, gone [fade] zoom levels after it stopped fitting (zoomed inside, the
/// screen is not tinted with the border off screen).
List<Object> areaFillOpacity(double fitZoom, {double fill = 0.08, double fade = 1.5}) => [
      'interpolate',
      ['linear'],
      ['zoom'],
      fitZoom,
      fill,
      fitZoom + fade,
      0,
    ];

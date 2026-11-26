// A group marker (and, zoomed out, a saved-place pin) that sits on a city's or town's name is nudged to one side so the name and the
// icon are both readable and tappable. Only the drawn position moves; the true point stays for the fan's leader lines. This file is the
// screen-space maths with no map or widget in it; the screen computes on camera idle and writes the nudged points to the sources.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// Below this zoom the owner's saved-place pins also step aside off town names; at and above it they stay exactly in place.
const double kNudgePinsBelowZoom = 10;

/// Space kept between a nudged icon and the name's text box, in points.
const double kNudgePadding = 4;

/// The size of a place name's text in points, for its estimated box (the query gives the label's point and name, not its text box).
const double kTownNameFont = 14;

/// The layers of the names of cities and towns (Protomaps, OpenMapTiles).
const List<String> kTownNameLayerIds = ['places_locality', 'label_village', 'label_town', 'label_city', 'label_city_capital'];

/// A camera as the map screen knows it: where the camera's centre is on the screen, the centre's point, the zoom and the bearing. It
/// turns a point on the earth into a screen point (Web Mercator, 512 point tiles, the map's own) and back, with no platform call.
class NudgeCamera {
  const NudgeCamera({required this.centreScreen, required this.lat, required this.lon, required this.zoom, this.bearing = 0});

  final Offset centreScreen;
  final double lat;
  final double lon;
  final double zoom;

  /// Degrees clockwise from north that point up on the screen.
  final double bearing;

  double get _scale => 512 * math.pow(2, zoom).toDouble();

  Offset _plane(double la, double lo) {
    final s = math.sin(la * math.pi / 180).clamp(-0.9999, 0.9999);
    return Offset((lo + 180) / 360 * _scale, (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * _scale);
  }

  /// Where [la], [lo] are on the screen, in points.
  Offset project(double la, double lo) {
    final d = _plane(la, lo) - _plane(lat, lon);
    final b = bearing * math.pi / 180, c = math.cos(b), s = math.sin(b);
    return centreScreen + Offset(d.dx * c + d.dy * s, -d.dx * s + d.dy * c);
  }

  /// The point on the earth at screen point [p]: (lat, lon).
  (double, double) unproject(Offset p) {
    final v = p - centreScreen;
    final b = bearing * math.pi / 180, c = math.cos(b), s = math.sin(b);
    final d = Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
    final centre = _plane(lat, lon);
    final x = centre.dx + d.dx, y = centre.dy + d.dy;
    final lo = x / _scale * 360 - 180;
    final la = 180 / math.pi * (2 * math.atan(math.exp((0.5 - y / _scale) * 2 * math.pi)) - math.pi / 2);
    return (la, lo);
  }
}

/// The estimated text box of a place name drawn centred on [at]: [name]'s characters at [font] points.
Rect labelBox(String name, Offset at, {double font = kTownNameFont}) =>
    Rect.fromCenter(center: at, width: math.max(1, name.runes.length) * font * 0.58, height: font * 1.3);

/// How far each item must move (screen points) to clear every label box in [labels]. [items] are the items' extents by id (what the
/// item draws, or its tap target if that is bigger); an item that touches no label is not in the result. An overlapping item moves the
/// least that clears the label plus [padding]; where the distances are close it takes the side with more room in [viewport]. Items
/// never move into a label they were clear of, up to a few passes.
Map<String, Offset> nudgeOffLabels({
  required Map<String, Rect> items,
  required List<Rect> labels,
  required Rect viewport,
  double padding = kNudgePadding,
}) {
  final out = <String, Offset>{};
  if (labels.isEmpty) return out;
  final ids = items.keys.toList()..sort();
  for (final id in ids) {
    var r = items[id]!;
    var moved = Offset.zero;
    for (var pass = 0; pass < 4; pass++) {
      final hit = labels.where((l) => l.inflate(padding).overlaps(r)).firstOrNull;
      if (hit == null) break;
      final l = hit.inflate(padding);
      // The four ways out: (move, room on that side of the label).
      final cands = <(Offset, double)>[
        (Offset(l.left - r.right, 0), l.left - viewport.left),
        (Offset(l.right - r.left, 0), viewport.right - l.right),
        (Offset(0, l.top - r.bottom), l.top - viewport.top),
        (Offset(0, l.bottom - r.top), viewport.bottom - l.bottom),
      ];
      final fits = [for (final c in cands) if (viewport.contains(r.shift(c.$1).topLeft) && viewport.contains(r.shift(c.$1).bottomRight)) c];
      final use = fits.isEmpty ? cands : fits;
      // The least move wins; among moves nearly as short, the side with the most room.
      final least = use.map((c) => c.$1.distance).reduce(math.min);
      final near = [for (final c in use) if (c.$1.distance <= least * 1.25 + 4) c];
      final best = near.reduce((a, b) => b.$2 > a.$2 ? b : a);
      moved += best.$1;
      r = r.shift(best.$1);
    }
    if (moved != Offset.zero) out[id] = moved;
  }
  return out;
}

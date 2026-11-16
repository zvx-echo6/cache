import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// How far down the free map ([guidanceFreeMap]) the phone's position sits while guiding with the map turned to the heading, as
/// Google and Apple Maps do: low, so more of the road ahead is in view. The same on every screen.
const double kGuideDown = 0.72;

/// The room kept between the position's marker and a piece over the map's corner (the scale, the credits, the route mini map,
/// the map's buttons).
const double kGuideClear = 8;

/// What is laid out over the map while guiding, as measured from the screen's own layout, in the map's logical points (the
/// map's top left is 0,0):
/// - [top]: the lower edge of the band across the map's top (the turn banner on a phone); null when there is none.
/// - [bottom]: the upper edge of the band across its foot (the guidance bar on a phone); null when there is none.
/// - [left]: the right edge of the column on the left (from the side-by-side width the banner and the bar are there); null on
///   a phone.
/// - [tiles]: the pieces in the map's corners (the scale, the credits, the route mini map, the map's buttons). They do not move
///   the position; it is only kept from going under one of them ([guidanceAnchor]).
class GuideCovers {
  const GuideCovers({this.top, this.bottom, this.left, this.tiles = const []});

  final double? top;
  final double? bottom;
  final double? left;
  final List<Rect> tiles;
}

/// The free map while guiding: the [map] less the bands across its top and foot and the column on its left ([covers]), and
/// less the screen's [safe] area where nothing covers an edge. When the covers leave nothing, the whole map.
Rect guidanceFreeMap(Size map, GuideCovers covers, {EdgeInsets safe = EdgeInsets.zero}) {
  final whole = Offset.zero & map;
  if (map.isEmpty) return whole;
  final top = covers.top ?? safe.top;
  final bottom = covers.bottom ?? map.height - safe.bottom;
  final left = covers.left ?? safe.left;
  final right = map.width - safe.right;
  final free = Rect.fromLTRB(math.max(0, left), math.max(0, top), math.min(map.width, right), math.min(map.height, bottom));
  return free.width <= 0 || free.height <= 0 ? whole : free;
}

/// Where the position sits while guiding heading-up: centred across the [free] map and [kGuideDown] of the way down it. A marker
/// reaching [reach] points from the position is kept [kGuideClear] clear of the corner [tiles]: lifted above one at the foot (no
/// higher than the middle of the free map), and only when that is not enough, moved across, away from it.
Offset guidanceAnchor(Rect free, {List<Rect> tiles = const [], double reach = 0}) {
  if (free.isEmpty) return free.center;
  var x = free.center.dx;
  var y = free.top + free.height * kGuideDown;
  final highest = free.top + free.height / 2;
  final r = reach + kGuideClear;
  bool under(Rect t) => t.overlaps(Rect.fromCircle(center: Offset(x, y), radius: r));
  // Lifted above the pieces at the foot it would be under (each lift can bring it to another piece above that one).
  for (var i = 0; i <= tiles.length; i++) {
    final hit = tiles.where((t) => under(t) && t.bottom > y).toList();
    if (hit.isEmpty) break;
    y = math.max(highest, hit.map((t) => t.top - r).reduce(math.min));
    if (y <= highest) break;
  }
  // Still under one (a piece reaching above the middle): moved across, to the side of it with more room.
  for (final t in tiles) {
    if (!under(t)) continue;
    final toLeft = t.left - r, toRight = t.right + r;
    final roomLeft = toLeft - free.left, roomRight = free.right - toRight;
    x = roomLeft >= roomRight ? toLeft : toRight;
  }
  return Offset(x.clamp(free.left, free.right).toDouble(), y.clamp(free.top, free.bottom).toDouble());
}

/// Metres per logical pixel at [zoom] and [lat] (MapLibre draws the world 512 logical pixels wide at zoom 0, on every platform:
/// the map package and MapLibre turn logical pixels into the screen's own with the same pixel ratio as Flutter).
double metresPerPixel(double lat, double zoom) => 2 * math.pi * 6378137 * math.cos(lat * math.pi / 180) / (512 * math.pow(2, zoom));

/// The camera's centre that puts ([lat], [lon]) at [anchor] on a map of [map] size turned to [bearing] degrees at [zoom]. The
/// map must have no padding of its own (MapLibre's content insets): the screen sets them to none before it uses this.
(double, double) cameraCentreFor(double lat, double lon, {required double bearing, required double zoom, required Size map, required Offset anchor}) {
  final mpp = metresPerPixel(lat, zoom);
  final b = bearing * math.pi / 180;
  // The centre is up (along the bearing) and across (the bearing plus 90 degrees) from the position, in screen pixels.
  final up = (anchor.dy - map.height / 2) * mpp;
  final right = (map.width / 2 - anchor.dx) * mpp;
  final north = up * math.cos(b) - right * math.sin(b);
  final east = up * math.sin(b) + right * math.cos(b);
  return (lat + north / 111320, lon + east / (111320 * math.cos(lat * math.pi / 180)));
}

/// Where ([lat], [lon]) falls on a map of [map] size centred on ([centreLat], [centreLon]) turned to [bearing] at [zoom]: the
/// inverse of [cameraCentreFor], for the review pictures (the map itself is not drawn there) and the tests.
Offset screenPointFor(double lat, double lon, {required double centreLat, required double centreLon, required double bearing, required double zoom, required Size map}) {
  final mpp = metresPerPixel(lat, zoom);
  final b = bearing * math.pi / 180;
  final north = (centreLat - lat) * 111320;
  final east = (centreLon - lon) * 111320 * math.cos(lat * math.pi / 180);
  final up = north * math.cos(b) + east * math.sin(b);
  final right = -north * math.sin(b) + east * math.cos(b);
  return Offset(map.width / 2 - right / mpp, map.height / 2 + up / mpp);
}

/// Where the map shows the phone while guiding, and which way it turns the map: a position and a bearing in degrees.
typedef GuidePose = ({double lat, double lon, double bearing});

/// The pose [t] of the way from [a] to [b] (0 to 1), turning the short way round.
GuidePose lerpPose(GuidePose a, GuidePose b, double t) {
  final k = t.clamp(0.0, 1.0);
  final turn = ((b.bearing - a.bearing + 540) % 360) - 180;
  return (lat: a.lat + (b.lat - a.lat) * k, lon: a.lon + (b.lon - a.lon) * k, bearing: (a.bearing + turn * k) % 360);
}

/// The shortest and longest a glide from one fix to the next takes ([GuideGlide]).
const Duration kGlideShortest = Duration(milliseconds: 250);
const Duration kGlideLongest = Duration(milliseconds: 1500);

/// A glide this far or further is a jump (the first fix, a fix after a gap): the map moves there with its own animation.
const double kGlideFarthestM = 300;

/// While guiding, the map and the position's marker move together from one fix to the next at an even pace, over the time the
/// fixes come apart ([glideDuration]), so the marker stays where the camera puts it the whole way. (Moving the marker at once
/// and the camera over most of a second made it jump ahead at each fix and slide back.)
class GuideGlide {
  GuideGlide({required this.from, required this.to, required this.duration});

  final GuidePose from;
  final GuidePose to;
  final Duration duration;

  /// The pose [elapsed] into the glide.
  GuidePose at(Duration elapsed) => doneAt(elapsed) ? to : lerpPose(from, to, elapsed.inMicroseconds / duration.inMicroseconds);

  /// Whether [elapsed] reaches the end.
  bool doneAt(Duration elapsed) => elapsed >= duration;
}

/// How long the glide to a fix takes: the time since the fix before it ([since]; a second when unknown), within
/// [kGlideShortest] and [kGlideLongest].
Duration glideDuration(Duration? since) {
  final d = since ?? const Duration(seconds: 1);
  if (d < kGlideShortest) return kGlideShortest;
  if (d > kGlideLongest) return kGlideLongest;
  return d;
}

/// Metres between two poses (flat; for short distances).
double poseDistanceM(GuidePose a, GuidePose b) {
  final north = (b.lat - a.lat) * 111320;
  final east = (b.lon - a.lon) * 111320 * math.cos(a.lat * math.pi / 180);
  return math.sqrt(north * north + east * east);
}

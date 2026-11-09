import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../layout/adaptive.dart' show kMapSideWidth;

/// While guiding with the map turned to the heading, the phone's position sits low on the map (as Google and Apple Maps do), so
/// more of the road ahead is in view. On a phone held upright it is 72% of the way down, centred across. From [kSideCardWidth]
/// wide (a tablet, a computer, a phone held sideways) the banner and the bar sit in the left column, so the position is centred
/// in the map to the right of it and 70% of the way down. It always stays clear of the card at the foot.
/// [side] is whether the screen lays out side by side; [leftInset] is the safe area on the left.
Offset guidanceAnchor(Size map, {required bool side, double leftInset = 0}) {
  if (map.isEmpty) return map.center(Offset.zero);
  // Stacked: the guidance bar, the scale and the credits take the foot. Side by side: only the scale and the credits do.
  final footRoom = side ? 72.0 : 190.0;
  final y = (map.height * (side ? 0.70 : 0.72)).clamp(map.height / 2, math.max(map.height / 2, map.height - footRoom)).toDouble();
  final columnRight = side ? leftInset + 12 + kMapSideWidth + 12 : 0.0;
  final x = side && columnRight < map.width ? (columnRight + map.width) / 2 : map.width / 2;
  return Offset(x, y);
}

/// Metres per logical pixel at [zoom] and [lat] (MapLibre draws the world 512 pixels wide at zoom 0).
double metresPerPixel(double lat, double zoom) => 2 * math.pi * 6378137 * math.cos(lat * math.pi / 180) / (512 * math.pow(2, zoom));

/// The camera's centre that puts ([lat], [lon]) at [anchor] on a map of [map] size turned to [bearing] degrees at [zoom].
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

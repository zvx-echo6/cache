import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/painting.dart' show Color;

import '../maps/palette/map_palette.dart';
import '../nav/elevation/elevation_profile.dart';
import '../theme.dart';

/// The two Cache-drawn pieces on the car's map (the climb-ahead card and the route mini map), as plain data for the car side to
/// paint (app/android/.../car/CarOverlayPainter.kt). Nothing here is drawn; the car works nothing out, it paints what it is sent.
///
/// The defaults of the two switches are these constants, so turning a piece off for everyone is a one-line change. They reach the
/// car in the trip as `overlay: {climb: .., miniMap: ..}`. (There is no car section in Settings yet, so no per-person switch.)
const bool kCarClimbAheadDefault = true;
const bool kCarRouteMiniMapDefault = true;

/// How many heights the climb card's shape is drawn from.
const int kClimbSamples = 56;

/// The most points the mini map's route line is simplified to.
const int kOverviewMaxPoints = 150;

/// The day theme the car uses by day (the phone has no day/night pair setting): the chosen theme if it is Light or Parchment,
/// else Light.
CacheThemeId carDayTheme(CacheThemeId chosen) => chosen == CacheThemeId.light || chosen == CacheThemeId.parchment ? chosen : CacheThemeId.light;

/// The night theme: the chosen theme if it is Dark or Tactical, else Dark.
CacheThemeId carNightTheme(CacheThemeId chosen) => chosen == CacheThemeId.dark || chosen == CacheThemeId.tactical ? chosen : CacheThemeId.dark;

/// The theme whose map style the car map draws: by day Light's, by night Dark's, except that a chosen Tactical gets the full
/// Tactical map style at night, the same palette the phone's map uses for Tactical (mapPaletteFor).
CacheThemeId carMapTheme({required bool dark, required CacheThemeId chosen}) =>
    !dark ? CacheThemeId.light : (chosen == CacheThemeId.tactical ? CacheThemeId.tactical : CacheThemeId.dark);

/// The `climb` block, or null with no elevation data (the card is then not drawn).
///
/// [distanceAlongM] is the core's metres along the route; [routeM] the route's length (the profile measures the same line a
/// little differently, so the position is scaled to the profile, as [RouteElevation.positionOnProfile] does).
Map<String, dynamic>? carClimb(ElevationProfile? profile, {required double? distanceAlongM, required double routeM}) {
  if (profile == null || !profile.hasData || profile.distM.isEmpty) return null;
  final posM = _positionOnProfile(profile, distanceAlongM, routeM);
  final steep = profile.steepestClimbAhead(posM);

  // The climb still to come: the dead-band climb over the heights from the position on.
  final ahead = <double>[];
  for (var i = 0; i < profile.distM.length; i++) {
    if (profile.distM[i] < posM || profile.elevM[i].isNaN) continue;
    ahead.add(profile.elevM[i]);
  }
  final climbAheadM = climbAndDescent(ahead).climb;

  final remaining = math.max(0.0, profile.totalM - posM);
  final window = math.min(remaining, math.max(8000.0, steep == null ? 0.0 : steep.endM - posM + 1500));
  if (window < 1) return null;
  final heights = <double>[];
  double? last;
  for (var i = 0; i < kClimbSamples; i++) {
    final e = profile.elevationAt(posM + window * i / (kClimbSamples - 1));
    last = e ?? last;
    heights.add(last ?? double.nan);
  }
  // A gap at the start takes the first height that exists.
  final firstReal = heights.firstWhere((h) => !h.isNaN, orElse: () => double.nan);
  if (firstReal.isNaN) return null;
  for (var i = 0; i < heights.length && heights[i].isNaN; i++) {
    heights[i] = firstReal;
  }

  int? from, to;
  if (steep != null) {
    from = (((steep.startM - posM) / window) * (kClimbSamples - 1)).round().clamp(0, kClimbSamples - 1);
    to = (((steep.endM - posM) / window) * (kClimbSamples - 1)).round().clamp(0, kClimbSamples - 1);
    if (to <= from) from = to = null;
  }
  return {
    'climbAheadM': climbAheadM,
    'gradePct': steep == null ? null : steep.grade * 100,
    'steepestInM': steep == null ? null : math.max(0.0, steep.startM - posM),
    'heightsM': heights,
    'steepFrom': from,
    'steepTo': to,
    'windowM': window,
  };
}

double _positionOnProfile(ElevationProfile p, double? alongM, double routeM) {
  if (alongM == null || routeM <= 0) return 0;
  return (alongM * p.totalM / routeM).clamp(0, p.totalM).toDouble();
}

/// The `overview` block: the whole route simplified, how much of it is driven, the steepest point's place and grade, and the
/// destination. Null with no route.
Map<String, dynamic>? carOverview(MapRoute? route, {required double? distanceAlongM, ElevationProfile? profile, GeoPoint? destination}) {
  if (route == null || route.points.length < 2) return null;
  final pts = simplifyRoute(route.points, kOverviewMaxPoints);
  final routeM = route.distanceM > 0 ? route.distanceM : 1.0;
  final driven = distanceAlongM == null ? 0.0 : (distanceAlongM / routeM).clamp(0.0, 1.0).toDouble();

  Map<String, dynamic>? steepPoint;
  if (profile != null && profile.hasData) {
    final posM = _positionOnProfile(profile, distanceAlongM, route.distanceM);
    final c = profile.steepestClimbAhead(posM);
    if (c != null && profile.totalM > 0) {
      final at = pointAtFraction(route.points, ((c.startM + c.endM) / 2 / profile.totalM).clamp(0.0, 1.0));
      steepPoint = {'lat': at.lat, 'lon': at.lon, 'gradePct': c.grade * 100};
    }
  }
  final end = destination ?? route.points.last;
  return {
    'points': [for (final p in pts) [p.lat, p.lon]],
    'drivenFraction': driven,
    'steep': steepPoint,
    'destination': {'lat': end.lat, 'lon': end.lon},
  };
}

/// The route cut down to at most [max] points: Douglas-Peucker with a tolerance that grows until it fits, so the shape stays.
List<GeoPoint> simplifyRoute(List<GeoPoint> points, int max) {
  if (points.length <= max) return points;
  var tol = 2.0;
  var out = points;
  for (var i = 0; i < 24 && out.length > max; i++) {
    out = _dp(points, tol);
    tol *= 1.7;
  }
  if (out.length > max) {
    // Still over (a very wiggly line): take evenly by index, keeping both ends.
    out = [for (var i = 0; i < max; i++) out[(i * (out.length - 1) / (max - 1)).round()]];
  }
  return out;
}

List<GeoPoint> _dp(List<GeoPoint> pts, double tolM) {
  final lat0 = pts.first.lat * math.pi / 180;
  final kx = 111320.0 * math.cos(lat0), ky = 110574.0;
  final xs = [for (final p in pts) p.lon * kx], ys = [for (final p in pts) p.lat * ky];
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var worst = -1.0;
    var at = -1;
    final dx = xs[b] - xs[a], dy = ys[b] - ys[a];
    final len2 = dx * dx + dy * dy;
    for (var i = a + 1; i < b; i++) {
      double d;
      if (len2 == 0) {
        d = math.sqrt(math.pow(xs[i] - xs[a], 2) + math.pow(ys[i] - ys[a], 2));
      } else {
        final t = (((xs[i] - xs[a]) * dx + (ys[i] - ys[a]) * dy) / len2).clamp(0.0, 1.0);
        d = math.sqrt(math.pow(xs[i] - (xs[a] + t * dx), 2) + math.pow(ys[i] - (ys[a] + t * dy), 2));
      }
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (worst > tolM && at > 0) {
      keep[at] = true;
      stack.add((a, at));
      stack.add((at, b));
    }
  }
  return [for (var i = 0; i < pts.length; i++) if (keep[i]) pts[i]];
}

double _metersBetween(GeoPoint a, GeoPoint b) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// The point [fraction] of the way along the line by length.
GeoPoint pointAtFraction(List<GeoPoint> pts, double fraction) {
  if (pts.length < 2) return pts.first;
  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    cum.add(cum.last + _metersBetween(pts[i - 1], pts[i]));
  }
  final target = cum.last * fraction.clamp(0.0, 1.0);
  var i = 1;
  while (i < cum.length - 1 && cum[i] < target) {
    i++;
  }
  final seg = cum[i] - cum[i - 1];
  final t = seg <= 0 ? 0.0 : ((target - cum[i - 1]) / seg).clamp(0.0, 1.0);
  return GeoPoint(pts[i - 1].lat + (pts[i].lat - pts[i - 1].lat) * t, pts[i - 1].lon + (pts[i].lon - pts[i - 1].lon) * t);
}

String _hex(Color c) {
  String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}';
}

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// The overlay's colors for one theme, as `#rrggbb`. They come from the Dart tokens and the map palette, so the car side holds no
/// palette. The route is the palette's own route color (never a traffic green, yellow, orange or red); Tactical is all on its red
/// ramp, no white anywhere.
Map<String, String> carOverlayColors(CacheThemeId id) {
  final k = cacheTokens[id]!;
  // Parchment's route is brown on the phone; on the car screen it uses Light's blue (route, mini map, climb shape and badge edge
  // all come from this one color). The phone's Parchment is unchanged.
  final route = mapPaletteFor(id == CacheThemeId.parchment ? CacheThemeId.light : id).css('route');
  final r = Color(int.parse('FF${route.substring(1)}', radix: 16));
  Map<String, Color> c;
  switch (id) {
    case CacheThemeId.tactical:
      c = {
        'route': r,
        'routeDriven': const Color(0xFF7A2A24),
        'badge': const Color(0xFFFF8A7D),
        'badgeGlyph': const Color(0xFF3A0B07),
        'badgeEdge': k.background,
        'startDot': k.secondary,
        'destDot': r,
        'posFill': const Color(0xFFFF9A90),
        'posRing': r,
      };
    case CacheThemeId.light:
      c = {
        'route': r,
        'routeDriven': const Color(0xFF9AA3AD),
        'badge': const Color(0xFFFFFFFF),
        'badgeGlyph': k.text,
        'badgeEdge': r,
        'startDot': const Color(0xFF7C8590),
        'destDot': k.text,
        'posFill': const Color(0xFFFFFFFF),
        'posRing': r,
      };
    case CacheThemeId.parchment:
      c = {
        'route': r,
        'routeDriven': const Color(0xFFA39A85),
        'badge': const Color(0xFFFFFDF8),
        'badgeGlyph': k.text,
        'badgeEdge': r,
        'startDot': const Color(0xFF8A7F66),
        'destDot': k.text,
        'posFill': const Color(0xFFFFFDF8),
        'posRing': r,
      };
    case CacheThemeId.dark:
      c = {
        'route': r,
        'routeDriven': const Color(0xFF4A5866),
        'badge': const Color(0xFFF4F6F8),
        'badgeGlyph': const Color(0xFF161B20),
        'badgeEdge': k.background,
        'startDot': const Color(0xFF8A96A3),
        'destDot': const Color(0xFFF4F6F8),
        'posFill': const Color(0xFFFFFFFF),
        'posRing': r,
      };
  }
  // The host's own guidance card (NavigationTemplate background): the theme surface; Tactical a dark red.
  c['hostCard'] = id == CacheThemeId.tactical ? const Color(0xFF3A0B07) : k.surface;
  c['card'] = k.surface;
  // Text on the card reads at 4.5:1 or better in every theme. Tactical's own text and secondary reds are too faint on its card
  // for the car (4.9:1 and 2.4:1), so there the figures take its brightest red and the label its text red: still red on black.
  c['cardText'] = id == CacheThemeId.tactical ? k.accent : k.text;
  c['cardSecondary'] = id == CacheThemeId.tactical ? k.text : k.secondary;
  c['hatch'] = k.text;
  c['miniBg'] = k.background;
  c['miniBorder'] = _mix(k.background, k.secondary, 0.45);
  return {for (final e in c.entries) e.key: _hex(e.value)};
}

/// The `palette` block: the colors for the car's day (carDayTheme) and night (carNightTheme), each with the theme it came from.
Map<String, dynamic> carOverlayPalette(CacheThemeId chosen) {
  final day = carDayTheme(chosen), night = carNightTheme(chosen);
  return {
    'day': {'theme': day.name, ...carOverlayColors(day)},
    'night': {'theme': night.name, ...carOverlayColors(night)},
  };
}

/// The `overlay` switches.
Map<String, bool> carOverlaySwitches({bool climb = kCarClimbAheadDefault, bool miniMap = kCarRouteMiniMapDefault}) => {'climb': climb, 'miniMap': miniMap};

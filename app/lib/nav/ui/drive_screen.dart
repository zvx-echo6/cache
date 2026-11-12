import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../car/car_overlay.dart';
import '../../car/phone_drive.dart';
import '../../maps/palette/map_palette.dart';
import '../../theme.dart';
import '../elevation/route_elevation.dart';
import '../guidance.dart';
import '../nav_state.dart';
import '../units.dart';
import 'elevation_panel.dart';
import 'guidance_panels.dart';

/// How much of the room between the top of the screen and the bottom bar the list of turns takes while the phone carries the route
/// mini map and the elevation too; they share the rest, side by side. The owner chose two thirds from pictures (2026-11-12); change
/// it here and nowhere else. When the car carries the two (a big car screen) the list has the whole room.
const double kDriveTurnsShare = 2 / 3;

/// The phone's drive screen: what the Maps tab shows while a car screen is connected and guiding. The next turn first (the
/// phone's own turn banner, with its lane arrows when it has them), then the turns after it with the stops where they come, and
/// under them the route mini map and the elevation, which the car's screen does not carry (see [CarExtras]). The guidance bar at
/// the foot is the phone's own, with the same voice switch and End.
class DriveScreen extends StatelessWidget {
  const DriveScreen({
    super.key,
    required this.nav,
    required this.elevation,
    required this.palette,
    required this.themeId,
    this.extras = CarExtras.never,
  });

  final NavState nav;
  final RouteElevation elevation;
  final MapPalette palette;
  final CacheThemeId themeId;

  /// Where the car carries the mini map and the elevation. On this screen they are drawn unless the car always carries them.
  final CarExtras extras;

  /// The mini map and the elevation are on the phone's screen (this screen is showing, so [CarExtras.unlessPhoneShows] counts).
  bool get showsExtras => extras != CarExtras.always;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Material(
      key: const ValueKey('drive-screen'),
      color: k.background,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([nav, elevation]),
                builder: (context, _) => LayoutBuilder(
                  builder: (context, box) {
                    final room = box.maxHeight;
                    final turnsH = showsExtras ? room * kDriveTurnsShare : room;
                    return Column(
                      children: [
                        SizedBox(height: turnsH, child: DriveTurns(nav: nav)),
                        if (showsExtras)
                          Expanded(
                            child: DriveExtras(nav: nav, elevation: elevation, palette: palette, themeId: themeId),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
            // The guidance bar as it is in the dock (voice, arrive, left, to go, End), above the home indicator.
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: ListenableBuilder(
                  listenable: nav,
                  builder: (context, _) => GuidanceBar(nav: nav, fmt: nav.fmt),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The list of turns: the next turn as the phone's turn banner (lane arrows included), and under it the turns after it, with the
/// stops where they come, as they are in the route.
class DriveTurns extends StatelessWidget {
  const DriveTurns({super.key, required this.nav});

  final NavState nav;

  static const double rowHeight = 56;

  /// The turns after the next one, in order, as rows (none on arrival, while the position is not known, or with no route).
  static List<DriveRow> rowsAfterNext(NavState nav) {
    final p = nav.progress, r = nav.route;
    if (nav.arrived || p == null || r == null || p.next == null || p.next!.isArrival) return const [];
    final from = p.next!.index;
    final stops = nav.routeStopsInOrder;
    var stopAt = 0;
    final rows = <DriveRow>[];
    for (final (i, m) in r.maneuvers.indexed) {
      if (m.type == 'via') {
        // The route's stops in order: the n-th stop maneuver is the n-th stop of the route.
        final stop = stopAt < stops.length ? stops[stopAt] : null;
        stopAt++;
        if (m.index <= from) continue;
        rows.add(DriveRow(maneuver: m, distanceM: i == 0 ? 0 : r.maneuvers[i - 1].distanceM, stopNumber: stop?.$1 ?? stopAt, stopName: stop?.$2.name));
      } else if (m.index > from) {
        rows.add(DriveRow(maneuver: m, distanceM: i == 0 ? 0 : r.maneuvers[i - 1].distanceM));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = rowsAfterNext(nav);
    final k = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: GuidanceBanner(nav: nav, fmt: nav.fmt, showThen: false),
        ),
        Expanded(
          child: Opacity(
            // The old list stays, dimmed, while a new route is worked out; it is replaced when the route lands.
            opacity: nav.rerouting ? 0.4 : 1,
            child: LayoutBuilder(
              builder: (context, box) {
                // A list longer than its room fades out at its lower edge, so it reads as scrolling and never ends in a cut row.
                final overflows = rows.length * rowHeight + 4 > box.maxHeight;
                final list = ListView.builder(
                  key: const ValueKey('drive-turns'),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  itemExtent: rowHeight,
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _row(context, k, rows[i]),
                );
                if (!overflows || box.maxHeight <= 0) return list;
                final fade = math.min(40.0, box.maxHeight / 2) / box.maxHeight;
                return ShaderMask(
                  key: const ValueKey('drive-turns-fade'),
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (r) => LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
                    stops: [0, 1 - fade, 1],
                  ).createShader(r),
                  child: list,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, CacheTokens k, DriveRow r) {
    final m = r.maneuver;
    final icon = iconForTurn(turnIconFor(m.type, offroad: m.isOffroad));
    return Container(
      key: ValueKey('drive-row-${m.index}'),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.22)))),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: k.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 22, color: k.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              r.text(nav.fmt),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, height: 1.15, color: k.text),
            ),
          ),
          const SizedBox(width: 10),
          if (r.distanceM > 0) Text(nav.fmt.distance(r.distanceM), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.secondary)),
        ],
      ),
    );
  }
}

/// One row of the list: a maneuver of the route, how far it is from the one before it, and for a stop its number and name.
class DriveRow {
  const DriveRow({required this.maneuver, required this.distanceM, this.stopNumber, this.stopName});

  final Maneuver maneuver;
  final double distanceM;
  final int? stopNumber;
  final String? stopName;

  /// The words: the route's own instruction ("Turn left onto Alder Street"), an off-road leg as the turn banner words it, and a
  /// stop as the route panel does ("Stop 1: Corner Market").
  String text(Fmt fmt) {
    final m = maneuver;
    if (m.type == 'via' && stopName != null) return 'Stop $stopNumber: $stopName';
    var t = m.isOffroad
        ? offroadHint(
            ProgressManeuver(
              index: m.index,
              kind: m.kind,
              type: m.type,
              instruction: m.instruction,
              lat: m.lat,
              lon: m.lon,
              distanceM: m.distanceM,
              lengthM: m.distanceM,
              cardinal: m.cardinal,
              bearingDeg: m.bearingDeg,
              elevGainM: m.elevGainM,
              elevLossM: m.elevLossM,
              gradeClass: m.gradeClass,
            ),
            fmt)
        : m.instruction.trim();
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    return t;
  }
}

/// The route mini map and the elevation, side by side.
class DriveExtras extends StatelessWidget {
  const DriveExtras({super.key, required this.nav, required this.elevation, required this.palette, required this.themeId});

  final NavState nav;
  final RouteElevation elevation;
  final MapPalette palette;
  final CacheThemeId themeId;

  @override
  Widget build(BuildContext context) {
    final r = nav.route;
    final p = nav.progress;
    final dest = nav.selected;
    final overview = r == null
        ? null
        : carOverview(r, distanceAlongM: p?.distanceAlongM, profile: elevation.profile, destination: dest == null ? null : GeoPoint(dest.lat, dest.lon));
    final chart = DriveElevation(nav: nav, elevation: elevation, palette: palette);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: overview == null
          ? chart
          : Row(
              children: [
                Expanded(flex: 4, child: DriveMiniMap(overview: overview, themeId: themeId)),
                const SizedBox(width: 8),
                Expanded(flex: 6, child: chart),
              ],
            ),
    );
  }
}

/// The elevation of the whole route with the position on it, and the steepest climb ahead, in the words of the elevation panel.
class DriveElevation extends StatelessWidget {
  const DriveElevation({super.key, required this.nav, required this.elevation, required this.palette});

  final NavState nav;
  final RouteElevation elevation;
  final MapPalette palette;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final fmt = nav.fmt;
    final prof = elevation.profile;
    final Widget body;
    if (prof == null) {
      body = Row(
        children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: k.secondary)),
          const SizedBox(width: 10),
          Text('Reading the elevation', style: TextStyle(fontSize: 16, color: k.secondary)),
        ],
      );
    } else if (!prof.hasData) {
      body = Row(
        key: const ValueKey('elevation-none'),
        children: [
          Icon(Icons.terrain, size: 22, color: k.secondary),
          const SizedBox(width: 10),
          Expanded(child: Text('No elevation data for this route.', style: TextStyle(fontSize: 16, color: k.secondary))),
        ],
      );
    } else {
      final pos = elevation.positionOnProfile(nav.progress?.distanceAlongM, nav.route?.distanceM ?? 0);
      final steep = prof.steepestClimbAhead(pos ?? 0);
      final where = steep == null ? '' : (pos == null || steep.startM - pos < 1 ? ', starts here' : ', in ${fmt.distance(steep.startM - pos)}');
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => ElevationChart(
                key: const ValueKey('elevation-chart'),
                profile: prof,
                fmt: fmt,
                palette: palette,
                height: math.max(24.0, box.maxHeight),
                positionM: pos,
                steep: steep,
                // The plain chart: the line, the position and the climb marked on it, with no point labels to run into each other.
                full: false,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            key: const ValueKey('elevation-steep'),
            children: [
              Container(width: 16, height: 5, decoration: BoxDecoration(color: k.warning, borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: 'Steepest climb ahead  ', style: TextStyle(color: k.secondary)),
                    TextSpan(text: steep == null ? 'None' : '${(steep.grade * 100).round()}%', style: TextStyle(fontWeight: FontWeight.w700, color: k.text)),
                    if (steep != null) TextSpan(text: ' for ${fmt.distance(steep.lengthM)}$where', style: TextStyle(color: k.text)),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, height: 1.15),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Container(
      key: const ValueKey('drive-elevation'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: k.secondary.withValues(alpha: 0.22))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text('Elevation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: k.text))),
              if (prof != null && prof.hasData) Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Whole route, ${routeLengthText(fmt, prof.totalM)}', maxLines: 1, style: TextStyle(fontSize: 13, color: k.secondary)))),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// The route mini map the car's overlay draws (the whole route, the part driven, the steep stretch's pill, the start, the
/// destination and the moving dot), drawn here in Flutter from the same data ([carOverview]) and colors ([carOverlayColors]).
/// Not a live map.
class DriveMiniMap extends StatelessWidget {
  const DriveMiniMap({super.key, required this.overview, required this.themeId});

  final Map<String, dynamic> overview;
  final CacheThemeId themeId;

  @override
  Widget build(BuildContext context) {
    final c = _colors(themeId);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        key: const ValueKey('drive-mini-map'),
        decoration: BoxDecoration(color: c['miniBg'], borderRadius: BorderRadius.circular(14), border: Border.all(color: c['miniBorder']!)),
        child: CustomPaint(painter: RouteMiniMapPainter(overview: overview, colors: c), child: const SizedBox.expand()),
      ),
    );
  }

  static Map<String, Color> _colors(CacheThemeId id) => {
        for (final e in carOverlayColors(id).entries) e.key: Color(int.parse('FF${e.value.substring(1)}', radix: 16)),
      };
}

/// The mini map's drawing: the Android car overlay's (CarOverlayPainter.drawMiniContent), scaled to the box it is given.
class RouteMiniMapPainter extends CustomPainter {
  RouteMiniMapPainter({required this.overview, required this.colors});

  final Map<String, dynamic> overview;
  final Map<String, Color> colors;

  /// The size the car draws it at: 220 x 140.
  static const double fullHeight = 140;
  static const double fullWidth = 220;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final p in overview['points'] as List) (((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())];
    if (pts.length < 2 || size.isEmpty) return;
    final s = math.min(size.height / fullHeight, size.width / fullWidth).clamp(0.5, 1.4).toDouble();
    final steep = overview['steep'] as Map?;
    final all = [...pts, if (steep != null) (((steep['lat']) as num).toDouble(), ((steep['lon']) as num).toDouble())];
    final px = _project(all, size, 24 * s);
    final route = px.sublist(0, pts.length);

    Path poly(List<Offset> l) {
      final path = Path()..moveTo(l.first.dx, l.first.dy);
      for (final o in l.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      return path;
    }

    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    Paint fill(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawPath(poly(route), stroke(colors['route']!, 5 * s));
    final driven = _cut(route, (overview['drivenFraction'] as num).toDouble());
    if (driven.length >= 2) canvas.drawPath(poly(driven), stroke(colors['routeDriven']!, 5 * s));
    final end = route.last;
    if (steep != null) {
      final at = px.last;
      // The pill is left out when it would lie under the destination dot (as the car's is).
      if ((at.dx - end.dx).abs() >= (14 + 6 + 2) * s || (at.dy - end.dy).abs() >= (10 + 6 + 2) * s) _pill(canvas, at, s);
    }
    canvas.drawCircle(route.first, 5 * s, fill(colors['startDot']!));
    canvas.drawCircle(end, 6 * s, fill(colors['destDot']!));
    final here = driven.last;
    canvas.drawCircle(here, 8 * s, fill(colors['posFill']!));
    canvas.drawCircle(here, 8 * s, stroke(colors['posRing']!, 3 * s));
  }

  /// The grade pill without its figure: a rounded 28 x 20 pill with the slope triangle.
  void _pill(Canvas canvas, Offset c, double s) {
    final box = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 28 * s, height: 20 * s), Radius.circular(10 * s));
    canvas.drawRRect(box, Paint()..color = colors['badge']!);
    canvas.drawRRect(
      box,
      Paint()
        ..color = colors['badgeEdge']!
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, 1.5 * s),
    );
    final tx = c.dx - 7 * s;
    final tri = Path()
      ..moveTo(tx, c.dy + 5 * s)
      ..lineTo(tx + 10 * s, c.dy - 5 * s)
      ..lineTo(tx + 10 * s, c.dy + 5 * s)
      ..close();
    canvas.drawPath(tri, Paint()..color = colors['badgeGlyph']!);
  }

  /// The points in the box: equirectangular (longitude scaled by cos latitude), one scale, centered, with [pad] around.
  static List<Offset> _project(List<(double, double)> points, Size box, double pad) {
    final lat0 = points.map((p) => p.$1).reduce((a, b) => a + b) / points.length;
    final kx = math.cos(lat0 * math.pi / 180);
    final xs = [for (final p in points) p.$2 * kx], ys = [for (final p in points) -p.$1];
    final minX = xs.reduce(math.min), maxX = xs.reduce(math.max), minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    final w = math.max(maxX - minX, 1e-9), h = math.max(maxY - minY, 1e-9);
    final aw = box.width - 2 * pad, ah = box.height - 2 * pad;
    final sc = math.min(aw / w, ah / h);
    final ox = pad + (aw - w * sc) / 2, oy = pad + (ah - h * sc) / 2;
    return [for (var i = 0; i < points.length; i++) Offset(ox + (xs[i] - minX) * sc, oy + (ys[i] - minY) * sc)];
  }

  /// The first [fraction] of the line by length, ending exactly there.
  static List<Offset> _cut(List<Offset> pts, double fraction) {
    if (pts.length < 2 || fraction <= 0) return pts.take(1).toList();
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + (pts[i] - pts[i - 1]).distance);
    }
    final target = cum.last * fraction.clamp(0.0, 1.0);
    final out = <Offset>[pts[0]];
    for (var i = 1; i < pts.length; i++) {
      if (cum[i] <= target) {
        out.add(pts[i]);
      } else {
        final seg = cum[i] - cum[i - 1];
        final t = seg <= 0 ? 0.0 : (target - cum[i - 1]) / seg;
        out.add(Offset.lerp(pts[i - 1], pts[i], t)!);
        break;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(RouteMiniMapPainter old) => old.overview != overview || old.colors != colors;
}

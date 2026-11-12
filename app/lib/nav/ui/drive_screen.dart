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

/// The other form, for a wide route only (the owner is choosing between them from pictures): the list takes half of the room and
/// the stacked boxes the other half, each at a proper height. Off until he chooses; one constant switches it for everyone.
const bool kDriveWideHalf = false;
const double kDriveWideTurnsShare = 1 / 2;

/// The phone's drive screen: what the Maps tab shows while a car screen is connected and guiding. The next turn first (the
/// phone's own turn banner, with its lane arrows when it has them), then the turns after it with the stops where they come, and
/// under them the route mini map and the elevation, which the car's screen does not carry (see [CarExtras]). The guidance bar at
/// the foot is the phone's own, with the same voice switch and End.
class DriveScreen extends StatefulWidget {
  const DriveScreen({
    super.key,
    required this.nav,
    required this.elevation,
    required this.palette,
    required this.themeId,
    this.extras = CarExtras.never,
    this.wideHalf = kDriveWideHalf,
    this.sideBySideOnly = false,
  });

  final NavState nav;
  final RouteElevation elevation;
  final MapPalette palette;
  final CacheThemeId themeId;

  /// For a wide route the list takes [kDriveWideTurnsShare] of the room instead of [kDriveTurnsShare] ([kDriveWideHalf]).
  final bool wideHalf;

  /// Pictures only: every route is shown side by side, whatever its shape.
  @visibleForTesting
  final bool sideBySideOnly;

  /// Where the car carries the mini map and the elevation. On this screen they are drawn unless the car always carries them.
  final CarExtras extras;

  /// The mini map and the elevation are on the phone's screen (this screen is showing, so [CarExtras.unlessPhoneShows] counts).
  bool get showsExtras => extras != CarExtras.always;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  NavState get nav => widget.nav;
  RouteElevation get elevation => widget.elevation;

  String? _forRoute;
  bool? _stacked;

  /// Whether the route's two boxes stack: chosen when the route changes (the first route, or a re-route), not at each update.
  bool _stackedNow() {
    final r = nav.route;
    if (r == null || widget.sideBySideOnly) return false;
    if (_forRoute != r.routeId) {
      _forRoute = r.routeId;
      _stacked = driveStacked(routeAspect(r.points), previous: _stacked);
    }
    return _stacked ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final themeId = widget.themeId, palette = widget.palette;
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
                    final stacked = widget.showsExtras && _stackedNow();
                    final share = stacked && widget.wideHalf ? kDriveWideTurnsShare : kDriveTurnsShare;
                    final turnsH = widget.showsExtras ? room * share : room;
                    return Column(
                      children: [
                        SizedBox(height: turnsH, child: DriveTurns(nav: nav)),
                        if (widget.showsExtras)
                          Expanded(
                            child: DriveExtras(nav: nav, elevation: elevation, palette: palette, themeId: themeId, stacked: stacked),
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
                // The rows grow with the text size (two lines of larger text still fit a row).
                final extent = rowHeight * math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);
                final overflows = rows.length * extent + 4 > box.maxHeight;
                final list = ListView.builder(
                  key: const ValueKey('drive-turns'),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  itemExtent: extent,
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

/// The route's shape (its width over its height as the mini map draws it, east-west over north-south, north up) at which the two
/// boxes stack, the mini map across the full width and the elevation under it, instead of sitting side by side. The natural line
/// is the side-by-side mini map box's own proportions: about 140 wide and 195 high at 390 points (a width over height of about
/// 0.75). A route fills that box to its full height only up to that shape; at twice it (1.5) the route fills half the box's height
/// and the rest is blank, so from there the wide box serves it better.
const double kDriveStackAspect = 1.5;

/// The margin a re-route must clear to change the arrangement: a stacked one goes back to side by side only below
/// [kDriveStackAspect] over this (1.2), a side-by-side one stacks only above [kDriveStackAspect] times this (1.875). A nearly
/// square route, or one a little either side of the line, never flips back and forth.
const double kDriveStackMargin = 1.25;

/// Whether a route of [aspect] (width over height) is shown stacked. The first route of a drive is decided by the line alone;
/// after that [previous] is kept unless the new route is clearly the other kind (the margin).
bool driveStacked(double aspect, {bool? previous}) {
  if (previous == null) return aspect >= kDriveStackAspect;
  return previous ? aspect > kDriveStackAspect / kDriveStackMargin : aspect >= kDriveStackAspect * kDriveStackMargin;
}

/// The shape of [points] as the mini map draws it (the same projection: longitude scaled by the cosine of the mean latitude, north
/// up): its width over its height.
double routeAspect(List<GeoPoint> points) {
  if (points.length < 2) return 1;
  var minLat = points.first.lat, maxLat = minLat, minLon = points.first.lon, maxLon = minLon, sumLat = 0.0;
  for (final p in points) {
    minLat = math.min(minLat, p.lat);
    maxLat = math.max(maxLat, p.lat);
    minLon = math.min(minLon, p.lon);
    maxLon = math.max(maxLon, p.lon);
    sumLat += p.lat;
  }
  final w = (maxLon - minLon) * math.cos(sumLat / points.length * math.pi / 180);
  final h = maxLat - minLat;
  return h <= 1e-9 ? 1e9 : w / h;
}

/// The least height the elevation box gets when it is under the mini map: its title, a chart you can read, the climb line and its
/// padding at the normal text size (a narrow phone, whose climb line wraps, and larger text, add to it).
const double kDriveElevationMinHeight = 120;

/// The least height the mini map gets when it is stacked above the elevation.
const double kDriveMiniMinHeight = 56;

/// The route mini map and the elevation. Which way they sit is chosen once for a route, by its shape ([driveStacked]):
/// a wide route stacks (the mini map across the full width, short; the elevation under it, full width), any other sits side by
/// side (the mini map left, the elevation right). A re-route may change it only when its shape is clearly the other kind.
class DriveExtras extends StatelessWidget {
  const DriveExtras({super.key, required this.nav, required this.elevation, required this.palette, required this.themeId, this.stacked = false});

  final NavState nav;
  final RouteElevation elevation;
  final MapPalette palette;
  final CacheThemeId themeId;

  /// The route's boxes stack (see [driveStacked]); the screen decides it once for each route.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final r = nav.route;
    final p = nav.progress;
    final dest = nav.selected;
    final overview = r == null
        ? null
        : carOverview(r, distanceAlongM: p?.distanceAlongM, profile: elevation.profile, climbAhead: elevation.climbAhead, destination: dest == null ? null : GeoPoint(dest.lat, dest.lon));
    final chart = DriveElevation(nav: nav, elevation: elevation, palette: palette);
    if (overview == null) return Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 4), child: chart);
    final mini = DriveMiniMap(overview: overview, themeId: themeId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: LayoutBuilder(
        builder: (context, box) {
          // The mini map takes the height its route needs across the full width (the route fitted with the box's padding), but
          // never so much that the elevation under it has less than it needs; the elevation takes the rest. Where there is not
          // room for both at those least heights (a short phone, large text) the two sit side by side, as they do for other routes.
          final f = math.max(1.0, MediaQuery.textScalerOf(context).scale(16) / 16);
          final narrow = box.maxWidth < 330;
          final elevMin = kDriveElevationMinHeight * f + (narrow ? 18 : 0);
          final avail = box.maxHeight - 8;
          if (!stacked || avail < elevMin + kDriveMiniMinHeight) {
            return Row(
              children: [
                Expanded(flex: 4, child: mini),
                const SizedBox(width: 8),
                Expanded(flex: 6, child: chart),
              ],
            );
          }
          final natural = (box.maxWidth - 48) / math.min(routeAspect(r!.points), 8) + 48;
          final miniH = math.max(kDriveMiniMinHeight, math.min(natural, avail - elevMin));
          return Column(
            children: [
              SizedBox(height: miniH, child: mini),
              const SizedBox(height: 8),
              Expanded(child: chart),
            ],
          );
        },
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
    if (prof == null || (!prof.hasData && elevation.loading)) {
      // Nothing read yet: the frame and its guide lines, never a message or a spinner. The first chunk draws into it.
      body = CustomPaint(key: const ValueKey('elevation-frame'), painter: _EmptyChartPainter(k.secondary.withValues(alpha: 0.35)), child: const SizedBox.expand());
    } else if (!prof.chartable) {
      // The read is done and found no data, or the route is too short to chart: the panel's own line.
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
      final steep = elevation.climbAhead(pos ?? 0);
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
                child: LayoutBuilder(
                  builder: (context, line) {
                    // While the chunks are still coming and none holds a climb yet, no value (not "None", not a message).
                    final value = [
                      TextSpan(text: steep == null ? (elevation.loading ? ' ' : 'None') : '${(steep.grade * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (steep != null) TextSpan(text: ' for ${fmt.distance(steep.lengthM)}$where'),
                    ];
                    final label = TextSpan(text: 'Steepest climb ahead', style: TextStyle(color: k.secondary));
                    const base = TextStyle(fontSize: 14, height: 1.15);
                    // Where the box is wide (stacked under the mini map) the label and the figures share one line; where it is
                    // narrow they are two lines.
                    if (line.maxWidth >= 260) {
                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(TextSpan(style: TextStyle(color: k.text), children: [label, const TextSpan(text: '  '), ...value]), maxLines: 1, style: base),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text.rich(label, maxLines: 1, style: base)),
                        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text.rich(TextSpan(style: TextStyle(color: k.text), children: value), maxLines: 1, style: base)),
                      ],
                    );
                  },
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
              Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('Elevation', maxLines: 1, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: k.text)))),
              const SizedBox(width: 8),
              if (prof != null && prof.chartable) Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Whole route, ${routeLengthText(fmt, prof.totalM)}', maxLines: 1, style: TextStyle(fontSize: 13, color: k.secondary)))),
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
      if (pillFits(at, end, s)) _pill(canvas, at, s);
    }
    canvas.drawCircle(route.first, 5 * s, fill(colors['startDot']!));
    canvas.drawCircle(end, 6 * s, fill(colors['destDot']!));
    final here = driven.last;
    canvas.drawCircle(here, 8 * s, fill(colors['posFill']!));
    canvas.drawCircle(here, 8 * s, stroke(colors['posRing']!, 3 * s));
  }

  /// The car's rule (CarOverlayPainter.miniBadgeFits): the pill is left out when it would lie under the destination dot, which is
  /// where a climb at the end of the route puts it. The pill is 28 x 20, the dot's radius 6, and a gap of 2.
  static bool pillFits(Offset steep, Offset end, double s) => (steep.dx - end.dx).abs() >= (14 + 6 + 2) * s || (steep.dy - end.dy).abs() >= (10 + 6 + 2) * s;

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

/// The elevation box before the first chunk: dashed guide lines across it (where the chart will draw), no words.
class _EmptyChartPainter extends CustomPainter {
  _EmptyChartPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final f in const [0.15, 0.5, 0.85]) {
      final y = size.height * f;
      for (var x = 0.0; x < size.width; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, size.width), y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_EmptyChartPainter old) => old.color != color;
}

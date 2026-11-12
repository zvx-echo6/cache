import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../maps/palette/map_palette.dart';
import '../../theme.dart';
import '../elevation/elevation_profile.dart';
import '../elevation/route_elevation.dart';
import '../units.dart';

const double _ftPerM = 3.28084;
const double _mPerMile = 1609.344;

/// The least the chart's full height stands for: 330 ft (100 m), so a small rise or drop is drawn small, not as a hill. The car card's
/// rule (SHAPE_MIN_RISE_M in CarOverlayPainter.kt). The climb, descent, highest and lowest numbers are not changed by it.
const double kChartMinSpanM = 100.0;

String _group(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// A height on the elevation panel: "5,700 ft", "1,737 m".
String elevationText(Fmt fmt, double m) => fmt.units == UnitSystem.imperial ? '${_group((m * _ftPerM).round())} ft' : '${_group(m.round())} m';

/// A place along the route: "mile 8.6", "km 13.8".
String markerText(Fmt fmt, double m) =>
    fmt.units == UnitSystem.imperial ? 'mile ${(m / _mPerMile).toStringAsFixed(1)}' : 'km ${(m / 1000).toStringAsFixed(1)}';

/// The route's length to one decimal: "11.2 mi", "18.0 km".
String routeLengthText(Fmt fmt, double m) =>
    fmt.units == UnitSystem.imperial ? '${(m / _mPerMile).toStringAsFixed(1)} mi' : '${(m / 1000).toStringAsFixed(1)} km';

/// A "nice" step (1, 2, 2.5 or 5 times a power of ten; without 2.5 when [quarter] is false) nearest to [raw].
double niceStep(double raw, {bool quarter = true}) {
  if (raw <= 0 || raw.isNaN) return 1;
  final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  var best = p;
  for (final m in quarter ? const [1.0, 2.0, 2.5, 5.0, 10.0] : const [1.0, 2.0, 5.0, 10.0]) {
    if ((math.log(m * p) - math.log(raw)).abs() < (math.log(best) - math.log(raw)).abs()) best = m * p;
  }
  return best;
}

/// The heights the chart's full height covers, in the chart's unit, for a profile from [lo] to [hi]: its own range, or the [floor]
/// when that is less (then the profile sits in the middle), with room below and above for the labels. A route at or above 0 never gets
/// a window below 0.
@visibleForTesting
(double, double) chartWindow(double lo, double hi, {required double floor}) {
  final span = math.max(hi - lo, floor);
  final mid = (hi + lo) / 2;
  var yMin = mid - span / 2 - span * 0.28, yMax = mid + span / 2 + span * 0.18;
  if (lo >= 0 && yMin < 0) (yMax, yMin) = (yMax - yMin, 0);
  return (yMin, yMax);
}

/// The distance labels along the chart's foot (in the chart's own unit), as (distance, text). Enough decimals that no two read the
/// same: the step is 1, 2 or 5 times a power of ten, and it needs as many decimals as that power is small.
@visibleForTesting
List<(double, String)> distanceAxisLabels(double total, {required bool full}) {
  final step = niceStep(total / (full ? 5.5 : 2.2), quarter: false);
  final decimals = step >= 1 ? 0 : math.max(1, -(math.log(step) / math.ln10).floor());
  return [for (var i = 0; i * step <= total + 1e-9; i++) (i * step, (i * step).toStringAsFixed(decimals))];
}

/// The colours the chart draws with.
class ElevationChartColors {
  const ElevationChartColors({
    required this.route,
    required this.position,
    required this.text,
    required this.secondary,
    required this.surface,
    required this.warning,
  });

  factory ElevationChartColors.of(BuildContext context, MapPalette palette) {
    final k = context.t;
    return ElevationChartColors(
      route: palette['route'],
      position: palette['position'],
      text: k.text,
      secondary: k.secondary,
      surface: k.surface,
      warning: k.warning,
    );
  }

  final Color route;
  final Color position;
  final Color text;
  final Color secondary;
  final Color surface;
  final Color warning;
}

/// The elevation along the route. [full]: the guidance panel's chart (the position with "You are here", the highest and lowest
/// points, the steepest climb ahead); otherwise the preview's small one. Stretches with no data are left empty.
class ElevationChartPainter extends CustomPainter {
  ElevationChartPainter({
    required this.profile,
    required this.units,
    required this.colors,
    this.positionM,
    this.steep,
    this.full = true,
  });

  final ElevationProfile profile;
  final UnitSystem units;
  final ElevationChartColors colors;
  final double? positionM;
  final Climb? steep;
  final bool full;

  bool get _us => units == UnitSystem.imperial;
  double _h(double m) => _us ? m * _ftPerM : m;
  double _d(double m) => _us ? m / _mPerMile : m / 1000;

  TextPainter _text(String s, double size, Color color, {FontWeight weight = FontWeight.w400, Color? halo}) {
    final style = TextStyle(fontSize: size, color: color, fontWeight: weight, fontFamily: 'Roboto', height: 1.0);
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: halo == null
            ? style
            : style.copyWith(
                shadows: [for (final o in const [Offset(-1, 0), Offset(1, 0), Offset(0, -1), Offset(0, 1), Offset(1, 1), Offset(-1, -1), Offset(1, -1), Offset(-1, 1)]) Shadow(color: halo, offset: o * 1.2)],
              ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!profile.hasData) return;
    final pos = positionM;
    final l = full ? 44.0 : 40.0, r = 10.0, b = 20.0;
    final t = (pos != null && full) ? 24.0 : 8.0;
    final pw = size.width - l - r, ph = size.height - t - b;
    if (pw <= 0 || ph <= 0) return;

    var lo = double.infinity, hi = -double.infinity;
    for (final e in profile.elevM) {
      if (e.isNaN) continue;
      lo = math.min(lo, _h(e));
      hi = math.max(hi, _h(e));
    }
    final span = math.max(hi - lo, _h(kChartMinSpanM));
    final (yMin, yMax) = chartWindow(lo, hi, floor: _h(kChartMinSpanM));
    final total = _d(profile.totalM);
    double x(double m) => l + (total <= 0 ? 0 : _d(m) / total * pw);
    double y(double hm) => t + (yMax - _h(hm)) / (yMax - yMin) * ph;

    // Grid and height labels.
    final grid = Paint()
      ..color = colors.secondary.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    // The small chart labels every other line of the big one's.
    final gStep = niceStep(span / 2.2);
    var line = 0;
    for (var g = (yMin / gStep).ceil() * gStep; g <= yMax; g += gStep, line++) {
      if (!full && line.isOdd) continue;
      final gy = t + (yMax - g) / (yMax - yMin) * ph;
      for (var gx = l; gx < size.width - r; gx += 7) {
        canvas.drawLine(Offset(gx, gy), Offset(math.min(gx + 3, size.width - r), gy), grid);
      }
      final tp = _text(_group(g.round()), 11, colors.secondary);
      tp.paint(canvas, Offset(l - 6 - tp.width, gy - tp.height / 2));
    }

    // The line and the area under it, a stretch at a time; done (behind the position) and ahead apart.
    final bottom = t + ph;
    for (final (a, z) in profile.runs) {
      final pts = <Offset>[for (var i = a; i <= z; i++) Offset(x(profile.distM[i]), y(profile.elevM[i]))];
      if (pts.length == 1) pts.add(pts.first.translate(1, 0));
      final split = pos == null ? -1.0 : x(pos);
      final posY = pos == null ? null : profile.elevationAt(pos);
      List<Offset> part(bool behind) {
        final out = <Offset>[];
        for (final p in pts) {
          if (split < 0) {
            if (!behind) out.add(p);
          } else if (behind ? p.dx <= split : p.dx >= split) {
            out.add(p);
          }
        }
        if (split >= 0 && posY != null && split > pts.first.dx && split < pts.last.dx) {
          final sp = Offset(split, y(posY));
          if (behind) {
            out.add(sp);
          } else {
            out.insert(0, sp);
          }
        }
        return out;
      }

      void draw(List<Offset> ps, Color fill, Color stroke, double opacity) {
        if (ps.length < 2) return;
        final line = Path()..moveTo(ps.first.dx, ps.first.dy);
        for (final p in ps.skip(1)) {
          line.lineTo(p.dx, p.dy);
        }
        final area = Path.from(line)
          ..lineTo(ps.last.dx, bottom)
          ..lineTo(ps.first.dx, bottom)
          ..close();
        canvas.drawPath(area, Paint()..color = fill);
        canvas.drawPath(
            line,
            Paint()
              ..color = stroke.withValues(alpha: opacity)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round);
      }

      draw(part(true), colors.secondary.withValues(alpha: 0.14), colors.secondary, 0.8);
      draw(part(false), colors.route.withValues(alpha: 0.20), colors.route, 1);
    }

    // The steepest climb ahead.
    final s = steep;
    if (s != null) {
      final ps = <Offset>[];
      for (var m = s.startM; m <= s.endM + 0.1; m += math.max(10, (s.endM - s.startM) / 40)) {
        final e = profile.elevationAt(math.min(m, s.endM));
        if (e != null) ps.add(Offset(x(math.min(m, s.endM)), y(e)));
      }
      if (ps.length > 1) {
        final p = Path()..moveTo(ps.first.dx, ps.first.dy);
        for (final q in ps.skip(1)) {
          p.lineTo(q.dx, q.dy);
        }
        canvas.drawPath(
            p,
            Paint()
              ..color = colors.warning
              ..style = PaintingStyle.stroke
              ..strokeWidth = 5
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round);
      }
    }

    // Distance labels along the foot, and the unit.
    final unit = _text(_us ? 'mi' : 'km', 11, colors.secondary);
    final unitX = size.width - r - unit.width;
    unit.paint(canvas, Offset(unitX, size.height - 4 - unit.height + 2));
    for (final (v, label) in distanceAxisLabels(total, full: full)) {
      final tp = _text(label, 11, colors.secondary);
      final cx = l + (total <= 0 ? 0 : v / total * pw);
      if (cx + tp.width / 2 > unitX - 4 && v > 0) continue;
      tp.paint(canvas, Offset(cx - tp.width / 2, size.height - 4 - tp.height + 2));
    }

    if (full) {
      final dot = Paint()..color = colors.text;
      final ring = Paint()
        ..color = colors.surface
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final h = profile.highest, lw = profile.lowest;
      if (h != null) {
        final c = Offset(x(h.distM), y(h.elevM));
        canvas.drawCircle(c, 4.5, dot);
        canvas.drawCircle(c, 4.5, ring);
        final tp = _text(elevationText(Fmt(units), h.elevM), 11, colors.text, weight: FontWeight.w500, halo: colors.surface);
        tp.paint(canvas, Offset((c.dx - tp.width / 2).clamp(l, size.width - r - tp.width), c.dy - 9 - tp.height + 2));
      }
      if (lw != null) {
        final c = Offset(x(lw.distM), y(lw.elevM));
        canvas.drawCircle(c, 4.5, dot);
        canvas.drawCircle(c, 4.5, ring);
        final tp = _text(elevationText(Fmt(units), lw.elevM), 11, colors.text, weight: FontWeight.w500, halo: colors.surface);
        final left = c.dx - 9 - tp.width;
        tp.paint(canvas, Offset(left < l ? c.dx + 9 : left, c.dy - tp.height / 2));
      }
    }

    if (pos != null) {
      final px = x(pos);
      final e = profile.elevationAt(pos);
      canvas.drawLine(
          Offset(px, full ? t - 4 : t),
          Offset(px, bottom),
          Paint()
            ..color = colors.text.withValues(alpha: 0.55)
            ..strokeWidth = 1.2);
      if (e != null) {
        final c = Offset(px, y(e));
        canvas.drawCircle(c, 8, Paint()..color = colors.surface);
        canvas.drawCircle(
            c,
            8,
            Paint()
              ..color = colors.position
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
        canvas.drawCircle(c, 5, Paint()..color = colors.position);
      }
      if (full) {
        const cw = 82.0;
        final cx = px.clamp(l + cw / 2, size.width - r - cw / 2).toDouble();
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx - cw / 2, 2, cw, 18), const Radius.circular(9)), Paint()..color = colors.text);
        final tp = _text('You are here', 11, colors.surface, weight: FontWeight.w500);
        tp.paint(canvas, Offset(cx - tp.width / 2, 11 - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(ElevationChartPainter old) =>
      old.profile != profile || old.positionM != positionM || old.steep?.startM != steep?.startM || old.units != units || old.full != full || old.colors.route != colors.route || old.colors.text != colors.text;
}

/// The chart as a widget, as wide as it is given.
class ElevationChart extends StatelessWidget {
  const ElevationChart({super.key, required this.profile, required this.fmt, required this.palette, required this.height, this.positionM, this.steep, this.full = true});

  final ElevationProfile profile;
  final Fmt fmt;
  final MapPalette palette;
  final double height;
  final double? positionM;
  final Climb? steep;
  final bool full;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Elevation along the route',
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: ElevationChartPainter(
              profile: profile,
              units: fmt.units,
              colors: ElevationChartColors.of(context, palette),
              positionM: positionM,
              steep: steep,
              full: full,
            ),
          ),
        ),
      );
}

/// "No elevation data for 2.1 mi of this route": the line under a chart that has gaps.
String missingText(Fmt fmt, ElevationProfile p) => 'No elevation data for ${fmt.distance(p.missingM)} of this route';

/// The panel pulled up from the guidance card: climb and descent, the chart with the position, the highest and lowest points,
/// and the steepest climb ahead. With no data, one plain line.
class ElevationPanel extends StatelessWidget {
  const ElevationPanel({super.key, required this.elevation, required this.fmt, required this.palette, this.distanceAlongM, this.routeM = 0});

  final RouteElevation elevation;
  final Fmt fmt;
  final MapPalette palette;

  /// The core's metres along the route, and the route's length (to place the position on the profile).
  final double? distanceAlongM;
  final double routeM;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = elevation.profile;
    final header = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text('Elevation', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: k.text))),
          if (p != null && p.hasData) Text('Whole route, ${routeLengthText(fmt, p.totalM)}', style: TextStyle(fontSize: 13, color: k.secondary)),
        ],
      ),
    );
    final Widget body;
    if (p == null) {
      body = Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Row(
          children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: k.secondary)),
            const SizedBox(width: 10),
            Text('Reading the elevation', style: TextStyle(fontSize: 16, color: k.secondary)),
          ],
        ),
      );
    } else if (!p.hasData) {
      body = Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Row(
          key: const ValueKey('elevation-none'),
          children: [
            Icon(Icons.terrain, size: 22, color: k.secondary),
            const SizedBox(width: 10),
            Expanded(child: Text('No elevation data for this route.', style: TextStyle(fontSize: 16, color: k.secondary))),
          ],
        ),
      );
    } else {
      final pos = elevation.positionOnProfile(distanceAlongM, routeM);
      final steep = p.steepestClimbAhead(pos ?? 0);
      Widget stat(IconData icon, String big, String small) => Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: k.secondary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: k.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(big, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.1, color: k.text)),
                        Text(small, style: TextStyle(fontSize: 13, color: k.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
      // A fact: its key, its name and its value. The value keeps its full size when the row has room, and shrinks to fit (it
      // never runs off the card) when the text is large; the name gives way first only down to 40% of the row.
      Widget fact(Widget key, double keyWidth, String label, String value, String rest, {Key? rowKey}) {
        final labelStyle = TextStyle(fontSize: 14, color: k.secondary);
        final valueText = Text.rich(
          TextSpan(children: [
            TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: rest),
          ]),
          maxLines: 1,
          style: TextStyle(fontSize: 14, color: k.text),
        );
        return SizedBox(
          key: rowKey,
          height: 32,
          child: LayoutBuilder(builder: (context, box) {
            final labelWidth = (TextPainter(
              text: TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(labelStyle)),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
            )..layout())
                .width;
            final room = box.maxWidth - keyWidth - 16 - math.min(labelWidth, box.maxWidth * 0.4);
            return Row(
              children: [
                key,
                const SizedBox(width: 8),
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle)),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: math.max(0, room)),
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: valueText),
                ),
              ],
            );
          }),
        );
      }

      final dotKey = Container(width: 9, height: 9, decoration: BoxDecoration(color: k.text, shape: BoxShape.circle));
      final steepKey = Container(width: 16, height: 5, decoration: BoxDecoration(color: k.warning, borderRadius: BorderRadius.circular(3)));
      final where = steep == null ? '' : (pos == null || steep.startM - pos < 1 ? ', starts here' : ', in ${fmt.distance(steep.startM - pos)}');
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              stat(Icons.arrow_upward, elevationText(fmt, p.climbM), 'Climb'),
              const SizedBox(width: 12),
              stat(Icons.arrow_downward, elevationText(fmt, p.descentM), 'Descent'),
            ],
          ),
          const SizedBox(height: 6),
          ElevationChart(key: const ValueKey('elevation-chart'), profile: p, fmt: fmt, palette: palette, height: 142, positionM: pos, steep: steep),
          if (p.partial)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(missingText(fmt, p), key: const ValueKey('elevation-missing'), style: TextStyle(fontSize: 13, color: k.secondary)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Column(
              children: [
                if (p.highest case final h?) fact(dotKey, 9, 'Highest', elevationText(fmt, h.elevM), ' at ${markerText(fmt, h.distM)}'),
                if (p.lowest case final lw?) fact(dotKey, 9, 'Lowest', elevationText(fmt, lw.elevM), ' at ${markerText(fmt, lw.distM)}'),
                if (steep != null)
                  fact(steepKey, 16, 'Steepest climb ahead', '${(steep.grade * 100).round()}%', ' for ${fmt.distance(steep.lengthM)}$where', rowKey: const ValueKey('elevation-steep'))
                else
                  fact(steepKey, 16, 'Steepest climb ahead', '', 'None', rowKey: const ValueKey('elevation-steep')),
              ],
            ),
          ),
        ],
      );
    }
    return Container(
      key: const ValueKey('elevation-panel'),
      padding: EdgeInsets.fromLTRB(16, 12, 16, p != null && !p.hasData ? 14 : 4),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.22)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [header, body]),
    );
  }
}

/// The handle at the top of the guidance card: tap it or pull it up for the elevation panel, down to put it away.
class ElevationHandle extends StatelessWidget {
  const ElevationHandle({super.key, required this.elevation});

  final RouteElevation elevation;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final open = elevation.open;
    return Semantics(
      button: true,
      label: open ? 'Hide the elevation' : 'Show the elevation',
      child: GestureDetector(
        key: const ValueKey('elevation-handle'),
        behavior: HitTestBehavior.opaque,
        onTap: elevation.toggle,
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -50) elevation.setOpen(true);
          if (v > 50) elevation.setOpen(false);
        },
        child: SizedBox(
          height: 22,
          width: double.infinity,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(top: 0, child: Icon(open ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 20, color: k.secondary)),
              Positioned(
                bottom: 3,
                child: Container(width: 36, height: 4, decoration: BoxDecoration(color: k.secondary.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(2))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The preview's elevation: climb and descent, the small chart, and the highest and lowest points.
class RouteElevationSummary extends StatelessWidget {
  const RouteElevationSummary({super.key, required this.elevation, required this.fmt, required this.palette});

  final RouteElevation elevation;
  final Fmt fmt;
  final MapPalette palette;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = elevation.profile;
    final head = <Widget>[Expanded(child: Text('Elevation', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.secondary)))];
    final children = <Widget>[];
    if (p == null) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('Reading the elevation', style: TextStyle(fontSize: 14, color: k.secondary)),
      ));
    } else if (!p.hasData) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('No elevation data for this route.', key: const ValueKey('preview-elevation-none'), style: TextStyle(fontSize: 14, color: k.secondary)),
      ));
    } else {
      final total = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: k.text);
      head.add(Flexible(
        flex: 2,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward, size: 16, color: k.accent),
              const SizedBox(width: 3),
              Text(elevationText(fmt, p.climbM), style: total),
              const SizedBox(width: 10),
              Icon(Icons.arrow_downward, size: 16, color: k.accent),
              const SizedBox(width: 3),
              Text(elevationText(fmt, p.descentM), style: total),
            ],
          ),
        ),
      ));
      children
        ..add(ElevationChart(key: const ValueKey('preview-elevation-chart'), profile: p, fmt: fmt, palette: palette, height: 92, full: false))
        ..add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // Both labels in full: apart when the row has room, one under the other when it has not (large text on a narrow phone).
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 2,
            children: [
              if (p.highest case final h?) Text('Highest ${elevationText(fmt, h.elevM)}', style: TextStyle(fontSize: 13, color: k.secondary)),
              if (p.lowest case final lw?) Text('Lowest ${elevationText(fmt, lw.elevM)}', style: TextStyle(fontSize: 13, color: k.secondary)),
            ],
          ),
        ));
      if (p.partial) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(missingText(fmt, p), key: const ValueKey('preview-elevation-missing'), style: TextStyle(fontSize: 13, color: k.secondary)),
        ));
      }
    }
    return Container(
      key: const ValueKey('preview-elevation'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(border: Border.all(color: k.secondary.withValues(alpha: 0.35)), borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [Row(children: head), ...children],
      ),
    );
  }
}

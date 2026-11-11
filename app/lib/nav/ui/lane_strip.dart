import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';

/// How a lane is drawn: the lane to be in, another lane that works, one that does not, or (when the road gave no hint of which
/// lanes work) every lane alike.
/// How much of the text colour a lane that does not work keeps.
const double laneDimAlpha = 0.38;

/// The arrow colour of a lane that also works: the secondary tone, except in Tactical, where that is nearly the dimmed lanes'
/// dark red, so it takes the full text colour.
Color laneValidColor(CacheTokens k) => k.monoLight != null ? k.text : k.secondary;

/// The arrow colour of a lane that does not work: the text colour, 38% over the surface, opaque (a see-through arrow shows its
/// stem under its head).
Color laneDimColor(CacheTokens k) => Color.alphaBlend(k.text.withValues(alpha: laneDimAlpha), k.surface);

enum LaneRole { active, valid, dim, plain }

/// One arrow of a lane and its colour.
class LaneArrow {
  const LaneArrow(this.direction, this.color);
  final LaneDirection direction;
  final Color color;
}

/// The directions to draw for [lane]: its own, with "none" (unmarked) left out. An unmarked lane, or one with no
/// directions, is a plain straight arrow.
List<LaneDirection> laneGlyphDirections(Lane lane) {
  final d = {for (final x in lane.directions) if (x != LaneDirection.none) x};
  if (d.isEmpty) d.add(LaneDirection.through);
  return d.toList();
}

LaneRole laneRole(Lane lane, {required bool anyMarked}) {
  if (lane.active != null) return LaneRole.active;
  if (lane.valid != null) return LaneRole.valid;
  return anyMarked ? LaneRole.dim : LaneRole.plain;
}

/// 1 -> "1st", 2 -> "2nd", 3 -> "3rd", 4 -> "4th", 11 -> "11th", 21 -> "21st".
String laneOrdinal(int n) {
  final r = n % 100;
  if (r >= 11 && r <= 13) return '${n}th';
  return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' };
}

/// The lanes to use, as words for a screen reader, built from the lanes that work (the one to be in and any other that also
/// works). A group touching an edge is "keep left" (one lane) or "use the 2 left lanes"; one lane in the exact middle of an odd
/// count is "use the middle lane"; any other lane or group is counted from the nearer edge, left on a tie ("use the 2nd or 3rd
/// lane from the left"); every lane, or none marked, is "use any lane".
String laneLabel(List<Lane> lanes) {
  final n = lanes.length;
  final use = [for (var i = 0; i < n; i++) if (lanes[i].active != null || lanes[i].valid != null) i];
  final c = use.length;
  if (c == 0 || c == n) return 'Lanes: use any lane';
  final together = use.last - use.first == c - 1;
  if (together && use.first == 0) return c == 1 ? 'Lanes: keep left' : 'Lanes: use the $c left lanes';
  if (together && use.last == n - 1) return c == 1 ? 'Lanes: keep right' : 'Lanes: use the $c right lanes';
  if (c == 1 && n.isOdd && use.first == n ~/ 2) return 'Lanes: use the middle lane';
  final fromLeft = use.first <= n - 1 - use.last;
  final nums = [for (final i in fromLeft ? use : use.reversed) laneOrdinal(fromLeft ? i + 1 : n - i)];
  final list = nums.length == 1 ? nums.first : '${nums.sublist(0, nums.length - 1).join(', ')} or ${nums.last}';
  return 'Lanes: use the $list lane from the ${fromLeft ? 'left' : 'right'}';
}

/// The row of lane arrows under the turn banner: one glyph per lane, the lane to be in lit, the others that work in the
/// secondary tone, the rest dimmed. Scales down to fit the width (no scrolling).
class LaneStrip extends StatelessWidget {
  const LaneStrip({super.key, required this.lanes});

  final List<Lane> lanes;

  static const double maxCell = 40;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final anyMarked = lanes.any((l) => l.active != null || l.valid != null);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: laneLabel(lanes),
      child: LayoutBuilder(
        builder: (context, box) {
          final n = lanes.length;
          final room = box.maxWidth.isFinite ? box.maxWidth : maxCell * n;
          final cell = math.max(8.0, math.min(maxCell, (room - (n - 1)) / n));
          final glyph = math.max(6.0, cell - 6);
          return Center(
            child: Row(
              key: const ValueKey('lane-strip'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0 && lanes[i].active == null && lanes[i - 1].active == null) Container(width: 1, height: glyph * 0.8, color: k.secondary.withValues(alpha: 0.35)),
                  if (i > 0 && (lanes[i].active != null || lanes[i - 1].active != null)) const SizedBox(width: 1),
                  _cell(k, i, cell, glyph, anyMarked),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _cell(CacheTokens k, int i, double cell, double glyph, bool anyMarked) {
    final lane = lanes[i];
    final role = laneRole(lane, anyMarked: anyMarked);
    final dirs = laneGlyphDirections(lane);
    final base = switch (role) {
      LaneRole.active => k.secondary,
      LaneRole.valid => laneValidColor(k),
      LaneRole.dim => laneDimColor(k),
      LaneRole.plain => k.text,
    };
    final lit = lane.active == null || lane.active == LaneDirection.none ? LaneDirection.through : lane.active!;
    final arrows = [
      for (final d in dirs) if (role != LaneRole.active || d != lit) LaneArrow(d, base),
      if (role == LaneRole.active) LaneArrow(lit, k.accent),
    ];
    return Container(
      key: ValueKey('lane-$i'),
      width: cell,
      height: glyph + 6,
      alignment: Alignment.center,
      decoration: role == LaneRole.active ? BoxDecoration(color: k.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)) : null,
      child: CustomPaint(key: ValueKey('lane-glyph-$i'), size: Size.square(glyph), painter: LaneGlyphPainter(arrows, role)),
    );
  }
}

/// The arrows of one lane, drawn as vectors in a unit square: a stem from the foot, bending to each direction's way, with a
/// head. Arrows drawn later sit over earlier ones, so the one to take is last.
class LaneGlyphPainter extends CustomPainter {
  const LaneGlyphPainter(this.arrows, this.role);

  final List<LaneArrow> arrows;
  final LaneRole role;

  static const double _w = 0.12;
  static const double _bend = 0.6;

  /// Degrees clockwise from straight up, for the directions that turn.
  static double? _angle(LaneDirection d) => switch (d) {
        LaneDirection.sharpLeft => -135,
        LaneDirection.left => -90,
        LaneDirection.slightLeft => -45,
        LaneDirection.slightRight => 45,
        LaneDirection.right => 90,
        LaneDirection.sharpRight => 135,
        _ => null,
      };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width, size.height);
    for (final a in arrows) {
      final line = Paint()
        ..color = a.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _w
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final fill = Paint()..color = a.color;
      _arrow(canvas, a.direction, line, fill);
    }
    canvas.restore();
  }

  void _head(Canvas canvas, Offset tip, double deg, Paint fill) {
    final t = deg * math.pi / 180;
    final dir = Offset(math.sin(t), -math.cos(t));
    final perp = Offset(math.cos(t), math.sin(t));
    final base = tip - dir * 0.3;
    canvas.drawPath(Path()..moveTo(tip.dx, tip.dy)..lineTo((base + perp * 0.21).dx, (base + perp * 0.21).dy)..lineTo((base - perp * 0.21).dx, (base - perp * 0.21).dy)..close(), fill);
  }

  void _arrow(Canvas canvas, LaneDirection d, Paint line, Paint fill) {
    switch (d) {
      case LaneDirection.reverse:
        final p = Path()
          ..moveTo(0.68, 0.97)
          ..lineTo(0.68, 0.38)
          ..arcTo(Rect.fromCircle(center: const Offset(0.5, 0.38), radius: 0.18), 0, -math.pi, false)
          ..lineTo(0.32, 0.56);
        canvas.drawPath(p, line);
        _head(canvas, const Offset(0.32, 0.88), 180, fill);
      case LaneDirection.mergeToLeft || LaneDirection.mergeToRight:
        final m = d == LaneDirection.mergeToRight ? -1.0 : 1.0;
        double x(double v) => 0.5 + (v - 0.5) * m;
        final p = Path()
          ..moveTo(x(0.66), 0.97)
          ..lineTo(x(0.66), 0.7)
          ..cubicTo(x(0.66), 0.52, x(0.34), 0.56, x(0.34), 0.4)
          ..lineTo(x(0.34), 0.3);
        canvas.drawPath(p, line);
        _head(canvas, Offset(x(0.34), 0.04), 0, fill);
      default:
        final deg = _angle(d);
        if (deg == null) {
          canvas.drawLine(const Offset(0.5, 0.97), const Offset(0.5, 0.26), line);
          _head(canvas, const Offset(0.5, 0.03), 0, fill);
          return;
        }
        final t = deg * math.pi / 180;
        final dir = Offset(math.sin(t), -math.cos(t));
        // A sharp turn bends higher up, so its arm is long enough to read.
        final b = Offset(0.5, deg.abs() > 90 ? 0.4 : _bend);
        final tip = b + dir * 0.38;
        final end = tip - dir * 0.24;
        final p = Path()
          ..moveTo(0.5, 0.97)
          ..lineTo(0.5, b.dy + 0.1)
          ..quadraticBezierTo(b.dx, b.dy, (b + dir * 0.1).dx, (b + dir * 0.1).dy)
          ..lineTo(end.dx, end.dy);
        canvas.drawPath(p, line);
        _head(canvas, tip, deg, fill);
    }
  }

  @override
  bool shouldRepaint(LaneGlyphPainter old) => old.role != role || old.arrows.length != arrows.length || [for (var i = 0; i < arrows.length; i++) if (old.arrows[i].direction != arrows[i].direction || old.arrows[i].color != arrows[i].color) i].isNotEmpty;
}

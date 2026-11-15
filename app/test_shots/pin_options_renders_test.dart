// Sharper map pin options for review (pictures only, nothing in the app changes): A slim needle teardrop, B faceted hex-head spike,
// C push-pin. Each sheet has Light, Dark, Tactical bands: today's pin, then the option at 30 pt (a group, one selected, one at 2x).
// flutter test test_shots/pin_options_renders_test.dart --update-goldens  (pictures in test_shots/pin_options/)

import 'dart:math' as math;

import 'package:cache/maps/palette/map_palette.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const double _bandH = 190;
const double _pointY = 150;

TextPainter _icon(IconData i, double fs, Color c) => TextPainter(
      text: TextSpan(text: String.fromCharCode(i.codePoint), style: TextStyle(fontFamily: i.fontFamily, package: i.fontPackage, fontSize: fs, color: c)),
      textDirection: TextDirection.ltr,
    )..layout();

void _glyphAt(Canvas c, Offset ctr, IconData? i, double fs, Color col) {
  if (i == null) {
    c.drawCircle(ctr, fs * 0.16, Paint()..color = col);
    return;
  }
  final tp = _icon(i, fs, col);
  tp.paint(c, ctr - Offset(tp.width / 2, tp.height / 2));
}

Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeJoin = StrokeJoin.miter
  ..strokeMiterLimit = 20;

/// Fill, thin ring, dark edge: the same palette as today's pin (Tactical: dark fill, red ring, black edge).
void _shape(Canvas c, Path p, Color fill, Color ring, Color edge, double s) {
  c.drawPath(p, _stroke(edge, s * 0.1));
  c.drawPath(p, _stroke(ring, s * 0.045));
  c.drawPath(p, Paint()..color = fill);
}

void _opt(Canvas c, String o, Offset at, double s, IconData? icon, Color tint, bool tac) {
  final edge = tac ? const Color(0xFF000000) : const Color(0xE6000000);
  final fill = tac ? const Color(0xFF160505) : tint;
  final ring = tac ? tint : const Color(0xFFFFFFFF);
  final gc = tac ? tint : glyphOn(tint);
  c.save();
  c.translate(at.dx, at.dy);
  switch (o) {
    case 'A':
      final r = s * 0.4, d = s * 1.3, cy = -d;
      final th = math.acos(r / d);
      final tl = Offset(-r * math.sin(th), cy + r * math.cos(th));
      final tr = Offset(r * math.sin(th), cy + r * math.cos(th));
      final p = Path()
        ..moveTo(0, 0)
        ..lineTo(tl.dx, tl.dy)
        ..arcToPoint(tr, radius: Radius.circular(r), largeArc: true, clockwise: true)
        ..close();
      _shape(c, p, fill, ring, edge, s);
      _glyphAt(c, Offset(0, cy), icon, r * 1.2, gc);
    case 'B':
      final R = s * 0.5, cy = -s * 1.0, k = R * 0.866;
      final p = Path()
        ..moveTo(0, cy - R)
        ..lineTo(k, cy - R / 2)
        ..lineTo(k, cy + R / 2)
        ..lineTo(0, 0)
        ..lineTo(-k, cy + R / 2)
        ..lineTo(-k, cy - R / 2)
        ..close();
      _shape(c, p, fill, ring, edge, s);
      c.save();
      c.clipPath(p);
      c.drawPath(Path()..moveTo(0, cy - R)..lineTo(k, cy - R / 2)..lineTo(k, cy + R / 2)..lineTo(0, 0)..lineTo(0, cy - R)..close(), Paint()..color = const Color(0x33000000));
      c.drawPath(Path()..moveTo(0, cy - R)..lineTo(-k, cy - R / 2)..lineTo(-k, cy - R / 2 + R * 0.5)..lineTo(0, cy - R * 0.1)..close(), Paint()..color = const Color(0x22FFFFFF));
      c.restore();
      c.drawPath(p, _stroke(ring, s * 0.045));
      _glyphAt(c, Offset(0, cy), icon, R * 0.95, gc);
    case 'C':
      final steel = tac ? tint : const Color(0xFFB9BFC6);
      final needle = Path()..moveTo(0, 0)..lineTo(-s * 0.05, -s * 0.55)..lineTo(s * 0.05, -s * 0.55)..close();
      _shape(c, needle, steel, ring, edge, s * 0.7);
      final collar = Path()..moveTo(-s * 0.2, -s * 0.52)..lineTo(s * 0.2, -s * 0.52)..lineTo(s * 0.3, -s * 0.78)..lineTo(-s * 0.3, -s * 0.78)..close();
      _shape(c, collar, tac ? const Color(0xFF2A0808) : Color.lerp(tint, const Color(0xFF000000), 0.35)!, ring, edge, s * 0.8);
      final w = s * 0.46, top = -s * 1.55, bot = -s * 0.78, ch = s * 0.16;
      final head = Path()
        ..moveTo(-w + ch, top)
        ..lineTo(w - ch, top)
        ..lineTo(w, top + ch)
        ..lineTo(w, bot - ch)
        ..lineTo(w - ch, bot)
        ..lineTo(-w + ch, bot)
        ..lineTo(-w, bot - ch)
        ..lineTo(-w, top + ch)
        ..close();
      _shape(c, head, fill, ring, edge, s);
      _glyphAt(c, Offset(0, (top + bot) / 2), icon, s * 0.6, gc);
  }
  c.restore();
}

class _Sheet extends CustomPainter {
  _Sheet(this.o);
  final String o;

  @override
  void paint(Canvas canvas, Size size) {
    final themes = [(CacheThemeId.light, 'Light'), (CacheThemeId.dark, 'Dark'), (CacheThemeId.tactical, 'Tactical')];
    final red = cacheTokens[CacheThemeId.tactical]!.accent;
    final group = <(double, double, IconData?, String)>[
      (74, 146, Icons.water_drop, 'teal'),
      (92, 137, null, 'purple'),
      (108, 150, Icons.local_gas_station, 'blue'),
      (126, 141, null, 'teal'),
      (143, 148, Icons.warning, 'orange'),
    ];
    for (var b = 0; b < 3; b++) {
      final (id, name) = themes[b];
      final tac = id == CacheThemeId.tactical;
      final p = mapPaletteFor(id);
      canvas.save();
      canvas.translate(0, b * _bandH);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, _bandH), Paint()..color = p['land']);
      void cap(String t, double x, double y) {
        final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(fontFamily: 'Roboto', fontSize: 11, fontWeight: FontWeight.w600, color: p['labelPlace'])), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(x, y));
      }

      cap('$name  -  Today | $o', 10, 8);
      Color tint(String n) => tac ? red : markerColor(n).color;
      cap('Today', 14, _pointY + 8);
      paintMapPin(canvas, Offset(28, _pointY), 30, Icons.water_drop, tint('teal'), PinStyle.teardrop, tactical: tac);
      cap('30 pt group', 70, _pointY + 8);
      for (final (x, y, i, c) in group) {
        _opt(canvas, o, Offset(x, y), 30, i, tint(c), tac);
      }
      // selected: larger, raised, with a ground ring at the point
      final sel = Offset(205, _pointY);
      canvas.drawOval(Rect.fromCenter(center: sel, width: 26, height: 9), _stroke(tac ? red : const Color(0xFF111111), 1.6));
      _opt(canvas, o, sel + const Offset(0, -6), 40, Icons.water_drop, tint('teal'), tac);
      cap('Selected', 185, _pointY + 14);
      cap('2x zoom', 280, _pointY + 8);
      _opt(canvas, o, const Offset(310, _pointY), 60, Icons.local_hospital, tint('blue'), tac);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

void main() {
  setUpAll(loadShotFonts);
  for (final o in ['A', 'B', 'C']) {
    testWidgets('pin option $o', (tester) async {
      phone(tester, size: Size(390, _bandH * 3), ratio: 3);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(key: const ValueKey('sheet'), child: CustomPaint(painter: _Sheet(o), size: Size(390, _bandH * 3))),
      ));
      await tester.pump();
      await expectLater(find.byKey(const ValueKey('sheet')), matchesGoldenFile('pin_options/option-$o.png'));
    });
  }
}

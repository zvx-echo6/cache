import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;

/// The three pin styles under review. Not chosen yet; the owner picks one.
enum PinStyle {
  /// A: the icon itself in the colour, with a white halo (and a thin dark edge) so it reads on any map.
  halo,

  /// B: a teardrop map pin in the colour, carrying the icon; its point is the place.
  teardrop,

  /// C: a rounded-square badge in the colour, carrying the icon.
  badge,
}

/// The icon's colour on a shape of [c]: near-black on a light colour, white on a dark one.
Color glyphOn(Color c) => c.computeLuminance() > 0.38 ? const Color(0xFF111111) : const Color(0xFFFFFFFF);

TextPainter _glyph(IconData icon, double fontSize, {Color? color, Paint? foreground}) {
  return TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        fontSize: fontSize,
        color: foreground == null ? color : null,
        foreground: foreground,
        // Material Symbols are variable: filled and a little heavier read better at map sizes (other fonts ignore these).
        fontVariations: const [FontVariation('FILL', 1), FontVariation('wght', 600), FontVariation('opsz', 24)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

void _paintGlyph(Canvas canvas, Offset centre, TextPainter tp) => tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));

/// A map pin of [size] points in [style]: [at] is the place (the centre; for the teardrop, its point). [casing] is the thin edge
/// colour, a dark one that separates the pin from a light map.
void paintMapPin(Canvas canvas, Offset at, double size, IconData icon, Color tint, PinStyle style) {
  const white = Color(0xFFFFFFFF);
  const edge = Color(0xB3000000);
  switch (style) {
    case PinStyle.halo:
      final fs = size * 1.0;
      for (final (w, c) in [(size * 0.3, edge), (size * 0.2, white)]) {
        _paintGlyph(canvas, at, _glyph(icon, fs, foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = w..strokeJoin = StrokeJoin.round..color = c));
      }
      _paintGlyph(canvas, at, _glyph(icon, fs, color: tint));
    case PinStyle.teardrop:
      final r = size * 0.5;
      final c = at + Offset(0, -size * 0.95);
      Path drop(double grow) {
        final rr = r + grow;
        final k = rr * 1.0;
        return Path()
          ..moveTo(at.dx, at.dy + grow * 1.2)
          ..cubicTo(at.dx - rr * 0.35, at.dy - size * 0.35, c.dx - rr, c.dy + rr * 0.5, c.dx - rr, c.dy)
          ..arcToPoint(Offset(c.dx + rr, c.dy), radius: Radius.circular(k), clockwise: true)
          ..cubicTo(c.dx + rr, c.dy + rr * 0.5, at.dx + rr * 0.35, at.dy - size * 0.35, at.dx, at.dy + grow * 1.2)
          ..close();
      }
      canvas.drawPath(drop(size * 0.1), Paint()..color = edge);
      canvas.drawPath(drop(size * 0.05), Paint()..color = white);
      canvas.drawPath(drop(0), Paint()..color = tint);
      _paintGlyph(canvas, c, _glyph(icon, size * 0.52, color: glyphOn(tint)));
    case PinStyle.badge:
      final rect = Rect.fromCenter(center: at, width: size, height: size);
      RRect rr(double grow) => RRect.fromRectAndRadius(rect.inflate(grow), Radius.circular(size * 0.26 + grow));
      canvas.drawRRect(rr(size * 0.1), Paint()..color = edge);
      canvas.drawRRect(rr(size * 0.05), Paint()..color = white);
      canvas.drawRRect(rr(0), Paint()..color = tint);
      _paintGlyph(canvas, at, _glyph(icon, size * 0.64, color: glyphOn(tint)));
  }
}

/// The image's name in the map style: one per style, icon and colour.
String pinImageId(PinStyle style, String iconId, Color tint) => 'pin-${style.name}-$iconId-${(tint.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The pin as PNG bytes in a square of [size] points at [ratio] pixels per point (room for the edge, the teardrop's point at the
/// bottom middle), for `addImage` with the anchor at the bottom for the teardrop and the centre for the others.
Future<Uint8List> renderPinPng(IconData icon, Color tint, PinStyle style, {double size = 30, double ratio = 3}) async {
  final box = size * 1.5;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintMapPin(c, style == PinStyle.teardrop ? Offset(box / 2, box - size * 0.15) : Offset(box / 2, box / 2), size, icon, tint, style);
  final img = await rec.endRecording().toImage((box * ratio).round(), (box * ratio).round());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Which pin images the map style already has, so each style, icon and colour is drawn and added once ([add] is the style's
/// `addImage`). A new style (a theme change drops the images) is a new cache: call [reset].
class PinImages {
  PinImages(this.add, this.style);

  final Future<void> Function(String name, Uint8List png) add;
  final PinStyle style;
  final Set<String> _have = {};

  /// The image name for [iconId] in [tint], added on first use.
  Future<String> ensure(String iconId, IconData icon, Color tint) async {
    final name = pinImageId(style, iconId, tint);
    if (_have.add(name)) await add(name, await renderPinPng(icon, tint, style));
    return name;
  }

  void reset() => _have.clear();
}

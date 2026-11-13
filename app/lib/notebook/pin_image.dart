import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;

/// The three pin styles (Maps settings > Pin style), per device.
enum PinStyle {
  /// Icon: the icon itself in the colour, with a halo so it reads on any map. The default.
  icon('Icon', 'The icon itself, with a halo'),

  /// Teardrop: a map-pin shape in the colour, carrying the icon; its point is the place.
  teardrop('Teardrop', 'A map pin carrying the icon'),

  /// Badge: a rounded square in the colour, carrying the icon.
  badge('Badge', 'A rounded square carrying the icon');

  const PinStyle(this.label, this.hint);

  final String label;
  final String hint;

  /// The name kept in the settings file; an unknown name is the default.
  static PinStyle byName(Object? n) => PinStyle.values.firstWhere((s) => s.name == n, orElse: () => PinStyle.icon);
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

/// A map pin of [size] points in [style]: [at] is the place (the centre; for the teardrop, its point). On the light and dark
/// themes the shape or halo is white with a dark edge and the shape is filled with [tint]. In [tactical] (red only) there is no
/// white: the halo and the inner fill are dark, and the glyph, the shape's ring and the icon are [tint] (the theme's red).
void paintMapPin(Canvas canvas, Offset at, double size, IconData icon, Color tint, PinStyle style, {bool tactical = false}) {
  final halo = tactical ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  final edge = tactical ? const Color(0xFF000000) : const Color(0xB3000000);
  final fill = tactical ? const Color(0xFF160505) : tint;
  final ring = tactical ? tint : const Color(0xFFFFFFFF);
  final glyphColor = tactical ? tint : glyphOn(tint);
  final ringGrow = size * (tactical ? 0.08 : 0.05);
  switch (style) {
    case PinStyle.icon:
      final fs = size * 1.0;
      for (final (w, c) in [(size * 0.3, edge), (size * 0.2, halo)]) {
        _paintGlyph(canvas, at, _glyph(icon, fs, foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = w..strokeJoin = StrokeJoin.round..color = c));
      }
      _paintGlyph(canvas, at, _glyph(icon, fs, color: tint));
    case PinStyle.teardrop:
      final r = size * 0.5;
      final c = at + Offset(0, -size * 0.95);
      Path drop(double grow) {
        final rr = r + grow;
        return Path()
          ..moveTo(at.dx, at.dy + grow * 1.2)
          ..cubicTo(at.dx - rr * 0.35, at.dy - size * 0.35, c.dx - rr, c.dy + rr * 0.5, c.dx - rr, c.dy)
          ..arcToPoint(Offset(c.dx + rr, c.dy), radius: Radius.circular(rr), clockwise: true)
          ..cubicTo(c.dx + rr, c.dy + rr * 0.5, at.dx + rr * 0.35, at.dy - size * 0.35, at.dx, at.dy + grow * 1.2)
          ..close();
      }
      canvas.drawPath(drop(ringGrow + size * 0.05), Paint()..color = edge);
      canvas.drawPath(drop(ringGrow), Paint()..color = ring);
      canvas.drawPath(drop(0), Paint()..color = fill);
      _paintGlyph(canvas, c, _glyph(icon, size * 0.52, color: glyphColor));
    case PinStyle.badge:
      final rect = Rect.fromCenter(center: at, width: size, height: size);
      RRect rr(double grow) => RRect.fromRectAndRadius(rect.inflate(grow), Radius.circular(size * 0.26 + grow));
      canvas.drawRRect(rr(ringGrow + size * 0.05), Paint()..color = edge);
      canvas.drawRRect(rr(ringGrow), Paint()..color = ring);
      canvas.drawRRect(rr(0), Paint()..color = fill);
      _paintGlyph(canvas, at, _glyph(icon, size * 0.64, color: glyphColor));
  }
}

/// The image's name in the map style: one per style, icon and colour.
String pinImageId(PinStyle style, String iconId, Color tint, {bool tactical = false}) =>
    'pin-${style.name}${tactical ? '-t' : ''}-$iconId-${(tint.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

// How big the map draws a pin. A pin is 30 points ([renderPinPng]), in an image half as wide again. The map does not take an
// added image the same way everywhere, so the pixels the image is drawn at and the size its symbol layer draws it at go together:
// - A phone (MapLibre on Android and iOS, through the map plugin's addImage): the map reads an added image at the screen's own
//   scale, its pixels divided by the screen's pixels per point. The image is drawn at that scale and the layer draws it as it is.
// - A browser (MapLibre GL JS, through the web plugin): one pixel of an added image is one point. The image is drawn at
//   [kPinImageRatio] pixels per point and the layer draws it that much smaller.
// (Every image used to be drawn at 3 pixels per point and shown at a third: right in a browser, a third of the size on a 3x phone.)

/// Pixels per point of the pin images in a browser, where the symbol layers draw them this much smaller.
const double kPinImageRatio = 3;

/// Pixels per point the pin images are drawn at for a screen of [devicePixelRatio] pixels per point ([web]: in a browser).
double pinImageRatio(double devicePixelRatio, {bool web = kIsWeb}) => web ? kPinImageRatio : devicePixelRatio;

/// The `icon-size` of the symbol layers that draw the pin images ([web]: in a browser).
double pinIconSize({bool web = kIsWeb}) => web ? 1 / kPinImageRatio : 1;

/// The pin as PNG bytes in a square of [size] points at [ratio] pixels per point (room for the edge, the teardrop's point at the
/// bottom middle), for `addImage` with the anchor at the bottom for the teardrop and the centre for the others.
Future<Uint8List> renderPinPng(IconData icon, Color tint, PinStyle style, {double size = 30, double ratio = 3, bool tactical = false}) async {
  final box = size * 1.5;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintMapPin(c, style == PinStyle.teardrop ? Offset(box / 2, box - size * (tactical ? 0.2 : 0.17)) : Offset(box / 2, box / 2), size, icon, tint, style, tactical: tactical);
  final img = await rec.endRecording().toImage((box * ratio).round(), (box * ratio).round());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Which pin images the map style already has, so each style, icon and colour is drawn and added once ([add] is the style's
/// `addImage`). A new style (a theme change drops the images) is a new cache: call [reset].
class PinImages {
  PinImages(this.add, this.style, {this.tactical = false, required this.ratio});

  final Future<void> Function(String name, Uint8List png) add;
  final PinStyle style;
  final bool tactical;

  /// Pixels per point the images are drawn at: [pinImageRatio] of the screen the map is on.
  final double ratio;
  final Set<String> _have = {};

  /// The image name for [iconId] in [tint], added on first use.
  Future<String> ensure(String iconId, IconData icon, Color tint) async {
    final name = pinImageId(style, iconId, tint, tactical: tactical);
    if (_have.add(name)) await add(name, await renderPinPng(icon, tint, style, ratio: ratio, tactical: tactical));
    return name;
  }

  void reset() => _have.clear();
}

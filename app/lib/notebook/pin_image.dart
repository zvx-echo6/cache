import 'dart:math' as math;
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

double _ringGrow(double size, bool tactical) => size * (tactical ? 0.08 : 0.05);

/// The needle pin's head for a pin of [size] whose point is [at]: the centre of its round head and the radius of the coloured fill
/// (the white ring and the dark edge go [pinOutline] beyond it). The fill's apex is [pinOutline] above [at], so the edge's rounded
/// tip ends at [at]; the head sits [_needleLength] of a pin above the apex. The icon is drawn centred on this centre.
({Offset centre, double radius}) teardropHead(Offset at, double size, {bool tactical = false}) =>
    (centre: at + Offset(0, -(pinOutline(size, tactical: tactical) + size * _needleLength)), radius: size * 0.46);

/// From the apex to the head's centre, in pins: a round head on straight tangent sides running to a long point.
const double _needleLength = 1.3;

/// How far the ring and the edge of a teardrop or a badge reach beyond its coloured fill.
double pinOutline(double size, {bool tactical = false}) => _ringGrow(size, tactical) + size * 0.05;

/// The font size of the icon in a teardrop of [size]: its square sits inside the head's fill with room to spare.
double teardropGlyphSize(double size) => size * 0.52;

/// Where the icon of a teardrop of [size] (point [at]) is drawn: its box of [glyph] (the laid-out icon's size), centred on the
/// head's centre ([teardropHead]), not on the image's.
Rect teardropIconBox(Offset at, double size, Size glyph, {bool tactical = false}) =>
    Rect.fromCenter(center: teardropHead(at, size, tactical: tactical).centre, width: glyph.width, height: glyph.height);

/// The laid-out icon as the pins draw it (Material Symbols filled, a little heavier), at [fontSize]: for the tests that measure it.
TextPainter pinGlyph(IconData icon, double fontSize, {Color color = const Color(0xFFFFFFFF)}) => _glyph(icon, fontSize, color: color);

/// A map pin of [size] points in [style]: [at] is the place (the centre; for the teardrop, its point). On the light and dark
/// themes the shape or halo is white with a dark edge and the shape is filled with [tint]. In [tactical] (red only) there is no
/// white: the halo and the inner fill are dark, and the glyph, the shape's ring and the icon are [tint] (the theme's red).
void paintMapPin(Canvas canvas, Offset at, double size, IconData icon, Color tint, PinStyle style, {bool tactical = false}) {
  final halo = tactical ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  final edge = tactical ? const Color(0xFF000000) : const Color(0xB3000000);
  final fill = tactical ? const Color(0xFF160505) : tint;
  final ring = tactical ? tint : const Color(0xFFFFFFFF);
  final glyphColor = tactical ? tint : glyphOn(tint);
  final ringGrow = _ringGrow(size, tactical);
  switch (style) {
    case PinStyle.icon:
      final fs = size * 1.0;
      for (final (w, c) in [(size * 0.3, edge), (size * 0.2, halo)]) {
        _paintGlyph(canvas, at, _glyph(icon, fs, foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = w..strokeJoin = StrokeJoin.round..color = c));
      }
      _paintGlyph(canvas, at, _glyph(icon, fs, color: tint));
    case PinStyle.teardrop:
      _paintTeardrop(canvas, at, size, tint, tactical: tactical, icon: icon);
    case PinStyle.badge:
      final rect = Rect.fromCenter(center: at, width: size, height: size);
      RRect rr(double grow) => RRect.fromRectAndRadius(rect.inflate(grow), Radius.circular(size * 0.26 + grow));
      canvas.drawRRect(rr(ringGrow + size * 0.05), Paint()..color = edge);
      canvas.drawRRect(rr(ringGrow), Paint()..color = ring);
      canvas.drawRRect(rr(0), Paint()..color = fill);
      _paintGlyph(canvas, at, _glyph(icon, size * 0.64, color: glyphColor));
  }
}

/// The teardrop (needle pin) of [size] whose point is [at], filled with [tint]: with an [icon] drawn in its head, or with none a round
/// hole (a plain pin, which needs no icon font).
void _paintTeardrop(Canvas canvas, Offset at, double size, Color tint, {required bool tactical, IconData? icon}) {
  final edge = tactical ? const Color(0xFF000000) : const Color(0xB3000000);
  final fill = tactical ? const Color(0xFF160505) : tint;
  final ring = tactical ? tint : const Color(0xFFFFFFFF);
  final glyphColor = tactical ? tint : glyphOn(tint);
  final ringGrow = _ringGrow(size, tactical);
  final head = teardropHead(at, size, tactical: tactical);
  final r = head.radius;
  final c = head.centre;
  final apex = Offset(at.dx, at.dy - pinOutline(size, tactical: tactical));
  final th = math.acos(r / (apex.dy - c.dy));
  final tl = c + Offset(-r * math.sin(th), r * math.cos(th));
  final tr = c + Offset(r * math.sin(th), r * math.cos(th));
  final needle = Path()
    ..moveTo(apex.dx, apex.dy)
    ..lineTo(tl.dx, tl.dy)
    ..arcToPoint(tr, radius: Radius.circular(r), largeArc: true, clockwise: true)
    ..close();
  Paint line(Color col, double grow) => Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = grow * 2
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(needle, line(edge, ringGrow + size * 0.05));
  canvas.drawPath(needle, line(ring, ringGrow));
  canvas.drawPath(needle, Paint()..color = fill);
  if (icon != null) {
    final tp = _glyph(icon, teardropGlyphSize(size), color: glyphColor);
    tp.paint(canvas, teardropIconBox(at, size, tp.size, tactical: tactical).topLeft);
  } else {
    canvas.drawCircle(c, r * 0.4, Paint()..color = glyphColor);
  }
}

/// A plain map pin (a teardrop with a round hole, no icon font: a font that is not ready when the image is drawn would leave it empty)
/// as PNG bytes, for a dropped pin and a route's destination. Its point is at the bottom middle of the image for the teardrop style's
/// symbol layer (anchor at the bottom), and at the middle of an image twice as tall for the other styles' (anchor in the centre).
Future<Uint8List> renderPlainPinPng(Color tint, PinStyle style, {double size = 30, double ratio = 3, bool tactical = false}) async {
  final one = pinImageSize(PinStyle.teardrop, size);
  final tall = style != PinStyle.teardrop;
  final box = tall ? Size(one.width, one.height * 2 - size * 0.34) : one;
  final at = tall ? Offset(box.width / 2, box.height / 2) : pinImageAt(PinStyle.teardrop, size, tactical: tactical);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  _paintTeardrop(c, at, size, tint, tactical: tactical);
  final img = await rec.endRecording().toImage((box.width * ratio).round(), (box.height * ratio).round());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
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

/// The size in points of the image of a pin of [size]: a square half as wide again for the icon and the badge; for the teardrop
/// (the needle pin) as wide, and tall enough for the whole long pin above its point.
Size pinImageSize(PinStyle style, double size) => style == PinStyle.teardrop ? Size(size * 1.5, size * 2.3) : Size.square(size * 1.5);

/// Where the pin of [size] is placed in its image ([paintMapPin]'s `at`): the teardrop's point near the bottom middle (room for
/// its edge below), the others in the middle.
Offset pinImageAt(PinStyle style, double size, {bool tactical = false}) {
  final box = pinImageSize(style, size);
  return style == PinStyle.teardrop ? Offset(box.width / 2, box.height - size * (tactical ? 0.2 : 0.17)) : box.center(Offset.zero);
}

/// The pin as PNG bytes of [pinImageSize] points at [ratio] pixels per point (room for the edge, the teardrop's point at the
/// bottom middle), for `addImage` with the anchor at the bottom for the teardrop and the centre for the others.
Future<Uint8List> renderPinPng(IconData icon, Color tint, PinStyle style, {double size = 30, double ratio = 3, bool tactical = false}) async {
  final box = pinImageSize(style, size);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintMapPin(c, pinImageAt(style, size, tactical: tactical), size, icon, tint, style, tactical: tactical);
  final img = await rec.endRecording().toImage((box.width * ratio).round(), (box.height * ratio).round());
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

  /// The image name of the plain pin in [tint] (see [renderPlainPinPng]), added on first use.
  Future<String> ensurePlain(Color tint) async {
    final name = 'pin-plain-${style.name}${tactical ? '-t' : ''}-${(tint.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    if (_have.add(name)) await add(name, await renderPlainPinPng(tint, style, ratio: ratio, tactical: tactical));
    return name;
  }

  void reset() => _have.clear();
}

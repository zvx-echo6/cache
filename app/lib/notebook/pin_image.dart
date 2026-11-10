import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;

/// A map pin with an icon: a disc in the place's colour, a thin ring in the map's casing colour, and the icon in black or white
/// (whichever reads on the colour). The same drawing makes the PNG added to the map's style and the pictures in the lists.
void paintMapPin(Canvas canvas, Offset centre, double size, IconData icon, Color tint, Color casing) {
  final r = size / 2;
  canvas.drawCircle(centre, r, Paint()..color = casing);
  canvas.drawCircle(centre, r - size * 0.07, Paint()..color = tint);
  final glyph = glyphOn(tint);
  final tp = TextPainter(
    text: TextSpan(text: String.fromCharCode(icon.codePoint), style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size * 0.62, color: glyph)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
}

/// The icon's colour on a disc of [c]: near-black on a light colour, white on a dark one.
Color glyphOn(Color c) => c.computeLuminance() > 0.38 ? const Color(0xFF111111) : const Color(0xFFFFFFFF);

/// The image's name in the map style: one per icon and colour.
String pinImageId(String iconId, Color tint) => 'pin-$iconId-${(tint.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The pin as PNG bytes, [size] points at [ratio] pixels per point, for `addImage`.
Future<Uint8List> renderPinPng(IconData icon, Color tint, Color casing, {double size = 30, double ratio = 3}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintMapPin(c, Offset(size / 2, size / 2), size, icon, tint, casing);
  final img = await rec.endRecording().toImage((size * ratio).round(), (size * ratio).round());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Which pin images the map style already has, so each icon and colour is drawn and added once ([add] is the style's
/// `addImage`). A new style (a theme change drops the images) is a new cache: call [reset].
class PinImages {
  PinImages(this.add);

  final Future<void> Function(String name, Uint8List png) add;
  final Set<String> _have = {};

  /// The image name for [iconId] in [tint], added on first use.
  Future<String> ensure(String iconId, IconData icon, Color tint, Color casing) async {
    final name = pinImageId(iconId, tint);
    if (_have.add(name)) await add(name, await renderPinPng(icon, tint, casing));
    return name;
  }

  void reset() => _have.clear();
}

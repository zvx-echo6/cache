import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// The map image of a route's time label ("14 min"): a small rounded label. The chosen route's is filled in the route colour with
/// white text; another route's is pale with dark text and a thin outline in the route colour. Drawn at [ratio] pixels per point
/// (see pin_image.dart for how the map reads an added image's size).
const double kRouteTimeCorner = 3;

Future<Uint8List> renderRouteTimePng(String text, {required bool selected, required Color route, double ratio = 3}) async {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: selected ? const Color(0xFFFFFFFF) : const Color(0xFF1B1D20), height: 1.0, fontFamily: 'Roboto'),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  const padX = 7.0, padY = 4.0, edge = 1.5;
  final w = tp.width + padX * 2 + edge * 2, h = tp.height + padY * 2 + edge * 2;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  final box = RRect.fromRectAndRadius(Rect.fromLTWH(edge, edge, w - edge * 2, h - edge * 2), const Radius.circular(kRouteTimeCorner));
  if (selected) {
    c.drawRRect(box.inflate(1.2), Paint()..color = const Color(0xFFFFFFFF));
    c.drawRRect(box, Paint()..color = route);
  } else {
    c.drawRRect(box, Paint()..color = const Color(0xFFFBF6E8));
    c.drawRRect(box, Paint()..color = route.withValues(alpha: 0.7)..style = PaintingStyle.stroke..strokeWidth = 1.2);
  }
  tp.paint(c, Offset(edge + padX, edge + padY));
  final img = await rec.endRecording().toImage((w * ratio).ceil(), (h * ratio).ceil());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

// The pictures of stacked icons: the group marker (a disc with a count badge) and the discs of a fan, drawn by the painters the single
// icons use, so a group looks like what it holds.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../notebook/map_icons.dart';
import '../../notebook/notebook_map.dart' show repeaterTint;
import '../../notebook/pin_image.dart';
import '../../roads/road_chips.dart' show roadChipGlyph;
import '../../roads/road_event.dart';
import '../../roads/road_map_layers.dart' show roadEventRole;
import '../../theme.dart' show CacheThemeId, isFlatIconTheme;
import '../palette/map_palette.dart';
import '../poi_chips.dart' show paintPoiChip, poiChipLook;
import 'icon_groups.dart';

/// The width of the image of a group marker, in points (the disc is [kFanDisc] across, the badge sits on its upper right).
const double kStackMarkerSize = 54;

/// Draws a [kind] disc of [kFanDisc] points across, centred on [at]: a repeater's, or a road event's chip (of [road]) scaled up to
/// the same size.
void paintStackDisc(Canvas canvas, Offset at, StackKind kind, MapPalette p, {RoadEventKind road = RoadEventKind.work, double ratio = 3}) {
  final tactical = p.id == CacheThemeId.tactical;
  switch (kind) {
    case StackKind.repeater:
      paintMapPin(canvas, at, 30, mapIcon(kRepeaterIcon).icon, repeaterTint(tactical: tactical), PinStyle.icon, tactical: tactical, flat: isFlatIconTheme(p.id), ratio: ratio);
    case StackKind.roadEvent:
    case StackKind.poi:
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        ..scale(kFanDisc / 18);
      paintPoiChip(canvas, Offset.zero, roadChipGlyph(road), poiChipLook(p, roadEventRole(road)), flat: isFlatIconTheme(p.id), ratio: ratio * kFanDisc / 18);
      canvas.restore();
  }
}

/// A fan's disc as PNG bytes: [kFanDisc] plus the edge, in a square of [kStackMarkerSize] points.
Future<Uint8List> renderStackDiscPng(StackKind kind, MapPalette p, {RoadEventKind road = RoadEventKind.work, double ratio = 3}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintStackDisc(c, const Offset(kStackMarkerSize / 2, kStackMarkerSize / 2), kind, p, road: road, ratio: ratio);
  return _png(rec, ratio);
}

/// The group marker as PNG bytes: the disc of the group's kind with a dark count badge (a cream ring, white number) on its upper right.
Future<Uint8List> renderStackMarkerPng(StackKind kind, String badge, MapPalette p, {RoadEventKind road = RoadEventKind.work, double ratio = 3}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  const mid = Offset(kStackMarkerSize / 2, kStackMarkerSize / 2);
  paintStackDisc(c, mid, kind, p, road: road, ratio: ratio);
  final tp = TextPainter(
    text: TextSpan(text: badge, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFFFFFFFF), height: 1.0)),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = (tp.width + 9).clamp(17.0, 40.0);
  final centre = mid + const Offset(14, -14);
  final pill = RRect.fromRectAndRadius(Rect.fromCenter(center: centre, width: w, height: 17), const Radius.circular(8.5));
  c.drawRRect(pill.inflate(1.8), Paint()..color = const Color(0xFFF3E9D2));
  c.drawRRect(pill, Paint()..color = const Color(0xFF22222A));
  tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
  return _png(rec, ratio);
}

Future<Uint8List> _png(ui.PictureRecorder rec, double ratio) async {
  final px = (kStackMarkerSize * ratio).round();
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

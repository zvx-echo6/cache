import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:material_symbols_icons/symbols.dart';

import '../maps/palette/map_palette.dart';
import '../maps/poi_chips.dart' show kPoiChipSize, paintPoiChip, poiChipLook;
import '../theme.dart' show isFlatIconTheme;
import 'road_event.dart';
import 'road_map_layers.dart';

/// The chips of the road events, drawn the way the public-place chips are (a Material Symbols glyph on a round disc with a ring, one
/// image per kind): a block sign for a closure, a car crash for a crash or incident, a construction sign for work. The disc is the
/// event colour of the theme (`eventClosure` for closures and crashes, `eventWork` for work).

/// The glyph of a kind.
IconData roadChipGlyph(RoadEventKind kind) => switch (kind) {
  RoadEventKind.closure => Symbols.block,
  RoadEventKind.crash => Symbols.car_crash,
  RoadEventKind.work => Symbols.construction,
};

/// The chip as PNG bytes: [kPoiChipSize] points square at [ratio] pixels per point.
Future<Uint8List> renderRoadChipPng(RoadEventKind kind, MapPalette p, {double ratio = 3}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintPoiChip(c, const Offset(kPoiChipSize / 2, kPoiChipSize / 2), roadChipGlyph(kind), poiChipLook(p, roadEventRole(kind)), flat: isFlatIconTheme(p.id), ratio: ratio);
  final px = (kPoiChipSize * ratio).round();
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Adds the three chips to the map style (`addImage`). A new style drops its images, so this runs on each style load. One that cannot be
/// drawn or added is logged; the others still go in.
Future<void> addRoadChips(
  Future<void> Function(String name, Uint8List png) add,
  MapPalette p, {
  required double ratio,
  void Function(String message)? log,
  Future<Uint8List> Function(RoadEventKind kind, MapPalette p, {double ratio}) render = renderRoadChipPng,
}) async {
  for (final k in RoadEventKind.values) {
    try {
      await add(roadChipImage(k), await render(k, p, ratio: ratio));
    } catch (e) {
      log?.call('Road chip ${roadChipImage(k)} failed: $e');
    }
  }
}

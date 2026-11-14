import 'dart:math' as math;

import 'package:cache/layout/adaptive.dart' show kSideCardWidth;
import 'package:cache/maps/style/style_generator.dart' show kPositionDotReach;
import 'package:cache/maps/ui/map_widgets.dart' show AttributionChip, MapButton, ScaleBarWidget;
import 'package:cache/maps/ui/vehicle_arrow.dart';
import 'package:cache/nav/guidance_camera.dart';
import 'package:cache/nav/ui/elevation_dock.dart' show GuidanceDock;
import 'package:cache/nav/ui/guidance_panels.dart' show GuidanceBanner;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// The Maps screen while guiding, as laid out now and read from the widgets themselves (not from the screen's own measuring),
/// in the map's points: the free map and the pieces in its corners.
class GuideLayout {
  GuideLayout({required this.map, required this.free, required this.tiles});

  final Size map;
  final Rect free;
  final List<Rect> tiles;

  /// How far the position's marker reaches (the car's arrow or the dot, the larger).
  static double get reach => math.max(kPositionDotReach, VehicleArrow.reach);

  /// Where the position should be: centred across the free map and [kGuideDown] of the way down, kept clear of the corners.
  Offset get anchor => guidanceAnchor(free, tiles: tiles, reach: reach);

  /// Reads the layout; [safe] is the screen's safe area (what the app's MediaQuery says).
  static GuideLayout read(WidgetTester tester, {EdgeInsets safe = EdgeInsets.zero}) {
    final mapRect = tester.getRect(find.byType(MapLibreMap));
    Rect local(Finder f) => tester.getRect(f).shift(-mapRect.topLeft);
    List<Rect> all(Finder f) => [for (var i = 0; i < f.evaluate().length; i++) local(f.at(i))];
    final banner = local(find.byType(GuidanceBanner).first);
    final side = tester.view.physicalSize.width / tester.view.devicePixelRatio >= kSideCardWidth;
    final buttons = all(find.byType(MapButton));
    final tiles = [
      ...all(find.byType(ScaleBarWidget)),
      ...all(find.byType(AttributionChip)),
      ...all(find.byKey(const ValueKey('route-inset'))),
      if (buttons.isNotEmpty) buttons.reduce((a, b) => a.expandToInclude(b)),
    ];
    final map = mapRect.size;
    final free = side
        ? Rect.fromLTRB(banner.right, safe.top, map.width - safe.right, map.height - safe.bottom)
        : Rect.fromLTRB(safe.left, banner.bottom, map.width - safe.right, local(find.byType(GuidanceDock).first).top);
    return GuideLayout(map: map, free: free, tiles: tiles);
  }
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:material_symbols_icons/symbols.dart';

import '../notebook/pin_image.dart' show flatEdgeWidth, kFlatIconEdge, pinGlyph;
import '../theme.dart' show CacheThemeId, isFlatIconTheme;
import 'palette/map_palette.dart';

/// The public places the base map draws (its `pois` layer): one round chip per category, a Material Symbols glyph on a disc in the
/// category's group colour. The table is data from the tile schema (kind values), not language. Churches, schools, banks and civic
/// buildings are left out on purpose.
///
/// One chip is [kPoiChipSize] points wide; the ring and edge are inside it. A chip is a round disc with a ring, a shape none of the
/// user's own pin styles (icon, teardrop, badge) uses, so a public place is never taken for a saved one.
class PoiIcon {
  const PoiIcon(this.id, this.symbol, this.group, this.name, this.kinds);

  /// The image name in the map style is `poi-<id>`.
  final String id;
  final IconData symbol;

  /// The palette role of the group colour ([poiGroupRoles]).
  final String group;
  final String name;

  /// The `pois` layer's `kind` values drawn with this icon.
  final List<String> kinds;

  String get image => 'poi-$id';

  /// The image of the chip in a theme: the flat look (light and Parchment: no ring, a fine edge) has its own name, so a theme
  /// switch never shows the other look's image.
  String imageFor({required bool flat}) => flat ? 'poi-$id-f' : image;
}

/// The nine group colours, as palette roles.
const String poiFuel = 'poiFuel', poiFood = 'poiFood', poiShop = 'poiShop', poiLodging = 'poiLodging', poiOutdoor = 'poiOutdoor',
    poiMedical = 'poiMedical', poiSafety = 'poiSafety', poiWater = 'poiWater', poiLandmark = 'poiLandmark';

const List<String> poiGroupRoles = [poiFuel, poiFood, poiShop, poiLodging, poiOutdoor, poiMedical, poiSafety, poiWater, poiLandmark];

/// The 22 icons. Hostel, guest_house, chalet, volcano, viewpoint and zoo are listed but not yet seen in the tiles.
final List<PoiIcon> poiIcons = [
  PoiIcon('fuel', Symbols.local_gas_station, poiFuel, 'Fuel', ['fuel']),
  PoiIcon('charging', Symbols.ev_station, poiFuel, 'Charging', ['charging_station']),
  PoiIcon('airport', Symbols.local_airport, poiFuel, 'Airport', ['aerodrome']),
  PoiIcon('food', Symbols.restaurant, poiFood, 'Food', ['restaurant', 'fast_food', 'food_court', 'bakery', 'ice_cream', 'bar', 'pub']),
  PoiIcon('cafe', Symbols.local_cafe, poiFood, 'Cafe', ['cafe', 'coffee']),
  PoiIcon('groceries', Symbols.shopping_cart, poiShop, 'Groceries', ['supermarket', 'convenience', 'variety_store', 'wholesale']),
  PoiIcon('shop', Symbols.shopping_bag, poiShop, 'Shops', ['department_store', 'doityourself', 'outdoor', 'mall']),
  PoiIcon('lodging', Symbols.hotel, poiLodging, 'Lodging', ['hotel', 'motel', 'hostel', 'guest_house', 'chalet']),
  PoiIcon('camp', Symbols.camping, poiOutdoor, 'Campground', ['camp_site', 'caravan_site']),
  PoiIcon('park', Symbols.park, poiOutdoor, 'Park', ['park', 'nature_reserve', 'garden', 'golf_course']),
  PoiIcon('peak', Symbols.terrain, poiOutdoor, 'Peak', ['peak', 'volcano']),
  PoiIcon('trailhead', Symbols.hiking, poiOutdoor, 'Trailhead', ['trailhead']),
  PoiIcon('ranger', Symbols.forest, poiOutdoor, 'Ranger station', ['ranger_station']),
  PoiIcon('hospital', Symbols.local_hospital, poiMedical, 'Hospital', ['hospital']),
  PoiIcon('clinic', Symbols.medical_services, poiMedical, 'Clinic', ['clinic', 'doctors']),
  PoiIcon('pharmacy', Symbols.local_pharmacy, poiMedical, 'Pharmacy', ['pharmacy', 'chemist']),
  PoiIcon('police', Symbols.local_police, poiSafety, 'Police', ['police']),
  PoiIcon('fire', Symbols.local_fire_department, poiSafety, 'Fire station', ['fire_station']),
  PoiIcon('water', Symbols.water_drop, poiWater, 'Drinking water', ['drinking_water']),
  PoiIcon('restroom', Symbols.wc, poiWater, 'Restrooms', ['toilets']),
  PoiIcon('landmark', Symbols.attractions, poiLandmark, 'Landmark', ['attraction', 'museum', 'monument', 'viewpoint', 'stadium', 'theatre', 'zoo']),
  PoiIcon('info', Symbols.info, poiLandmark, 'Visitor information', ['information']),
];

/// The kind line of a tapped chip: the name of its icon ("Park", "Fuel", "Pharmacy"); empty for a kind that is not drawn.
String poiKindName(String? kind) {
  if (kind == null) return '';
  for (final i in poiIcons) {
    if (i.kinds.contains(kind)) return i.name;
  }
  return '';
}

/// Every `kind` that is drawn.
List<String> get poiKinds => [for (final i in poiIcons) ...i.kinds];

/// The kinds that win a collision with other chips and names: medical and emergency services.
List<String> get poiPriorityKinds => [
      for (final i in poiIcons)
        if (i.group == poiMedical || i.group == poiSafety) ...i.kinds
    ];

/// The kinds that show this many zoom levels before their data `min_zoom` (a tile that does not carry the feature yet still lacks it).
const List<String> poiEarlyKinds = ['hospital', 'pharmacy', 'fuel'];
const int poiEarlyBy = 2;

/// A chip's width and height in points, and the disc, ring and edge radii in it (the approved design's 24-point chip).
const double kPoiChipSize = 24;
const double _edgeR = 11.2, _ringR = 10.5, _discR = 9.0;

/// The colours of one chip: [fill] the disc, [ring] around it, [glyph] on it, [edge] the thin outer line that lifts it off the map.
class PoiChipLook {
  const PoiChipLook(this.fill, this.ring, this.glyph, this.edge);
  final Color fill, ring, glyph, edge;
}

/// How a chip of [group] is drawn in [p]'s theme. Light and parchment: the group colour with a white glyph and ring. Dark: the (lighter) group
/// colour with a near-black glyph and a dark ring. Tactical: red only, so every chip is a dark disc with a red ring and glyph, and the
/// categories are told apart by glyph alone.
PoiChipLook poiChipLook(MapPalette p, String group) {
  switch (p.id) {
    case CacheThemeId.tactical:
      return PoiChipLook(const Color(0xFF160505), p[group], p[group], const Color(0xFF000000));
    case CacheThemeId.dark:
      return PoiChipLook(p[group], const Color(0xFF0F1115), const Color(0xFF101418), const Color(0x66FFFFFF));
    default:
      return PoiChipLook(p[group], p['positionRing'], const Color(0xFFFFFFFF), const Color(0x66000000));
  }
}

/// Draws one chip centred on [centre] of [canvas] (in points). [flat] (the light and Parchment themes): no white ring, and the disc has the
/// same 2 pixel near-black edge ([ratio] pixels per point) as the flat icon pins; dark and Tactical keep their ring.
void paintPoiChip(Canvas canvas, Offset centre, IconData? symbol, PoiChipLook look, {bool flat = false, double ratio = 3}) {
  if (flat) {
    canvas.drawCircle(centre, _discR + flatEdgeWidth(ratio), Paint()..color = kFlatIconEdge);
  } else {
    canvas.drawCircle(centre, _edgeR, Paint()..color = look.edge);
    canvas.drawCircle(centre, _ringR, Paint()..color = look.ring);
  }
  canvas.drawCircle(centre, _discR, Paint()..color = look.fill);
  if (symbol == null) return; // The plain dot: the disc and ring alone.
  final tp = pinGlyph(symbol, 12.5, color: look.glyph);
  tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
}

/// The chip as PNG bytes: [kPoiChipSize] points square at [ratio] pixels per point. [dot] draws the plain dot (no glyph), the fallback
/// for a chip that cannot be drawn.
Future<Uint8List> renderPoiChipPng(PoiIcon icon, MapPalette p, {double ratio = 3, bool dot = false}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintPoiChip(c, const Offset(kPoiChipSize / 2, kPoiChipSize / 2), dot ? null : icon.symbol, poiChipLook(p, icon.group), flat: isFlatIconTheme(p.id), ratio: ratio);
  final px = (kPoiChipSize * ratio).round();
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Adds every chip of [p]'s theme to the map style (`addImage`), at [ratio] pixels per point (see `pinImageRatio`). A new style drops its
/// images, so this runs on each style load. A chip that cannot be drawn or added is logged and tried once more; if it fails again its
/// kind gets the plain dot of its group colour instead, so a kind is never left without an image. [render] draws a chip (a test's).
Future<void> addPoiChips(
  Future<void> Function(String name, Uint8List png) add,
  MapPalette p, {
  required double ratio,
  void Function(String message)? log,
  Future<Uint8List> Function(PoiIcon icon, MapPalette p, {double ratio, bool dot}) render = renderPoiChipPng,
}) async {
  for (final i in poiIcons) {
    var done = false;
    for (var attempt = 1; attempt <= 2 && !done; attempt++) {
      try {
        await add(i.imageFor(flat: isFlatIconTheme(p.id)), await render(i, p, ratio: ratio, dot: false));
        done = true;
      } catch (e) {
        log?.call('POI chip ${i.image} failed (attempt $attempt): $e');
      }
    }
    if (done) continue;
    try {
      await add(i.imageFor(flat: isFlatIconTheme(p.id)), await render(i, p, ratio: ratio, dot: true));
      log?.call('POI chip ${i.image} is the plain dot');
    } catch (e) {
      log?.call('POI chip ${i.image} has no image at all: $e');
    }
  }
}

/// What a style load does for the POI layer, once, for both maps: hides the layer, adds every chip ([addPoiChips]), lays the layer out
/// again with them ([relayout]) and only then shows it, so a tile is never laid out and drawn while a chip it asks for is missing.
/// The layer is shown whatever happens (a thrown step is logged), so a failure never leaves the map without its places.
Future<void> installPoiChips({
  required Future<void> Function(String name, Uint8List png) add,
  required Future<void> Function(bool visible) setVisible,
  required Future<void> Function() relayout,
  required MapPalette palette,
  required double ratio,
  void Function(String message)? log,
  Future<Uint8List> Function(PoiIcon icon, MapPalette p, {double ratio, bool dot}) render = renderPoiChipPng,
}) async {
  try {
    await setVisible(false);
  } catch (_) {} // A style without the POI layer (OpenMapTiles layout).
  try {
    await addPoiChips(add, palette, ratio: ratio, log: log, render: render);
    await relayout();
  } catch (e) {
    log?.call('POI chips: $e');
  } finally {
    try {
      await setVisible(true);
    } catch (_) {}
  }
}

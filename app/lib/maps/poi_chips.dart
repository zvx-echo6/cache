import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:material_symbols_icons/symbols.dart';

import '../notebook/pin_image.dart' show pinGlyph;
import '../theme.dart' show CacheThemeId;
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

/// Draws one chip centred on [centre] of [canvas] (in points).
void paintPoiChip(Canvas canvas, Offset centre, IconData symbol, PoiChipLook look) {
  canvas.drawCircle(centre, _edgeR, Paint()..color = look.edge);
  canvas.drawCircle(centre, _ringR, Paint()..color = look.ring);
  canvas.drawCircle(centre, _discR, Paint()..color = look.fill);
  final tp = pinGlyph(symbol, 12.5, color: look.glyph);
  tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
}

/// The chip as PNG bytes: [kPoiChipSize] points square at [ratio] pixels per point.
Future<Uint8List> renderPoiChipPng(PoiIcon icon, MapPalette p, {double ratio = 3}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(ratio);
  paintPoiChip(c, const Offset(kPoiChipSize / 2, kPoiChipSize / 2), icon.symbol, poiChipLook(p, icon.group));
  final px = (kPoiChipSize * ratio).round();
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Adds every chip of [p]'s theme to the map style (`addImage`), at [ratio] pixels per point (see `pinImageRatio`). A new style drops its images,
/// so this runs on each style load. A chip that cannot be drawn or added is skipped, so one failure never loses the others.
Future<void> addPoiChips(Future<void> Function(String name, Uint8List png) add, MapPalette p, {required double ratio}) async {
  for (final i in poiIcons) {
    try {
      await add(i.image, await renderPoiChipPng(i, p, ratio: ratio));
    } catch (_) {}
  }
}

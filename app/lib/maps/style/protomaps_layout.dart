import 'dart:convert';

import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;

import '../palette/map_palette.dart';

/// The Protomaps (basemap tiles v4) layout of the base map. Its layers come from the official
/// `@protomaps/basemaps` package (BSD-3-Clause, https://github.com/protomaps/basemaps, version 5.7.2), turned into
/// assets/map/protomaps_v4_template.json by tool/make_protomaps_template.cjs. In that template every colour is
/// a placeholder named after a field of the package's "flavor" (`@water`, `@landcover.forest`, ...).
///
/// This file is the other half: it makes a flavor out of one of the app's palettes, so the Protomaps layout is
/// drawn in the same four themes as the OpenMapTiles layout, from the same palette roles.

/// Which layout a base-map layer definition uses (its `layout` field).
enum MapLayout {
  /// OpenMapTiles (OpenFreeMap); the default when a definition says nothing.
  openMapTiles,

  /// Protomaps basemap tiles v4.
  protomapsV4;

  static MapLayout parse(Object? name) => switch (name) {
        'protomaps-v4' => MapLayout.protomapsV4,
        _ => MapLayout.openMapTiles,
      };
}

/// The Protomaps template, from the app's assets.
Future<Map<String, dynamic>> loadProtomapsTemplate() async =>
    jsonDecode(await rootBundle.loadString('assets/map/protomaps_v4_template.json')) as Map<String, dynamic>;

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// Every colour field of the package's flavor, from the palette. A field the template does not use is still
/// listed, so a newer template cannot meet a gap (the tests check that every placeholder is covered).
Map<String, Color> protomapsFlavor(MapPalette p) {
  final land = p['land'];
  // Tunnels are drawn a little paler than the same road above ground.
  Color tunnel(String role) => _mix(p[role], land, 0.35);
  return {
    'background': land,
    'earth': land,
    'park_a': p['park'],
    'park_b': p['parkEdge'],
    'hospital': p['hospital'],
    'industrial': _mix(land, p['building'], 0.5),
    'school': p['school'],
    'wood_a': p['wood'],
    'wood_b': p['wood'],
    'pedestrian': _mix(land, p['roadMinor'], 0.5),
    'scrub_a': p['grass'],
    'scrub_b': p['grass'],
    'glacier': p['ice'],
    'sand': p['sand'],
    'beach': p['sand'],
    'aerodrome': p['aeroway'],
    'runway': p['aerowayLine'],
    'water': p['water'],
    'zoo': p['park'],
    'military': _mix(land, p['boundaryMinor'], 0.3),
    'tunnel_other_casing': p['roadMinorCasing'],
    'tunnel_minor_casing': p['roadMinorCasing'],
    'tunnel_link_casing': p['roadMinorCasing'],
    'tunnel_major_casing': p['roadMinorCasing'],
    'tunnel_highway_casing': p['roadMinorCasing'],
    'tunnel_other': tunnel('roadPath'),
    'tunnel_minor': tunnel('roadMinor'),
    'tunnel_link': tunnel('roadMajor'),
    'tunnel_major': tunnel('roadMajor'),
    'tunnel_highway': tunnel('roadMotorway'),
    'pier': p['building'],
    'buildings': p['building'],
    'minor_service_casing': p['roadMinorCasing'],
    'minor_casing': p['roadMinorCasing'],
    'link_casing': p['roadMajorCasing'],
    'major_casing_late': p['roadMajorCasing'],
    'highway_casing_late': p['roadMajorCasing'],
    'other': p['roadPath'],
    'minor_service': p['roadMinor'],
    'minor_a': p['roadMinor'],
    'minor_b': p['roadMinor'],
    'link': p['roadMajor'],
    'major_casing_early': p['roadMajorCasing'],
    'major': p['roadMajor'],
    'highway_casing_early': p['roadMajorCasing'],
    'highway': p['roadMotorway'],
    'railway': p['rail'],
    'boundaries': p['boundary'],
    'bridges_other_casing': p['roadMinorCasing'],
    'bridges_minor_casing': p['roadMinorCasing'],
    'bridges_link_casing': p['roadMajorCasing'],
    'bridges_major_casing': p['roadMajorCasing'],
    'bridges_highway_casing': p['roadMajorCasing'],
    'bridges_other': p['roadPath'],
    'bridges_minor': p['roadMinor'],
    'bridges_link': p['roadMajor'],
    'bridges_major': p['roadMajor'],
    'bridges_highway': p['roadMotorway'],
    'roads_label_minor': p['labelRoad'],
    'roads_label_minor_halo': p['labelHalo'],
    'roads_label_major': p['labelRoad'],
    'roads_label_major_halo': p['labelHalo'],
    'ocean_label': p['labelWater'],
    'subplace_label': p['labelMinor'],
    'subplace_label_halo': p['labelHalo'],
    'city_label': p['labelPlace'],
    'city_label_halo': p['labelHalo'],
    'state_label': p['labelMinor'],
    'state_label_halo': p['labelHalo'],
    'country_label': p['labelPlace'],
    'address_label': p['labelPath'],
    'address_label_halo': p['labelHalo'],
    // Points of interest are not drawn (their icons need a sprite sheet), but their colours stay defined.
    'pois.blue': p['labelMinor'],
    'pois.green': p['labelMinor'],
    'pois.lapis': p['labelMinor'],
    'pois.pink': p['labelMinor'],
    'pois.red': p['labelMinor'],
    'pois.slategray': p['labelMinor'],
    'pois.tangerine': p['labelMinor'],
    'pois.turquoise': p['labelMinor'],
    'landcover.barren': p['sand'],
    'landcover.farmland': p['grass'],
    'landcover.forest': p['wood'],
    'landcover.glacier': p['ice'],
    'landcover.grassland': p['grass'],
    'landcover.scrub': p['wetland'],
    'landcover.urban_area': p['residential'],
  };
}

/// The template's layers with every `@field` replaced from the palette and the source set to [src].
List<Map<String, dynamic>> protomapsLayers(MapPalette p, Map<String, dynamic> template, String src) {
  final flavor = protomapsFlavor(p);
  Object? fill(Object? v) {
    if (v is String && v.startsWith('@')) {
      final c = flavor[v.substring(1)];
      if (c == null) throw StateError('The Protomaps template uses ${v.substring(1)}, which the palette mapping lacks');
      return MapPalette.cssOf(c);
    }
    if (v is List) return [for (final e in v) fill(e)];
    if (v is Map) return <String, dynamic>{for (final e in v.entries) e.key as String: fill(e.value)};
    return v;
  }

  return [
    for (final l in template['layers'] as List)
      () {
        final m = fill(l) as Map<String, dynamic>;
        if (m.containsKey('source')) m['source'] = src;
        return m;
      }()
  ];
}

/// Where overlays slot in: the first layer with this id prefix is where "under the roads" overlays go, and
/// the label layers start at [protomapsLabelsAt].
const String protomapsGroundAt = 'roads_tunnels';
const String protomapsLabelsAt = 'address_label';

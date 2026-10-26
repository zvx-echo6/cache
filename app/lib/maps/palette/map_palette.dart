import 'package:flutter/material.dart' show Color, immutable;

import '../../theme.dart';

/// The colours of one map theme, by role. Every map style is made from a palette: the style generator
/// (style/style_generator.dart) holds the layout and each palette gives the colours, so there is one
/// generator and four palettes and no hand-kept per-theme style. The Protomaps-layout generator that
/// comes later reads the same roles.
@immutable
class MapPalette {
  const MapPalette._(this.id, this._colors);

  /// Builds a palette; throws if a role is missing, so a new role cannot be forgotten in one theme.
  factory MapPalette(CacheThemeId id, Map<String, Color> colors) {
    final missing = [for (final r in roleNames) if (!colors.containsKey(r)) r];
    if (missing.isNotEmpty) throw ArgumentError('Palette ${id.name} lacks roles: ${missing.join(', ')}');
    return MapPalette._(id, Map.unmodifiable(colors));
  }

  final CacheThemeId id;
  final Map<String, Color> _colors;

  /// Every role a palette must define. The base-map template (assets/map/omt_template.json) writes its
  /// colours as "@role" and the overlay builders ask for the overlay roles by name.
  static const List<String> roleNames = [
    // Ground and water.
    'land', 'water', 'waterway', 'park', 'parkEdge', 'wood', 'grass', 'sand', 'ice', 'wetland', 'residential',
    'cemetery', 'pitch', 'hospital', 'school', 'aeroway', 'aerowayLine', 'building', 'buildingEdge',
    // Roads, rail and borders.
    'roadMotorway', 'roadMajor', 'roadMinor', 'roadPath', 'roadMajorCasing', 'roadMinorCasing', 'rail',
    'boundary', 'boundaryMinor',
    // Labels.
    'labelPlace', 'labelMinor', 'labelRoad', 'labelPath', 'labelWater', 'labelWaterway', 'labelHalo',
    // Overlays.
    'hillshadeShadow', 'hillshadeHighlight', 'hillshadeAccent', 'contour', 'contourIndex', 'contourLabel',
    'publicLandsFill', 'publicLandsLine', 'trail', 'mvum', 'blm',
    // The phone's own position.
    'position', 'positionAccuracy', 'positionRing',
  ];

  Color operator [](String role) {
    final c = _colors[role];
    if (c == null) throw ArgumentError('Unknown palette role: $role');
    return c;
  }

  bool has(String role) => _colors.containsKey(role);

  /// A CSS colour MapLibre understands: `#rrggbb` when opaque, else `rgba(r,g,b,a)`. [opacity] multiplies the alpha.
  String css(String role, {double opacity = 1}) => cssOf(this[role], opacity: opacity);

  static String cssOf(Color c, {double opacity = 1}) {
    final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
    final a = (c.a * opacity).clamp(0.0, 1.0);
    if (a >= 0.999) {
      String h(int v) => v.toRadixString(16).padLeft(2, '0');
      return '#${h(r)}${h(g)}${h(b)}';
    }
    return 'rgba($r,$g,$b,${double.parse(a.toStringAsFixed(3))})';
  }
}

MapPalette mapPaletteFor(CacheThemeId id) => mapPalettes[id]!;

Color _c(int rgb, [double a = 1]) => Color(0xFF000000 | rgb).withValues(alpha: a);

/// Light: natural colours on near-white, close to the open style the layout started from.
final MapPalette _light = MapPalette(CacheThemeId.light, {
  'land': _c(0xF8F4F0), 'water': _c(0x9EC5E8), 'waterway': _c(0x8FB6DC), 'park': _c(0xD8E8C8),
  'parkEdge': _c(0xB9D9A8), 'wood': _c(0xBFE0A8, 0.7), 'grass': _c(0xC4DFB0), 'sand': _c(0xF4ECC4),
  'ice': _c(0xE0ECEC), 'wetland': _c(0xC9E2D0), 'residential': _c(0xEDE6DD, 0.6), 'cemetery': _c(0xCFE0B8),
  'pitch': _c(0xDFE5C9), 'hospital': _c(0xF5DCE6), 'school': _c(0xECEDCC), 'aeroway': _c(0xE5E4E0),
  'aerowayLine': _c(0xF0EDE9), 'building': _c(0xDCD9D6), 'buildingEdge': _c(0xC9C5C0),
  'roadMotorway': _c(0xFFCC88), 'roadMajor': _c(0xFFEEAA), 'roadMinor': _c(0xFFFFFF), 'roadPath': _c(0xF4F0EA),
  'roadMajorCasing': _c(0xE9AC77), 'roadMinorCasing': _c(0xCFCDCA), 'rail': _c(0xBBBBBB),
  'boundary': _c(0x7D7D86), 'boundaryMinor': _c(0xB3B3B3),
  'labelPlace': _c(0x1D2127), 'labelMinor': _c(0x2E343C), 'labelRoad': _c(0x5A616B), 'labelPath': _c(0x9C8A76),
  'labelWater': _c(0x495E91), 'labelWaterway': _c(0x5C94CF), 'labelHalo': _c(0xFFFFFF, 0.8),
  'hillshadeShadow': _c(0x46505F), 'hillshadeHighlight': _c(0xFFFFFF), 'hillshadeAccent': _c(0x6B7280),
  'contour': _c(0x8C643C, 0.55), 'contourIndex': _c(0x78502A, 0.85), 'contourLabel': _c(0x6B4A28),
  'publicLandsFill': _c(0x5EA657, 0.16), 'publicLandsLine': _c(0x3C8246, 0.75), 'trail': _c(0xB5470F),
  'mvum': _c(0x7B3FA0), 'blm': _c(0xB8860B),
  'position': _c(0x1F6FA8), 'positionAccuracy': _c(0x1F6FA8, 0.16), 'positionRing': _c(0xFFFFFF),
});

/// Dark: low-glare blue-greys, labels light.
final MapPalette _dark = MapPalette(CacheThemeId.dark, {
  'land': _c(0x14171C), 'water': _c(0x1F3B52), 'waterway': _c(0x2F5C80), 'park': _c(0x1F2D24),
  'parkEdge': _c(0x2A3B2F), 'wood': _c(0x1B2B21, 0.8), 'grass': _c(0x20301F), 'sand': _c(0x2B2A22),
  'ice': _c(0x2A3138), 'wetland': _c(0x1D3030), 'residential': _c(0xFFFFFF, 0.03), 'cemetery': _c(0x222C24),
  'pitch': _c(0x232E25), 'hospital': _c(0x33242B), 'school': _c(0x272719), 'aeroway': _c(0x22262C),
  'aerowayLine': _c(0x2E333B), 'building': _c(0x262A31), 'buildingEdge': _c(0x323740),
  'roadMotorway': _c(0x7A5A34), 'roadMajor': _c(0x59606B), 'roadMinor': _c(0x3E444D), 'roadPath': _c(0x5A606A),
  'roadMajorCasing': _c(0x1C1F24), 'roadMinorCasing': _c(0x20242A), 'rail': _c(0x5A6068),
  'boundary': _c(0x8A929C), 'boundaryMinor': _c(0x5A626C),
  'labelPlace': _c(0xE8EAED), 'labelMinor': _c(0xC9CED5), 'labelRoad': _c(0x9AA1AB), 'labelPath': _c(0x8A8478),
  'labelWater': _c(0x7FA6D6), 'labelWaterway': _c(0x6A9CCC), 'labelHalo': _c(0x0F1115, 0.85),
  'hillshadeShadow': _c(0x000000), 'hillshadeHighlight': _c(0x9AA6B5), 'hillshadeAccent': _c(0x05070A),
  'contour': _c(0xC8AA78, 0.35), 'contourIndex': _c(0xD7B987, 0.6), 'contourLabel': _c(0xD9BD8A),
  'publicLandsFill': _c(0x5FB98A, 0.12), 'publicLandsLine': _c(0x5FB98A, 0.7), 'trail': _c(0xE8955A),
  'mvum': _c(0xB48AE0), 'blm': _c(0xE0B45A),
  'position': _c(0x6BB4DE), 'positionAccuracy': _c(0x6BB4DE, 0.18), 'positionRing': _c(0x0F1115),
});

/// Parchment: warm paper, muted water, sepia lines.
final MapPalette _parchment = MapPalette(CacheThemeId.parchment, {
  'land': _c(0xEFE3C8), 'water': _c(0x9FB5A9), 'waterway': _c(0x7F9A8D), 'park': _c(0xD5D9B0),
  'parkEdge': _c(0xC0C696), 'wood': _c(0xC4CF9C, 0.75), 'grass': _c(0xD0D6A8), 'sand': _c(0xE6D6A6),
  'ice': _c(0xE7E4D2), 'wetland': _c(0xB9C9A4), 'residential': _c(0xC8AF82, 0.25), 'cemetery': _c(0xCDD2A6),
  'pitch': _c(0xD4D6A6), 'hospital': _c(0xE3C4B0), 'school': _c(0xE0D9B0), 'aeroway': _c(0xDCD0B2),
  'aerowayLine': _c(0xCDBD98), 'building': _c(0xD7C6A0), 'buildingEdge': _c(0xBFA97D),
  'roadMotorway': _c(0xE0A860), 'roadMajor': _c(0xEDD08A), 'roadMinor': _c(0xF8EFD8), 'roadPath': _c(0xFFF6DC),
  'roadMajorCasing': _c(0xB98A50), 'roadMinorCasing': _c(0xCDBF9E), 'rail': _c(0xA89878),
  'boundary': _c(0x8A7556), 'boundaryMinor': _c(0xB3A381),
  'labelPlace': _c(0x2B2118), 'labelMinor': _c(0x3D3226), 'labelRoad': _c(0x6B5A45), 'labelPath': _c(0x8B7355),
  'labelWater': _c(0x4F6B63), 'labelWaterway': _c(0x5F7F76), 'labelHalo': _c(0xF3E9D2, 0.85),
  'hillshadeShadow': _c(0x5A4630), 'hillshadeHighlight': _c(0xFFF8E6), 'hillshadeAccent': _c(0x6A5236),
  'contour': _c(0x6E4B28, 0.5), 'contourIndex': _c(0x5F3C1E, 0.85), 'contourLabel': _c(0x5A3A1A),
  'publicLandsFill': _c(0x6B8F4E, 0.2), 'publicLandsLine': _c(0x4F7A3A, 0.8), 'trail': _c(0xA3261C),
  'mvum': _c(0x6B3A7A), 'blm': _c(0x8A5A00),
  'position': _c(0x7A4E1D), 'positionAccuracy': _c(0x7A4E1D, 0.18), 'positionRing': _c(0xF3E9D2),
});

/// Tactical: black with reds only, so it does not spoil night vision. Every colour here has a red hue;
/// features are told apart by brightness, not hue.
final MapPalette _tactical = MapPalette(CacheThemeId.tactical, {
  'land': _c(0x000000), 'water': _c(0x2E0909), 'waterway': _c(0x6A1612), 'park': _c(0x120303),
  'parkEdge': _c(0x2A0808), 'wood': _c(0x150404, 0.8), 'grass': _c(0x110303), 'sand': _c(0x1A0808),
  'ice': _c(0x1F0A0A), 'wetland': _c(0x180505), 'residential': _c(0x3C0A0A, 0.35), 'cemetery': _c(0x160404),
  'pitch': _c(0x160404), 'hospital': _c(0x240606), 'school': _c(0x1C0505), 'aeroway': _c(0x1A0606),
  'aerowayLine': _c(0x2A0A0A), 'building': _c(0x240808), 'buildingEdge': _c(0x3A0D0D),
  'roadMotorway': _c(0xB02218), 'roadMajor': _c(0x8A1A14), 'roadMinor': _c(0x5A100D), 'roadPath': _c(0x7A1812),
  'roadMajorCasing': _c(0x000000), 'roadMinorCasing': _c(0x1A0505), 'rail': _c(0x6A1A14),
  'boundary': _c(0x8E2B24), 'boundaryMinor': _c(0x5C1C17),
  'labelPlace': _c(0xE0473C), 'labelMinor': _c(0xCC4136), 'labelRoad': _c(0xA8352C), 'labelPath': _c(0x8E2B24),
  'labelWater': _c(0x9A2A22), 'labelWaterway': _c(0x7A2420), 'labelHalo': _c(0x000000, 0.85),
  'hillshadeShadow': _c(0x000000), 'hillshadeHighlight': _c(0x7A1812), 'hillshadeAccent': _c(0x1A0303),
  'contour': _c(0xB42D23, 0.45), 'contourIndex': _c(0xDC3C30, 0.7), 'contourLabel': _c(0xE0473C),
  'publicLandsFill': _c(0xB23A2E, 0.14), 'publicLandsLine': _c(0xB23A2E, 0.75), 'trail': _c(0xFF5A4A),
  'mvum': _c(0xC24A1E), 'blm': _c(0x8E2B24),
  'position': _c(0xFF5A4A), 'positionAccuracy': _c(0xFF5A4A, 0.18), 'positionRing': _c(0x000000),
});

final Map<CacheThemeId, MapPalette> mapPalettes = {
  CacheThemeId.light: _light,
  CacheThemeId.dark: _dark,
  CacheThemeId.parchment: _parchment,
  CacheThemeId.tactical: _tactical,
};

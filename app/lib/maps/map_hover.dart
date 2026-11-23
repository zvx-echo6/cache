import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart' show LayerProperties;

/// Mouse hover on the map: the feature under the mouse is drawn in the highlight colour and the cursor shows it can be clicked.
/// Browser and Linux desktop only (the Linux build is the web build); a phone has no mouse and is unchanged.
bool mouseHoverOn({required bool web, required bool linuxDesktop}) => web || linuxDesktop;

/// What the mouse is over: the layers a feature was found in, and its name (null when it has none: the cursor still shows it is
/// clickable, but there is nothing to match a colour on).
class HoverTarget {
  const HoverTarget(this.layers, this.name);
  final List<String> layers;
  final String? name;

  @override
  bool operator ==(Object other) => other is HoverTarget && other.name == name && other.layers.join('\u0000') == layers.join('\u0000');

  @override
  int get hashCode => Object.hash(name, layers.join('\u0000'));
}

/// The layers of a style as it was applied, by id (their type and paint are what a highlight is made from and put back to).
Map<String, Map<String, dynamic>> styleLayersById(String? styleJson) {
  if (styleJson == null) return const {};
  try {
    final s = jsonDecode(styleJson);
    final layers = s is Map ? s['layers'] : null;
    if (layers is! List) return const {};
    return {
      for (final l in layers)
        if (l is Map && l['id'] is String) l['id'] as String: Map<String, dynamic>.from(l),
    };
  } catch (_) {
    return const {};
  }
}

// The paint a highlight changes, by layer type, with what the property is when the style does not say.
const Map<String, Map<String, Object>> _hoverKeys = {
  'symbol': {'text-color': '#000000', 'text-halo-width': 0},
  'circle': {'circle-color': '#000000'},
  'line': {'line-color': '#000000'},
  'fill': {'fill-color': '#000000'},
};

/// The paint of a [layer] (a style layer's JSON) with the feature called [name] in [colour] and every other feature as the style
/// has it. A symbol's text is also given a wider halo, so it stands out. Empty for a layer that has nothing to highlight.
Map<String, Object?> hoverPaint(Map<String, dynamic> layer, String name, String colour) {
  final keys = _hoverKeys[layer['type']];
  if (keys == null) return const {};
  final paint = layer['paint'] is Map ? layer['paint'] as Map : const {};
  final out = <String, Object?>{};
  for (final e in keys.entries) {
    final rest = paint[e.key] ?? e.value;
    final hovered = e.key == 'text-halo-width' ? 2 : colour;
    out[e.key] = [
      'case',
      ['==', ['get', 'name'], name],
      hovered,
      rest,
    ];
  }
  return out;
}

/// The paint [hoverPaint] changed, as the style has it.
Map<String, Object?> restPaint(Map<String, dynamic> layer) {
  final keys = _hoverKeys[layer['type']];
  if (keys == null) return const {};
  final paint = layer['paint'] is Map ? layer['paint'] as Map : const {};
  return {for (final e in keys.entries) e.key: paint[e.key] ?? e.value};
}

/// Paint properties sent as they are (the typed ones send every field, and a field left empty resets that property).
class RawPaint implements LayerProperties {
  const RawPaint(this.paint);
  final Map<String, Object?> paint;

  @override
  Map<String, dynamic> toJson({bool skipNulls = true}) => Map<String, dynamic>.from(paint);
}

/// Keeps the one highlighted feature: draws it when the mouse comes onto it, puts the layers back when it goes.
class MapHover {
  MapHover({required this.apply});

  /// Sets paint properties on a layer of the map.
  final Future<void> Function(String layerId, Map<String, Object?> paint) apply;

  HoverTarget? _current;
  HoverTarget? get current => _current;

  /// The style was applied again: its layers are as the style has them, so nothing is left to put back.
  void forget() => _current = null;

  /// Highlights [target] (null: nothing). [layerOf] gives a layer's JSON from the style; [colour] is the highlight colour.
  Future<void> show(HoverTarget? target, Map<String, Map<String, dynamic>> layerOf, String colour) async {
    if (target == _current) return;
    final old = _current;
    _current = target;
    if (old != null && old.name != null) {
      for (final id in old.layers) {
        final layer = layerOf[id];
        if (layer == null) continue;
        final paint = restPaint(layer);
        if (paint.isNotEmpty) await _apply(id, paint);
      }
    }
    if (target != null && target.name != null) {
      for (final id in target.layers) {
        final layer = layerOf[id];
        if (layer == null) continue;
        final paint = hoverPaint(layer, target.name!, colour);
        if (paint.isNotEmpty) await _apply(id, paint);
      }
    }
  }

  Future<void> _apply(String id, Map<String, Object?> paint) async {
    try {
      await apply(id, paint);
    } catch (_) {}
  }
}

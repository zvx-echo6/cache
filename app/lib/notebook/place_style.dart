import 'package:flutter/material.dart';

import 'notebook_model.dart';

/// A place's marker colour: a stored name, the colour drawn, and the name a screen reader says. Red is left out: it is kept for
/// "serious".
class MarkerColor {
  const MarkerColor(this.id, this.spoken, this.color);

  /// What the entry stores (`props.color`).
  final String id;
  final String spoken;
  final Color color;

  /// `#rrggbb`, for the map's pins.
  String get hex => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// The seven marker colours, in the order the swatches show.
const List<MarkerColor> kMarkerColors = [
  MarkerColor('orange', 'Orange', Color(0xFFE08A3C)),
  MarkerColor('yellow', 'Yellow', Color(0xFFE6C24E)),
  MarkerColor('green', 'Green', Color(0xFF7CC46A)),
  MarkerColor('teal', 'Teal', Color(0xFF3FBFAE)),
  MarkerColor('blue', 'Blue', Color(0xFF5AA7E6)),
  MarkerColor('purple', 'Purple', Color(0xFFAE86F0)),
  MarkerColor('sand', 'Sand', Color(0xFFD8C7A0)),
];

/// The colour named [id]; the first one for a name this Cache does not know (or none).
MarkerColor markerColor(String? id) => kMarkerColors.firstWhere((c) => c.id == id, orElse: () => kMarkerColors.first);

/// The colour a new place gets: the one fewest places of [entries] use, the first of those in swatch order.
MarkerColor defaultMarkerColor(Iterable<NbEntry> entries) {
  final counts = {for (final c in kMarkerColors) c.id: 0};
  for (final e in entries) {
    final c = e.color;
    if (c != null && counts.containsKey(c)) counts[c] = counts[c]! + 1;
  }
  var best = kMarkerColors.first;
  for (final c in kMarkerColors) {
    if (counts[c.id]! < counts[best.id]!) best = c;
  }
  return best;
}

/// A place's marker: filled in its colour when it is on the map, an outline with a slash when it is hidden (colour never
/// carries the meaning alone).
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({super.key, required this.color, this.hidden = false, this.size = 26});

  final MarkerColor color;
  final bool hidden;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Icon(hidden ? Icons.location_off_outlined : Icons.place, size: size, color: color.color);
}

import 'package:flutter/material.dart';

import '../theme.dart';
import 'pin_image.dart';

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

/// True in the Tactical theme (red only).
bool isTactical(BuildContext context) => context.t.accent == cacheTokens[CacheThemeId.tactical]!.accent;

/// [own] on the light and dark themes; the red of the theme in Tactical, where every pin is red and its icon tells them apart.
Color pinTint(BuildContext context, Color own) => isTactical(context) ? context.t.accent : own;

/// A pin in the person's pin style (Settings > Maps > Pin style), drawn by the code that makes the map's images, in a square of
/// [size]: for lists, the place screens and the long-press ring.
class PinGlyph extends StatelessWidget {
  const PinGlyph({super.key, required this.icon, required this.tint, required this.style, this.size = 28});

  final IconData icon;

  /// The colour already chosen for the theme (see [pinTint]).
  final Color tint;
  final PinStyle style;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tactical = isTactical(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PinGlyphPainter(icon, tint, style, tactical)),
    );
  }
}

class _PinGlyphPainter extends CustomPainter {
  _PinGlyphPainter(this.icon, this.tint, this.style, this.tactical);

  final IconData icon;
  final Color tint;
  final PinStyle style;
  final bool tactical;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    if (style == PinStyle.teardrop) {
      paintMapPin(canvas, Offset(s / 2, s * 0.94), s * 0.6, icon, tint, style, tactical: tactical);
    } else {
      paintMapPin(canvas, Offset(s / 2, s / 2), s * 0.74, icon, tint, style, tactical: tactical);
    }
  }

  @override
  bool shouldRepaint(_PinGlyphPainter old) => old.icon != icon || old.tint != tint || old.style != style || old.tactical != tactical;
}

/// A place's marker: filled in its colour when it is on the map, an outline with a slash when it is hidden (colour never
/// carries the meaning alone). With a map [icon] it is the place's pin in the person's [pinStyle].
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({super.key, required this.color, this.hidden = false, this.size = 26, this.icon, this.pinStyle});

  final MarkerColor color;
  final bool hidden;
  final double size;

  /// The place's map icon (its own, else its notebook's); the pin when null.
  final IconData? icon;

  /// How the icon is drawn; null draws the plain marker (no map icons).
  final PinStyle? pinStyle;

  @override
  Widget build(BuildContext context) {
    if (hidden || icon == null || pinStyle == null) {
      return Icon(hidden ? Icons.location_off_outlined : (icon ?? Icons.place), size: size, color: color.color);
    }
    return PinGlyph(icon: icon!, tint: pinTint(context, color.color), style: pinStyle!, size: size + 4);
  }
}

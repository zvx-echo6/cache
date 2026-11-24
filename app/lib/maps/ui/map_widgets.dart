import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../geo.dart';

/// Panels drawn over the map: the theme's surface colour, fully solid so the map's labels never show through. Only the small chips (the
/// scale, the credits) pass a lower [alpha] on purpose.
BoxDecoration mapPanel(BuildContext context, {double radius = 12, double alpha = 1}) {
  final k = context.t;
  return BoxDecoration(
    color: k.surface.withValues(alpha: alpha),
    borderRadius: BorderRadius.circular(radius),
    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 1))],
  );
}

/// A round 48-point button on the map.
class MapButton extends StatelessWidget {
  const MapButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.active = false, this.child});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Drawn in the accent colour (a mode that is on).
  final bool active;

  /// Replaces the icon (the compass needle).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: k.surface,
          elevation: 3,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(child: child ?? Icon(icon, size: 26, color: active ? k.accent : k.text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The compass needle: points to north, so it turns against the map's bearing.
class CompassNeedle extends StatelessWidget {
  const CompassNeedle({super.key, required this.bearing});

  /// Degrees the map is turned clockwise.
  final double bearing;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Transform.rotate(
      angle: -bearing * math.pi / 180,
      child: Icon(Icons.navigation, size: 26, color: k.emergency),
    );
  }
}

/// A scale bar, in miles and feet above and kilometres and metres below, so either reading works.
class ScaleBarWidget extends StatelessWidget {
  const ScaleBarWidget({super.key, required this.lat, required this.zoom, this.maxWidth = 120});

  final double lat;
  final double zoom;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final mpp = metersPerPoint(lat, zoom);
    final us = imperialScale(mpp, maxWidth);
    final si = metricScale(mpp, maxWidth);
    final style = TextStyle(fontSize: 11, color: k.text, fontWeight: FontWeight.w600, height: 1.1);
    Widget bar(ScaleBar b, {required bool labelAbove}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (labelAbove) Text(b.label, style: style),
            Container(
              width: b.widthPoints,
              height: 5,
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: k.text, width: 1.5),
                  right: BorderSide(color: k.text, width: 1.5),
                  bottom: BorderSide(color: k.text, width: 1.5),
                ),
              ),
            ),
            if (!labelAbove) Text(b.label, style: style),
          ],
        );
    return Semantics(
      label: 'Scale ${us.label}, ${si.label}',
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
        decoration: mapPanel(context, radius: 6, alpha: 0.75),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [bar(us, labelAbove: true), const SizedBox(height: 2), bar(si, labelAbove: false)],
        ),
      ),
    );
  }
}

/// The map credits. [folded] false: the credit line ("© OpenStreetMap contributors · Protomaps"), shown when the map first opens in a
/// launch (OpenStreetMap asks for the credit to be shown before it is collapsed). [folded] true: a small (i) button, 28 points
/// across in a 44 point touch area. Either way a tap opens the full credits (their sheet).
class AttributionChip extends StatelessWidget {
  const AttributionChip({super.key, required this.lines, required this.onTap, this.folded = false});

  final List<String> lines;
  final VoidCallback onTap;
  final bool folded;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      button: true,
      label: 'Map credits',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: folded
              // A 44-point target around a 28-point button.
              ? SizedBox(
                  key: const ValueKey('credits-button'),
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: mapPanel(context, radius: 14, alpha: 0.85),
                      child: Icon(Icons.info_outline, size: 18, color: k.secondary),
                    ),
                  ),
                )
              : Container(
                  key: const ValueKey('credits-line'),
                  constraints: const BoxConstraints(minHeight: 28),
                  padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
                  decoration: mapPanel(context, radius: 6, alpha: 0.78),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          lines.join(' · '),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: k.secondary, height: 1.2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.info_outline, size: 15, color: k.secondary),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// The small line when a visible layer has nothing to draw here and there is no connection.
class NoticePill extends StatelessWidget {
  const NoticePill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: mapPanel(context, radius: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 18, color: k.warning),
            const SizedBox(width: 8),
            Flexible(child: Text(text, style: TextStyle(fontSize: 14, color: k.text))),
          ],
        ),
      ),
    );
  }
}

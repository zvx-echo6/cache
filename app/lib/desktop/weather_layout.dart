import 'package:flutter/material.dart';

import '../layout/adaptive.dart' show ContentWidth;
import '../theme.dart';
import 'desktop.dart';

/// The widest Weather's page is on the Linux desktop.
const double kWeatherMaxWidth = 1200;

/// The widest the empty Weather card is.
const double kWeatherEmptyCardWidth = 480;

/// Weather's page padding. On the Linux desktop the page is left-aligned on the page gutter (centred while it shows only the empty card),
/// at most [kWeatherMaxWidth] wide; anywhere else it is the phone's, as it always was.
EdgeInsets weatherPadding(BuildContext context, double width, {bool centered = false}) {
  final m = DesktopMetrics.of(context);
  if (m == null) return ContentWidth.padFor(width, min: 16).copyWith(top: 4, bottom: 24);
  final side = centered ? m.gutter : (width - m.gutter - kWeatherMaxWidth).clamp(m.gutter, double.infinity).toDouble();
  return EdgeInsets.fromLTRB(m.gutter, 24, side, 24);
}

/// The Dashboard template for the populated page. On a phone, and under 1280, one column: the top card, what is happening nearby,
/// then the forecast and the credits, 12 apart. From 1280 the top card and the forecast are the main column (about 62 percent) and
/// what is happening nearby is a side column (38 percent), 24 apart. With nothing happening nearby to show it is one column.
class WeatherColumns extends StatelessWidget {
  const WeatherColumns({super.key, required this.top, required this.nearby, required this.below});

  /// The top card, and the one plain line when there is one.
  final List<Widget> top;

  /// "Happening nearby".
  final List<Widget> nearby;

  /// The forecast and the credits.
  final List<Widget> below;

  static const double _gap = 12;

  static List<Widget> _spaced(List<Widget> parts) => [
    for (var i = 0; i < parts.length; i++) ...[
      if (i > 0) const SizedBox(height: _gap),
      parts[i],
    ],
  ];

  @override
  Widget build(BuildContext context) {
    if (!isLinuxWide(context) || nearby.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced([...top, ...nearby, ...below]));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 62, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced([...top, ...below]))),
        const SizedBox(width: 24),
        Expanded(flex: 38, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(nearby))),
      ],
    );
  }
}

/// The empty Weather page on the Linux desktop: one card, centred and at most [kWeatherEmptyCardWidth] wide, with the status line on
/// top and the page's words and buttons under it.
class WeatherEmptyCard extends StatelessWidget {
  const WeatherEmptyCard({super.key, required this.status, required this.child});

  final Widget status;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kWeatherEmptyCardWidth),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: k.secondary.withValues(alpha: 0.2))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                status,
                Divider(height: 1, thickness: 1, color: k.secondary.withValues(alpha: 0.2)),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

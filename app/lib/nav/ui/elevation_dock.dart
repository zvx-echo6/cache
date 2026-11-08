import 'package:flutter/material.dart';

import '../../maps/palette/map_palette.dart';
import '../../maps/ui/map_widgets.dart';
import '../elevation/route_elevation.dart';
import '../nav_state.dart';
import 'elevation_panel.dart';
import 'guidance_panels.dart';

/// The guidance card at the foot: the elevation panel (when pulled up), the handle that pulls it up, and the guidance bar. The
/// handle stays when the route has no elevation data; the panel then says so in one line.
class GuidanceDock extends StatelessWidget {
  const GuidanceDock({super.key, required this.nav, required this.elevation, required this.palette});

  final NavState nav;
  final RouteElevation elevation;
  final MapPalette palette;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: elevation,
      builder: (context, _) => Container(
        key: const ValueKey('guidance-dock'),
        clipBehavior: Clip.antiAlias,
        decoration: mapPanel(context, radius: 20, alpha: 0.98),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (elevation.open)
              ElevationPanel(
                elevation: elevation,
                fmt: nav.fmt,
                palette: palette,
                distanceAlongM: nav.progress?.distanceAlongM,
                routeM: nav.route?.distanceM ?? 0,
              ),
            ElevationHandle(elevation: elevation),
            GuidanceBar(nav: nav, fmt: nav.fmt, bare: true),
          ],
        ),
      ),
    );
  }
}

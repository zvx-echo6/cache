import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../nav_state.dart';
import '../units.dart';

/// The top pill while choosing how to go: where to, and the way back to the map.
class DirectionsHeader extends StatelessWidget {
  const DirectionsHeader({super.key, required this.nav});

  final NavState nav;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final to = nav.selected;
    return Container(
      decoration: mapPanel(context, radius: 28, alpha: 0.97),
      child: Row(
        children: [
          IconButton(tooltip: 'Back', icon: Icon(Icons.arrow_back, color: k.text), onPressed: nav.cancelDirections),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Directions to', style: TextStyle(fontSize: 13, color: k.secondary)),
                Text(to?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }
}

/// How to go: the way of travel, the routes (the best and its alternatives, with the road and off-road parts told apart), and Start.
class RoutePanel extends StatelessWidget {
  const RoutePanel({super.key, required this.nav, required this.fmt});

  final NavState nav;
  final Fmt fmt;

  static const _modes = [('drive', Icons.directions_car, 'Drive'), ('walk', Icons.directions_walk, 'Walk'), ('bike', Icons.directions_bike, 'Bike')];
  static const _offroadModes = [('offroad_foot', 'On foot'), ('offroad_vehicle', 'Vehicle')];
  static const _landAccess = [('strict', 'Stay on open land'), ('pragmatic', 'Usual'), ('emergency', 'Emergency: any land')];

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      decoration: mapPanel(context, radius: 20, alpha: 0.98),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final m in _modes)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _ModeButton(
                        key: ValueKey('mode-${m.$1}'),
                        icon: m.$2,
                        label: m.$3,
                        selected: nav.mode == m.$1,
                        onTap: () => nav.setMode(m.$1),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _ModeButton(
                      key: const ValueKey('mode-offroad'),
                      icon: Icons.terrain,
                      label: 'Off-road',
                      selected: nav.offroad,
                      onTap: () => nav.setMode(nav.offroadMode),
                    ),
                  ),
                ),
              ],
            ),
            if (nav.offroad) ...[
              const SizedBox(height: 8),
              _Choices(
                choices: _offroadModes,
                selected: nav.mode,
                keyPrefix: 'offroad-mode',
                onSelected: nav.setMode,
              ),
              const SizedBox(height: 6),
              _Choices(
                choices: _landAccess,
                selected: nav.landAccess,
                keyPrefix: 'land',
                onSelected: nav.setLandAccess,
              ),
              if (nav.landAccess == 'emergency')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Ignores land rules: the route may cross private or closed land.',
                      key: const ValueKey('land-emergency-warning'), style: TextStyle(fontSize: 14, color: k.warning)),
                ),
            ],
            const SizedBox(height: 10),
            if (nav.routing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: k.accent)),
                    const SizedBox(width: 12),
                    Text('Finding the way', style: TextStyle(fontSize: 17, color: k.secondary)),
                  ],
                ),
              )
            else if (nav.routeError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(nav.routeError!, key: const ValueKey('route-error'), style: TextStyle(fontSize: 17, color: k.emergency)),
              )
            else ...[
              for (var i = 0; i < nav.routes.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RouteCard(index: i, route: nav.routes[i], selected: i == nav.routeIndex, fmt: fmt, onTap: () => nav.selectRoute(i)),
                ),
              if (nav.route?.hasOffroad ?? false) _OffroadNote(route: nav.route!, fmt: fmt),
            ],
            const SizedBox(height: 4),
            FilledButton.icon(
              key: const ValueKey('route-start'),
              onPressed: nav.route == null || nav.routing ? null : nav.start,
              icon: const Icon(Icons.navigation),
              label: const Text('Start'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({super.key, required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? k.accent.withValues(alpha: 0.2) : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? k.accent : k.secondary.withValues(alpha: 0.5))),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 22, color: selected ? k.accent : k.secondary),
                    const SizedBox(width: 6),
                    Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: selected ? k.accent : k.text)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of choices, one selected (the off-road way of travel, the land access).
class _Choices extends StatelessWidget {
  const _Choices({required this.choices, required this.selected, required this.keyPrefix, required this.onSelected});

  final List<(String, String)> choices;
  final String selected;
  final String keyPrefix;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final c in choices)
          ChoiceChip(
            key: ValueKey('$keyPrefix-${c.$1}'),
            label: Text(c.$2, style: TextStyle(fontSize: 15, color: selected == c.$1 ? k.accent : k.text)),
            selected: selected == c.$1,
            showCheckmark: false,
            selectedColor: k.accent.withValues(alpha: 0.2),
            side: BorderSide(color: selected == c.$1 ? k.accent : k.secondary.withValues(alpha: 0.5)),
            onSelected: (_) => onSelected(c.$1),
          ),
      ],
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.index, required this.route, required this.selected, required this.fmt, required this.onTap});

  final int index;
  final MapRoute route;
  final bool selected;
  final Fmt fmt;
  final VoidCallback onTap;

  /// The main road of the route, for telling alternatives apart.
  String _via() {
    for (final m in route.maneuvers) {
      if (m.streetNames.isNotEmpty && m.distanceM > 0) {
        return 'via ${m.streetNames.first}';
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final via = (route.raw['major_roads'] is List && (route.raw['major_roads'] as List).isNotEmpty)
        ? 'via ${((route.raw['major_roads'] as List).first as Map)['name']}'
        : _via();
    return Semantics(
      button: true,
      selected: selected,
      label: 'Route ${index + 1}, ${fmt.duration(route.durationS)}, ${fmt.distance(route.distanceM)}',
      child: Material(
        color: selected ? k.accent.withValues(alpha: 0.14) : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? k.accent : k.secondary.withValues(alpha: 0.4))),
        child: InkWell(
          key: ValueKey('route-card-$index'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(fmt.duration(route.durationS), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: selected ? k.accent : k.text)),
                      if (via.isNotEmpty) Text(via, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(fmt.distance(route.distanceM), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                    if (route.hasOffroad) Text('${fmt.distance(route.totals.offroadM)} off-road', style: TextStyle(fontSize: 14, color: k.warning)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What an off-road route asks of the person, before they start.
class _OffroadNote extends StatelessWidget {
  const _OffroadNote({required this.route, required this.fmt});

  final MapRoute route;
  final Fmt fmt;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final t = route.totals;
    final parts = <String>[
      'Part of this route has no road: ${fmt.distance(t.offroadM)} over open ground, shown dashed.',
      if (t.ascentM > 0 || t.descentM > 0) 'Climb ${fmt.height(t.ascentM)}, descent ${fmt.height(t.descentM)}.',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.terrain, size: 20, color: k.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(parts.join(' '), key: const ValueKey('offroad-note'), style: TextStyle(fontSize: 14, height: 1.3, color: k.secondary))),
        ],
      ),
    );
  }
}

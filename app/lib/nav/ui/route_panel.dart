import 'package:cache_search/cache_search.dart';
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../nav_state.dart';
import '../street_names.dart';
import '../units.dart';
import 'travel_rows.dart';

/// The top pill while choosing how to go: where to, and the way back to the map.
class DirectionsHeader extends StatelessWidget {
  const DirectionsHeader({super.key, required this.nav});

  final NavState nav;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final to = nav.selected;
    return Container(
      decoration: mapPanel(context, radius: 28),
      child: Row(
        children: [
          IconButton(tooltip: 'Back', icon: Icon(Icons.arrow_back, color: k.text), onPressed: nav.cancelDirections),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Where to: the destination on the map.
                InkWell(
                  key: const ValueKey('directions-to'),
                  onTap: to == null ? null : () => nav.showOnMap(to.point),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Directions to', style: TextStyle(fontSize: 13, color: k.secondary)),
                      Text(to?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                    ],
                  ),
                ),
                if (nav.fromPlace case final f?)
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => nav.showOnMap(f.point),
                          child: Text('From ${f.name}', key: const ValueKey('directions-from'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('directions-from-clear'),
                        tooltip: 'Start from your location',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        icon: Icon(Icons.close, size: 18, color: k.secondary),
                        onPressed: nav.clearFrom,
                      ),
                    ],
                  ),
                // The intermediate stops: dragged by their handle (not while guiding); From and the destination stay put.
                ReorderableListView(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  proxyDecorator: (child, index, animation) => Material(
                    color: k.surface,
                    elevation: 4,
                    shape: Border(left: BorderSide(color: k.accent, width: 3)),
                    child: child,
                  ),
                  onReorderItem: (from, end) {
                    // [end] is the place the stop ends up in, which is what the nav state takes.
                    if (end == from) return;
                    nav.reorderStop(from, end);
                    ScaffoldMessenger.maybeOf(context)
                      ?..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(content: Text('Stop order changed')));
                  },
                  children: [
                    for (final (i, stop) in nav.stops.indexed)
                      Row(
                        key: ValueKey('stop-$i'),
                        children: [
                          if (!nav.guiding)
                            ReorderableDragStartListener(
                              key: ValueKey('stop-handle-$i'),
                              index: i,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: SizedBox(width: 44, height: 44, child: Icon(Icons.drag_handle, size: 18, color: k.secondary)),
                              ),
                            ),
                          Expanded(
                            child: InkWell(
                              key: ValueKey('stop-show-$i'),
                              onTap: () => nav.showOnMap(stop.point),
                              child: Text('Stop ${i + 1}: ${stop.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.text)),
                            ),
                          ),
                          IconButton(
                            key: ValueKey('stop-remove-$i'),
                            tooltip: 'Remove stop ${i + 1}',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                            icon: Icon(Icons.close, size: 18, color: k.secondary),
                            onPressed: () => nav.removeStop(i),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }
}

/// How to go: the way of travel, one line for the chosen route (its time, distance and road) and Start. The other routes, the
/// elevation and the notes are one tap away on the route line ([_showDetails]).
class RoutePanel extends StatelessWidget {
  const RoutePanel({super.key, required this.nav, required this.fmt, this.maxHeight, this.elevation, this.onNextTurn, this.onDownloadArea, this.onAddOffroad, this.onSwipeDown});

  final NavState nav;
  final Fmt fmt;

  /// A swipe down on the panel: back to the place (the same as the arrow on the top pill). Null: the panel does not take it.
  final VoidCallback? onSwipeDown;

  /// "Download this area" under a route outside the downloaded maps ([NavState.outsideMaps]): the download for the route's area.
  /// Null leaves it out.
  final VoidCallback? onDownloadArea;

  /// "Add off-road data" under an off-road route with no off-road data ([NavState.offroadDataMissing]): the off-road data for the
  /// route's area. Null leaves it out.
  final VoidCallback? onAddOffroad;

  /// The next arrow beside Start: shows the route's first turn (the step card). Null leaves the arrow out.
  final VoidCallback? onNextTurn;

  /// The chosen route's elevation (RouteElevationSummary), in the route details; null leaves it out.
  final Widget? elevation;

  /// The most the panel may take (the map's side column); null: the choices take up to half the window, as a bottom panel.
  final double? maxHeight;

  void _showDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: nav,
          builder: (ctx, _) {
            final k = ctx.t;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('Route details', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
                  ),
                  for (var i = 0; i < nav.routes.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _RouteCard(index: i, route: nav.routes[i], selected: i == nav.routeIndex, fmt: fmt, onTap: () => nav.selectRoute(i)),
                    ),
                  if (nav.routes.isNotEmpty && elevation != null) elevation!,
                  if (nav.route?.hasOffroad ?? false) _OffroadNote(route: nav.route!, fmt: fmt),
                  if (nav.route case final r? when r.notes.isNotEmpty) _RouteNotes(notes: r.notes),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final r = nav.route;
    final ready = r != null && !nav.routing;
    // At large text the route line does not fit beside the buttons (it would shrink): it goes in the scrolling part, under the rows,
    // so the panel never grows past its cap, and the buttons stay at the foot.
    final big = MediaQuery.textScalerOf(context).scale(10) > 11.5;
    final summary = r == null || nav.routing || nav.routeError != null ? null : _RouteSummary(route: r, fmt: fmt, onTap: () => _showDetails(context), wrap: big);
    final panel = Container(
      decoration: mapPanel(context, radius: 20),
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The three rows (and a route error) scroll only when taller than about half the screen (large text).
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight == null ? MediaQuery.sizeOf(context).height * 0.5 : (maxHeight! - 70).clamp(120.0, double.infinity)),
              child: _ChoicesScroll(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TravelChoicesView(nav: nav),
                    if (nav.routing)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
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
                        padding: const EdgeInsets.only(top: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(nav.routeError!, key: const ValueKey('route-error'), style: TextStyle(fontSize: 17, color: k.emergency)),
                            if (nav.outsideMaps && onDownloadArea != null) ...[
                              const SizedBox(height: 8),
                              FilledButton.icon(key: const ValueKey('route-download-area'), onPressed: onDownloadArea, icon: const Icon(Icons.download), label: const Text('Download this area')),
                            ],
                            if (nav.offroadDataMissing && onAddOffroad != null) ...[
                              const SizedBox(height: 8),
                              FilledButton.icon(key: const ValueKey('route-add-offroad'), onPressed: onAddOffroad, icon: const Icon(Icons.terrain_outlined), label: const Text('Add off-road data')),
                            ],
                            if (nav.offroadDataMissing) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(child: OutlinedButton.icon(key: const ValueKey('offroad-instead-walk'), onPressed: () => nav.setMode('walk'), icon: const Icon(Icons.directions_walk), label: const Text('Walk'))),
                                  const SizedBox(width: 8),
                                  Expanded(child: OutlinedButton.icon(key: const ValueKey('offroad-instead-drive'), onPressed: () => nav.setMode('drive'), icon: const Icon(Icons.directions_car), label: const Text('Drive'))),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (big && summary != null) Padding(padding: const EdgeInsets.only(top: 8), child: summary),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Builder(builder: (context) {
                final next = onNextTurn == null
                    ? null
                    : IconButton.outlined(
                        key: const ValueKey('step-next'),
                        tooltip: 'Next',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: !ready || r.maneuvers.isEmpty ? null : onNextTurn,
                      );
                final start = FilledButton.icon(
                  key: const ValueKey('route-start'),
                  onPressed: ready ? nav.start : null,
                  icon: const Icon(Icons.navigation),
                  label: const Text('Start'),
                );
                if (big) return Row(children: [if (next != null) ...[next, const SizedBox(width: 8)], Expanded(child: start)]);
                return Row(
                  children: [
                    // The chosen route in one line; a tap opens the details (the other routes, elevation, notes).
                    Expanded(child: summary ?? const SizedBox(height: 48)),
                    if (next != null) ...[const SizedBox(width: 8), next],
                    const SizedBox(width: 8),
                    start,
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
    if (onSwipeDown == null) return panel;
    return _SwipeDown(key: const ValueKey('route-panel-swipe'), onSwipeDown: onSwipeDown!, child: panel);
  }
}

/// A quick swipe down anywhere on the panel (the choices included, which scroll): [onSwipeDown]. Read from the raw pointer events, so
/// the choices' own scroll does not swallow it; a drag that scrolled the choices is theirs and does not count.
class _SwipeDown extends StatefulWidget {
  const _SwipeDown({super.key, required this.onSwipeDown, required this.child});

  final VoidCallback onSwipeDown;
  final Widget child;

  @override
  State<_SwipeDown> createState() => _SwipeDownState();
}

class _SwipeDownState extends State<_SwipeDown> {
  final Map<int, VelocityTracker> _trackers = {};
  final Map<int, Offset> _starts = {};
  bool _scrolled = false;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        if ((n.scrollDelta ?? 0) != 0) _scrolled = true;
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (_trackers.isEmpty) _scrolled = false;
          _trackers[e.pointer] = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.position);
          _starts[e.pointer] = e.position;
        },
        onPointerMove: (e) => _trackers[e.pointer]?.addPosition(e.timeStamp, e.position),
        onPointerCancel: (e) {
          _trackers.remove(e.pointer);
          _starts.remove(e.pointer);
        },
        onPointerUp: (e) {
          final t = _trackers.remove(e.pointer), start = _starts.remove(e.pointer);
          if (t == null || start == null || _scrolled || _trackers.isNotEmpty) return;
          final v = t.getVelocity().pixelsPerSecond;
          final d = e.position - start;
          // Down, mostly vertical, far enough and fast enough: not a tap, not a slow drag.
          if (d.dy >= 40 && d.dy.abs() > d.dx.abs() * 1.5 && v.dy >= 300) widget.onSwipeDown();
        },
        child: widget.child,
      ),
    );
  }
}

/// The chosen route in one line: its time and distance, and under them its road (and the off-road part when it has one).
class _RouteSummary extends StatelessWidget {
  const _RouteSummary({required this.route, required this.fmt, required this.onTap, this.wrap = false});

  final MapRoute route;
  final Fmt fmt;
  final VoidCallback onTap;

  /// Large text: the lines are not squeezed to one line each, they wrap.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final roads = route.raw['major_roads'];
    final major = roads is List && roads.isNotEmpty ? majorRoadShown(roads.first) : null;
    final via = major != null ? 'via $major' : '';
    return Semantics(
      button: true,
      label: 'Route, ${fmt.duration(route.durationS)}, ${fmt.distance(route.distanceM)}. Route details',
      child: InkWell(
        key: const ValueKey('route-summary'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: wrap ? const EdgeInsets.symmetric(vertical: 4) : EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _fit(wrap, Text('${fmt.duration(route.durationS)} \u00b7 ${fmt.distance(route.distanceM)}', maxLines: 1, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.15, color: k.accent))),
                      if (route.hasOffroad || via.isNotEmpty)
                        Text.rich(
                          TextSpan(children: [
                            if (route.hasOffroad) TextSpan(text: '${fmt.distance(route.totals.offroadM)} off-road', style: TextStyle(color: k.warning)),
                            if (via.isNotEmpty && route.hasOffroad) TextSpan(text: ' \u00b7 ', style: TextStyle(color: k.secondary)),
                            if (via.isNotEmpty) TextSpan(text: via, style: TextStyle(color: k.secondary)),
                          ]),
                          maxLines: wrap ? 3 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, height: 1.15),
                        ),
                    ],
                  ),
                ),
              ),
              Icon(Icons.expand_less, size: 22, color: k.secondary),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _fit(bool wrap, Widget c) => wrap ? c : Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: c));

/// The colour of the bar beside the choices while there is more of them than fits (see [_ChoicesScroll]).
Color routeChoicesBarColor(CacheTokens k) => k.secondary.withValues(alpha: 0.6);

/// The panel's choices above Start: they scroll when taller than their room, and a thin bar at the right edge, in the panel's
/// own margin, shows for as long as there is more than fits (nothing is drawn when everything fits).
class _ChoicesScroll extends StatefulWidget {
  const _ChoicesScroll({required this.child});

  final Widget child;

  @override
  State<_ChoicesScroll> createState() => _ChoicesScrollState();
}

class _ChoicesScrollState extends State<_ChoicesScroll> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawScrollbar(
      key: const ValueKey('route-choices-bar'),
      controller: _scroll,
      thumbVisibility: true,
      thumbColor: routeChoicesBarColor(context.t),
      thickness: 4,
      radius: const Radius.circular(2),
      crossAxisMargin: 6,
      mainAxisMargin: 2,
      // The bar runs the whole height of the choices: they are inside the panel, not under the status bar (whose room the bar
      // would otherwise leave free at its top).
      padding: EdgeInsets.zero,
      // A computer's window would add a bar of its own to the scroll view: this one is the only one.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(right: 16),
          child: widget.child,
        ),
      ),
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
      final road = m.shownRoadName;
      if (road != null && m.distanceM > 0) {
        return 'via $road';
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final roads = route.raw['major_roads'];
    final major = roads is List && roads.isNotEmpty ? majorRoadShown(roads.first) : null;
    final via = major != null ? 'via $major' : _via();
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
      'Part of this route is off-road: ${fmt.distance(t.offroadM)}, shown dashed.',
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

/// How the route was made, in plain words: what the area's data lacks and what was used instead.
class _RouteNotes extends StatelessWidget {
  const _RouteNotes({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final n in notes)
            Text(n, key: const ValueKey('route-note'), style: TextStyle(fontSize: 14, height: 1.3, color: k.secondary)),
        ],
      ),
    );
  }
}

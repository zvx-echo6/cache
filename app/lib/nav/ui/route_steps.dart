import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../nav_state.dart';
import 'drive_screen.dart';
import 'lane_strip.dart';

// PLACEHOLDER: the owner chooses the final words
/// The route panel's button that opens the step card (beside Start).
const String kStepThroughLabel = 'Step through';

// PLACEHOLDER: the owner chooses the final words
/// The step card's counter: {n} is the turn shown, {total} how many the route has ("3 of 18").
const String kStepCounterFormat = '{n} of {total}';

/// The counter's words for turn [n] (from 1) of [total].
String stepCounterText(int n, int total) => kStepCounterFormat.replaceAll('{n}', '$n').replaceAll('{total}', '$total');

/// The zoom the map comes to at each turn while stepping through the route: a street's.
const double kStepZoom = 17;

/// How far a finger must move sideways on the step card, or how fast, for the card to step.
const double kStepSwipeDistance = 40;
const double kStepSwipeSpeed = 300;

/// The turns of the route shown before Start, in order, as the drive screen's rows: every maneuver of the route from the start to
/// the arrival, each with how far it is from the one before, and a stop ("via") with its number and name. Before the drive the
/// n-th stop maneuver is the n-th of the stops the route was asked through ([NavState.numberedStopsAhead]), as
/// [DriveTurns.rowsAfterNext] numbers them during the drive. Empty with no route.
List<DriveRow> previewStepRows(NavState nav) {
  final r = nav.route;
  if (r == null) return const [];
  final stops = nav.numberedStopsAhead;
  var stopAt = 0;
  final rows = <DriveRow>[];
  for (final (i, m) in r.maneuvers.indexed) {
    final distance = i == 0 ? 0.0 : r.maneuvers[i - 1].distanceM;
    if (m.type == 'via') {
      final stop = stopAt < stops.length ? stops[stopAt] : null;
      stopAt++;
      rows.add(DriveRow(maneuver: m, distanceM: distance, stopNumber: stop?.$1 ?? stopAt, stopName: stop?.$2.name));
    } else {
      rows.add(DriveRow(maneuver: m, distanceM: distance));
    }
  }
  return rows;
}

/// The lanes of the route's [i]-th maneuver, as the route gave them (its JSON's `lanes`); none off-road, on arrival, or when the
/// road gave none.
List<Lane> previewStepLanes(MapRoute r, int i) {
  final all = r.raw['maneuvers'];
  if (all is! List || i < 0 || i >= all.length || i >= r.maneuvers.length) return const [];
  final m = r.maneuvers[i];
  if (m.isOffroad || m.isArrival) return const [];
  final j = all[i];
  return j is Map ? Lane.listFrom(j['lanes']) : const [];
}

/// The route preview's step card: one turn of the route at a time, drawn as the drive screen draws its turn rows (the arrow, the
/// router's words, how far, the lane arrows when the route has them, a stop's number and name), with the way back and forward
/// through the turns (also a sideways swipe on the card), the count, a close button and Start.
class RouteStepCard extends StatefulWidget {
  const RouteStepCard({super.key, required this.nav, required this.rows, required this.index, required this.onStep, required this.onClose});

  final NavState nav;

  /// The route's turns ([previewStepRows]) and the one shown.
  final List<DriveRow> rows;
  final int index;

  /// Asked to show the turn at this place in [rows].
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  State<RouteStepCard> createState() => _RouteStepCardState();
}

class _RouteStepCardState extends State<RouteStepCard> {
  double _drag = 0;

  bool get _canBack => widget.index > 0;
  bool get _canNext => widget.index < widget.rows.length - 1;

  void _back() {
    if (_canBack) widget.onStep(widget.index - 1);
  }

  void _next() {
    if (_canNext) widget.onStep(widget.index + 1);
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    // A finger moving to the left brings the next turn, as a page turns; to the right the one before.
    if (_drag <= -kStepSwipeDistance || v <= -kStepSwipeSpeed) {
      _next();
    } else if (_drag >= kStepSwipeDistance || v >= kStepSwipeSpeed) {
      _back();
    }
    _drag = 0;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final nav = widget.nav;
    final rows = widget.rows;
    if (rows.isEmpty) return const SizedBox.shrink();
    final i = widget.index.clamp(0, rows.length - 1);
    final row = rows[i];
    final r = nav.route;
    final lanes = r == null ? const <Lane>[] : previewStepLanes(r, i);
    return GestureDetector(
      key: const ValueKey('step-card'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _drag = 0,
      onHorizontalDragUpdate: (d) => _drag += d.primaryDelta ?? 0,
      onHorizontalDragEnd: _dragEnd,
      child: Container(
        decoration: mapPanel(context, radius: 20, alpha: 0.98),
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 14),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(stepCounterText(i + 1, rows.length), key: const ValueKey('step-counter'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.secondary)),
                  ),
                  IconButton(
                    key: const ValueKey('step-close'),
                    tooltip: 'Close',
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    icon: Icon(Icons.close, color: k.text),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: DriveTurns.rowHeight),
                  child: DriveTurnRow(key: ValueKey('step-row-${row.maneuver.index}'), row: row, fmt: nav.fmt, divider: false, maxLines: 3),
                ),
              ),
              if (lanes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
                  child: LaneStrip(key: const ValueKey('step-lanes'), lanes: lanes),
                ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    IconButton.outlined(
                      key: const ValueKey('step-back'),
                      tooltip: 'Previous',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _canBack ? _back : null,
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      key: const ValueKey('step-next'),
                      tooltip: 'Next',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: _canNext ? _next : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('step-start'),
                        onPressed: nav.route == null || nav.routing ? null : nav.start,
                        icon: const Icon(Icons.navigation),
                        label: const Text('Start'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

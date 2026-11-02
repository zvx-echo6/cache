import 'package:flutter/material.dart';

import '../../nav/ui/search_panel.dart' show bearingBetween, compass8;
import '../../nav/units.dart';
import '../../theme.dart';
import '../user_layers.dart';
import 'map_widgets.dart';

/// "4.2 mi NE" from [fromLat], [fromLon] to the repeater, with "from map centre" when the start is the map's centre (no position);
/// null when the repeater has no position.
String? repeaterDistance(Repeater r, Fmt fmt, {required double fromLat, required double fromLon, bool fromMapCentre = false}) {
  if (!r.located) return null;
  final d = RepeaterNotebookSource.metresBetween(fromLat, fromLon, r.lat!, r.lon!);
  final words = '${fmt.distance(d)} ${compass8(bearingBetween(fromLat, fromLon, r.lat!, r.lon!))}';
  return fromMapCentre ? '$words from map centre' : words;
}

/// What the core says for a setting the imported list did not have (cache_user's repeater words).
const String kNotInImportedList = 'not in the imported list';

/// The settings of one repeater, in the order a radio wants them: frequency (always), mode, offset, tone, then its town. A field
/// the list does not have is not shown (no "--").
List<(String, String)> repeaterFields(Repeater r) {
  String? have(String? v) => v == null || v == kNotInImportedList ? null : v;
  return [
    ('Frequency', r.frequency ?? 'Not in the list'),
    if (have(r.mode) case final m?) ('Mode', m),
    if (have(r.offset) case final o?) ('Offset', o),
    if (have(r.tone) case final t?) ('Tone', t),
    if (have(r.town) case final t?) ('Town', t),
  ];
}

/// The card of a repeater tapped on the map (the place card's frame): its callsign, "Repeater · 4.2 mi NE", its settings in two
/// columns, and Directions and Open in notebook.
class RepeaterCard extends StatelessWidget {
  const RepeaterCard({super.key, required this.repeater, required this.distance, required this.onClose, this.onDirections, this.onOpenList});

  final Repeater repeater;

  /// "4.2 mi NE" (see [repeaterDistance]); null leaves it out.
  final String? distance;
  final VoidCallback onClose;

  /// Directions to it, as from a place card; null greys the button (a route is being followed).
  final VoidCallback? onDirections;

  /// Its list notebook, at its row; null leaves the button out.
  final VoidCallback? onOpenList;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final r = repeater;
    final fields = repeaterFields(r);
    Widget cell((String, String) f) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 74, child: Text(f.$1, style: TextStyle(fontSize: 13, color: k.secondary))),
          Expanded(child: Text(f.$2, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: k.text))),
        ],
      ),
    );
    final rows = <Widget>[];
    // Two settings a line; the town takes a line of its own.
    final pairs = [for (final f in fields) if (f.$1 != 'Town') f];
    for (var i = 0; i < pairs.length; i += 2) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: cell(pairs[i])),
          const SizedBox(width: 10),
          Expanded(child: i + 1 < pairs.length ? cell(pairs[i + 1]) : const SizedBox.shrink()),
        ],
      ));
    }
    for (final f in fields.where((f) => f.$1 == 'Town')) {
      rows.add(cell(f));
    }
    return Container(
      key: const ValueKey('repeater-card'),
      decoration: mapPanel(context, radius: 20, alpha: 0.98),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name, key: const ValueKey('repeater-card-name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: k.text)),
                      const SizedBox(height: 2),
                      Text(['Repeater', ?distance].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: k.secondary)),
                    ],
                  ),
                ),
                IconButton(key: const ValueKey('repeater-card-close'), tooltip: 'Close', icon: Icon(Icons.close, color: k.secondary), onPressed: onClose),
              ],
            ),
            Divider(height: 18, color: k.secondary.withValues(alpha: 0.25), endIndent: 8),
            ...rows,
            Divider(height: 18, color: k.secondary.withValues(alpha: 0.25), endIndent: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              // Side by side when both fit at their full words; else one above the other (a phone), never cut.
              child: LayoutBuilder(
                builder: (context, c) {
                  final directions = FilledButton.icon(
                    key: const ValueKey('repeater-directions'),
                    onPressed: r.located ? onDirections : null,
                    icon: const Icon(Icons.directions),
                    label: const Text('Directions'),
                  );
                  final open = onOpenList == null
                      ? null
                      : OutlinedButton(key: const ValueKey('repeater-open-list'), onPressed: onOpenList, child: const Text('Open in notebook'));
                  if (open == null) return SizedBox(width: double.infinity, child: directions);
                  if (c.maxWidth >= 420 * MediaQuery.textScalerOf(context).scale(1)) {
                    return Row(children: [Expanded(child: directions), const SizedBox(width: 8), Expanded(child: open)]);
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [directions, const SizedBox(height: 8), open],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

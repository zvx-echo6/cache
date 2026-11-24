import 'package:flutter/material.dart';

import '../maps/ui/map_widgets.dart' show mapPanel;
import '../theme.dart';
import 'road_event.dart';

/// The card a tap on a road event opens (the place card's frame and spacing): the road as the title, "Road closure · Westbound" under it,
/// then lines for what the source gave (a field a site does not provide is left out, never "no detour"), the detour instructions, and the
/// credit with the age of the data. No buttons: Directions and Avoid are not offered.

/// "Road closure", "Crash or incident", "Road work".
String roadKindWords(RoadEventKind k) => switch (k) {
  RoadEventKind.closure => 'Road closure',
  RoadEventKind.crash => 'Crash or incident',
  RoadEventKind.work => 'Road work',
};

/// "Northbound".
String headingWords(Heading h) => switch (h) {
  Heading.north => 'Northbound',
  Heading.south => 'Southbound',
  Heading.east => 'Eastbound',
  Heading.west => 'Westbound',
};

/// "Updated 40 minutes ago" from the core's "40 minutes old"; the out-of-date form says so.
String roadAgeWords(String? age, {required bool stale}) {
  if (age == null || age.isEmpty) return stale ? 'Out of date' : '';
  final base = age.endsWith(' old') ? age.substring(0, age.length - 4) : age;
  return stale ? 'Out of date, last updated $base ago' : 'Updated $base ago';
}

/// One line of the card.
class RoadCardLine {
  const RoadCardLine(this.icon, this.text, {this.emphasis = false});

  final IconData icon;
  final String text;

  /// Drawn in the emergency colour (all lanes closed).
  final bool emphasis;
}

/// What the card says, from the event: separate from the widget so it is tested without drawing.
class RoadCardData {
  const RoadCardData({required this.title, required this.subtitle, required this.lines, required this.detour, required this.credit});

  final String title;
  final String subtitle;
  final List<RoadCardLine> lines;
  final List<String> detour;
  final String credit;
}

RoadCardData roadCardData(RoadEvent e) {
  String? f(String label) {
    final v = e.fields[label]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  final lanes = f('Lanes affected') ?? f('Lanes');
  final starts = f('Starts');
  final ends = f('Planned end') ?? f('Ends');
  final details = f('Details');
  final comment = f('Comment');
  final severity = f('Severity');
  final detour = e.detourSteps.isNotEmpty ? e.detourSteps : [?f('Detour')];
  return RoadCardData(
    title: e.road.isEmpty ? roadKindWords(e.kind) : e.road,
    subtitle: [roadKindWords(e.kind), if (e.heading != null) headingWords(e.heading!) else ?f('Direction')].join(' · '),
    lines: [
      if (e.fullClosure) const RoadCardLine(Icons.block, 'All lanes closed', emphasis: true) else if (lanes != null) RoadCardLine(Icons.alt_route, lanes),
      if (severity != null) RoadCardLine(Icons.priority_high, severity),
      if (starts != null) RoadCardLine(Icons.schedule, 'Starts $starts'),
      if (ends != null) RoadCardLine(Icons.event, 'Ends $ends'),
      if (details != null) RoadCardLine(Icons.notes, details),
      if (comment != null) RoadCardLine(Icons.chat_bubble_outline, comment),
    ],
    detour: detour,
    credit: [if (e.credit.isNotEmpty) e.credit, roadAgeWords(e.age, stale: e.stale)].where((s) => s.isNotEmpty).join(' · '),
  );
}

class RoadEventCard extends StatelessWidget {
  const RoadEventCard({super.key, required this.event, required this.onClose, this.maxHeight});

  final RoadEvent event;
  final VoidCallback onClose;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final d = roadCardData(event);
    final body = Column(
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
                  Text(d.title, key: const ValueKey('road-event-card-title'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: k.text)),
                  const SizedBox(height: 2),
                  Text(d.subtitle, key: const ValueKey('road-event-card-subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: k.secondary)),
                ],
              ),
            ),
            IconButton(key: const ValueKey('road-event-card-close'), tooltip: 'Close', icon: Icon(Icons.close, color: k.secondary), onPressed: onClose),
          ],
        ),
        if (d.lines.isNotEmpty || d.detour.isNotEmpty) Divider(height: 18, color: k.secondary.withValues(alpha: 0.25), endIndent: 8),
        for (final l in d.lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(l.icon, size: 18, color: l.emphasis ? k.emergency : k.secondary),
                const SizedBox(width: 10),
                Expanded(child: Text(l.text, style: TextStyle(fontSize: 15, color: l.emphasis ? k.emergency : k.text, fontWeight: l.emphasis ? FontWeight.w600 : null))),
              ],
            ),
          ),
        if (d.detour.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, right: 8),
            child: Row(
              key: const ValueKey('road-event-card-detour'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.turn_slight_right, size: 18, color: k.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Detour', style: TextStyle(fontSize: 13, color: k.secondary)),
                      for (final s in d.detour) Text(s, style: TextStyle(fontSize: 15, color: k.text)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (d.credit.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Text(d.credit, key: const ValueKey('road-event-card-credit'), style: TextStyle(fontSize: 12, color: k.secondary))),
      ],
    );
    return Container(
      key: const ValueKey('road-event-card'),
      decoration: mapPanel(context, radius: 20),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      constraints: maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight!),
      child: SafeArea(top: false, child: SingleChildScrollView(child: body)),
    );
  }
}

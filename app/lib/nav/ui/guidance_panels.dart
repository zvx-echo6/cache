import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../guidance.dart';
import '../nav_state.dart';
import '../units.dart';
import 'lane_strip.dart';

IconData iconForTurn(TurnIcon t) => switch (t) {
      TurnIcon.start => Icons.navigation,
      TurnIcon.straight => Icons.arrow_upward,
      TurnIcon.slightLeft => Icons.turn_slight_left,
      TurnIcon.left => Icons.turn_left,
      TurnIcon.sharpLeft => Icons.turn_sharp_left,
      TurnIcon.slightRight => Icons.turn_slight_right,
      TurnIcon.right => Icons.turn_right,
      TurnIcon.sharpRight => Icons.turn_sharp_right,
      TurnIcon.uTurn => Icons.u_turn_left,
      TurnIcon.roundabout => Icons.roundabout_left,
      TurnIcon.merge => Icons.merge,
      TurnIcon.ramp => Icons.ramp_right,
      TurnIcon.exit => Icons.exit_to_app,
      TurnIcon.ferry => Icons.directions_boat,
      TurnIcon.via => Icons.flag_outlined,
      TurnIcon.arrive => Icons.flag,
      TurnIcon.offroad => Icons.terrain,
    };

/// "Head north for 0.4 mi, up 120 ft" (or "Follow the trail north for ..."): an off-road leg in words.
String offroadHint(ProgressManeuver m, Fmt fmt) {
  final dir = cardinalWord(m.cardinal);
  final climb = (m.elevGainM ?? 0) >= 10 ? ', up ${fmt.height(m.elevGainM!)}' : ((m.elevLossM ?? 0) >= 10 ? ', down ${fmt.height(m.elevLossM!)}' : '');
  if (m.kind == 'offroad_follow') return 'Follow ${m.followName ?? 'the trail'} $dir for ${fmt.distance(m.lengthM)}$climb'.replaceAll('  ', ' ');
  return 'Head $dir for ${fmt.distance(m.lengthM)}$climb'.replaceAll('  ', ' ');
}

/// The strip at the top while guiding: the next turn and how far, then the one after. On an off-road leg it is the bearing to
/// the next point, how far, and the climb.
class GuidanceBanner extends StatelessWidget {
  const GuidanceBanner({super.key, required this.nav, required this.fmt, this.showThen = true});

  final NavState nav;
  final Fmt fmt;

  /// The small "Then ..." line under the turn. The drive screen turns it off: the turn after is the first row of its list.
  final bool showThen;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = nav.progress;
    Widget body;
    List<Lane> lanes = const [];
    if (nav.arrived) {
      body = _row(context, icon: Icons.flag, big: 'You have arrived', small: nav.route?.destinationName ?? '');
    } else if (nav.rerouting) {
      body = _row(context, icon: Icons.alt_route, big: 'Rerouting', small: 'Working out a new way from here');
    } else if (p == null) {
      body = _row(context, icon: Icons.navigation, big: 'Getting your position', small: 'Guidance starts with the first GPS fix');
    } else if (p.leg != null && !((p.next?.isArrival ?? false) && p.next!.distanceM < 30)) {
      body = _offroad(context, p);
    } else {
      final next = p.next;
      if (next == null) {
        body = _row(context, icon: Icons.flag, big: 'Arriving', small: nav.route?.destinationName ?? '');
      } else {
        final icon = turnIconFor(next.type, offroad: next.isOffroad);
        // The lanes show once the turn is as close as the first voice prompt (800 m by car), read from the engine for the way of travel.
        lanes = lanesToShow(next, nav.farStageM);
        body = _row(
          context,
          icon: iconForTurn(icon),
          big: fmt.distance(next.distanceM),
          small: next.isOffroad ? offroadHint(next, fmt) : next.instruction,
          then: !showThen || p.then == null || p.then!.isArrival && next.isArrival ? null : 'Then ${_thenText(p.then!)}',
        );
      }
    }
    return Container(
      key: const ValueKey('guidance-banner'),
      decoration: BoxDecoration(
        color: k.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      // Compact, so more of the map shows: how far and the turn on one line. The type stays large enough to read from the
      // dashboard and grows with the phone's text size. Solid surface and text colours, so it holds its contrast in sunlight.
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: lanes.isEmpty ? body : Column(mainAxisSize: MainAxisSize.min, children: [body, const SizedBox(height: 6), LaneStrip(lanes: lanes)]),
    );
  }

  String _thenText(ProgressManeuver m) {
    if (m.isOffroad) return offroadHint(m, fmt).toLowerCase();
    var t = m.instruction.trim();
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
  }

  Widget _row(BuildContext context, {required IconData icon, required String big, required String small, String? then}) {
    final k = context.t;
    return _layout(
      context,
      icon: Icon(icon, size: 26, color: k.accent),
      tint: k.accent,
      big: big,
      small: small,
      then: then,
    );
  }

  /// The icon, then "0.4 mi · Turn left onto Road 1" on one line (on two only when the street's name is long), then the small
  /// "Then ..." line.
  Widget _layout(BuildContext context, {required Widget icon, required Color tint, required String big, required String small, String? then, Key? key}) {
    final k = context.t;
    final text = small.endsWith('.') ? small.substring(0, small.length - 1) : small;
    return Row(
      key: key,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: tint.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
          child: icon,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: big, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  if (text.isNotEmpty) TextSpan(text: ' · $text', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400)),
                ]),
                key: const ValueKey('banner-distance'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(height: 1.15, color: k.text),
              ),
              if (then != null && then.isNotEmpty)
                Text(then, key: const ValueKey('banner-then'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.2, color: k.secondary)),
            ],
          ),
        ),
      ],
    );
  }

  /// Off-road: an arrow that points at the next point, how far, the compass word, and the climb.
  Widget _offroad(BuildContext context, MapProgress p) {
    final k = context.t;
    final leg = p.leg!;
    final heading = nav.lastFix?.heading;
    // Relative to the way the phone is moving when that is known, else to north.
    final angle = (leg.bearingDeg - (heading ?? 0)) * math.pi / 180;
    final climb = leg.climbM != null && leg.climbM! >= 5
        ? 'Climb ${fmt.height(leg.climbM!)}'
        : (leg.descentM != null && leg.descentM! >= 5 ? 'Descent ${fmt.height(leg.descentM!)}' : null);
    final info = <String>[
      ?climb,
      if (leg.gradeClass != null && leg.gradeClass != 'flat') leg.gradeClass!.replaceAll('_', ' '),
    ];
    return _layout(
      context,
      key: const ValueKey('banner-offroad'),
      icon: Transform.rotate(angle: angle, child: Icon(Icons.navigation, size: 26, color: k.warning)),
      tint: k.warning,
      big: fmt.distance(leg.distanceM),
      small: 'Head ${leg.cardinal} · ${leg.bearingDeg}°',
      then: info.isEmpty ? null : info.join(' · '),
    );
  }
}

/// The strip at the bottom while guiding: arrival time, time and distance left, the voice switch, and End.
class GuidanceBar extends StatelessWidget {
  const GuidanceBar({super.key, required this.nav, required this.fmt, this.bare = false});

  final NavState nav;
  final Fmt fmt;

  /// Inside the guidance card (GuidanceDock in elevation_dock.dart), which draws the card: no background of its own and no top
  /// padding (the elevation handle is above it).
  final bool bare;

  /// Under this width (the card's own, in points: a 360-point phone's card is 336) the bar is drawn in its narrow form: see [_bar].
  static const double narrowBelow = 360;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => _bar(context, narrow: box.maxWidth < narrowBelow));

  Widget _bar(BuildContext context, {required bool narrow}) {
    final k = context.t;
    final p = nav.progress;
    final r = nav.route;
    final eta = p?.eta;
    final remainingM = p?.remainingM ?? r?.distanceM ?? 0;
    final remainingS = p?.remainingS ?? r?.durationS ?? 0;
    Widget column(String big, String small, {Key? key, double bigSize = 20, double smallSize = 13}) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(big, key: key, style: TextStyle(fontSize: bigSize, fontWeight: FontWeight.w700, color: k.text)),
            Text(small, style: TextStyle(fontSize: smallSize, color: k.secondary)),
          ],
        );
    Widget stat(String big, String small, {Key? key}) => Expanded(child: FittedBox(fit: BoxFit.scaleDown, child: column(big, small, key: key)));
    // Narrow (a 320 or 360 point phone): three equal cells left each long value only a sliver, and each was shrunk to fill its own
    // cell, so the three ran together ("7:02 PM23 min17 mi"). Here the three sit in one run with a fixed gap between them, shrunk
    // together by one scale, so the gaps stay; the voice switch and End take less room.
    Widget narrowStats() => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  column(eta == null ? '--' : clockTime(eta), 'arrive', key: const ValueKey('bar-eta'), bigSize: 18, smallSize: 12),
                  const SizedBox(width: 14),
                  column(fmt.duration(remainingS), 'left', key: const ValueKey('bar-time'), bigSize: 18, smallSize: 12),
                  const SizedBox(width: 14),
                  column(fmt.distance(remainingM), 'to go', key: const ValueKey('bar-distance'), bigSize: 18, smallSize: 12),
                ],
              ),
            ),
          ),
        );
    return Container(
      key: const ValueKey('guidance-bar'),
      decoration: bare ? null : mapPanel(context, radius: 20, alpha: 0.98),
      // The screen's bottom inset (the home indicator) is kept below the card by the Maps screen, not inside it as an empty strip.
      // Inside the guidance card the elevation handle is above, so no top padding.
      padding: EdgeInsets.fromLTRB(8, bare ? 0 : 4, 8, 4),
      child: nav.arrived
            ? Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(child: Text('You have arrived', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text))),
                  FilledButton(key: const ValueKey('guidance-done'), onPressed: nav.finish, child: const Text('Done')),
                ],
              )
            : Row(
                children: [
                  IconButton(
                    key: const ValueKey('guidance-voice'),
                    tooltip: nav.voiceOn ? 'Turn the voice off' : 'Turn the voice on',
                    icon: Icon(nav.voiceOn ? Icons.volume_up : Icons.volume_off, color: nav.voiceOn ? k.accent : k.secondary, size: narrow ? 24 : 28),
                    padding: narrow ? EdgeInsets.zero : null,
                    constraints: narrow ? const BoxConstraints(minWidth: 36, minHeight: 48) : null,
                    onPressed: nav.toggleVoice,
                  ),
                  if (narrow)
                    narrowStats()
                  else
                    Expanded(
                      child: Row(
                        children: [
                          stat(eta == null ? '--' : clockTime(eta), 'arrive', key: const ValueKey('bar-eta')),
                          stat(fmt.duration(remainingS), 'left', key: const ValueKey('bar-time')),
                          stat(fmt.distance(remainingM), 'to go', key: const ValueKey('bar-distance')),
                        ],
                      ),
                    ),
                  FilledButton(
                    key: const ValueKey('guidance-end'),
                    style: FilledButton.styleFrom(backgroundColor: k.emergency, foregroundColor: k.background, minimumSize: Size(narrow ? 56 : 72, 52), padding: narrow ? const EdgeInsets.symmetric(horizontal: 12) : null),
                    onPressed: nav.end,
                    child: const Text('End'),
                  ),
                ],
              ),
    );
  }
}

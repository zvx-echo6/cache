import 'dart:math' as math;

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../maps/ui/map_widgets.dart';
import '../../theme.dart';
import '../guidance.dart';
import '../nav_state.dart';
import '../units.dart';

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

/// The strip at the top while guiding: the next turn and how far, then the one after. On an off-road leg it is the bearing to
/// the next point, how far, and the climb.
class GuidanceBanner extends StatelessWidget {
  const GuidanceBanner({super.key, required this.nav, required this.fmt});

  final NavState nav;
  final Fmt fmt;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = nav.progress;
    Widget body;
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
        body = _row(
          context,
          icon: iconForTurn(icon),
          big: fmt.distance(next.distanceM),
          small: next.isOffroad ? _offroadHint(next) : next.instruction,
          then: p.then == null || p.then!.isArrival && next.isArrival ? null : 'Then ${_thenText(p.then!)}',
        );
      }
    }
    return Container(
      key: const ValueKey('guidance-banner'),
      decoration: BoxDecoration(
        color: k.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: body,
    );
  }

  String _thenText(ProgressManeuver m) {
    if (m.isOffroad) return _offroadHint(m).toLowerCase();
    var t = m.instruction.trim();
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    return t.isEmpty ? t : t[0].toLowerCase() + t.substring(1);
  }

  String _offroadHint(ProgressManeuver m) {
    final dir = cardinalWord(m.cardinal);
    final climb = (m.elevGainM ?? 0) >= 10 ? ', up ${fmt.height(m.elevGainM!)}' : ((m.elevLossM ?? 0) >= 10 ? ', down ${fmt.height(m.elevLossM!)}' : '');
    if (m.kind == 'offroad_follow') return 'Follow ${m.followName ?? 'the trail'} $dir for ${fmt.distance(m.lengthM)}$climb'.replaceAll('  ', ' ');
    return 'Head $dir for ${fmt.distance(m.lengthM)}$climb'.replaceAll('  ', ' ');
  }

  Widget _row(BuildContext context, {required IconData icon, required String big, required String small, String? then}) {
    final k = context.t;
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: k.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, size: 36, color: k.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(big, key: const ValueKey('banner-distance'), style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.1, color: k.text)),
              if (small.isNotEmpty) Text(small, key: const ValueKey('banner-instruction'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, height: 1.2, color: k.text)),
              if (then != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(then, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: k.secondary))),
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
    return Row(
      key: const ValueKey('banner-offroad'),
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: k.warning.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(14)),
          child: Transform.rotate(angle: angle, child: Icon(Icons.navigation, size: 36, color: k.warning)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmt.distance(leg.distanceM), key: const ValueKey('banner-distance'), style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.1, color: k.text)),
              Text('Head ${leg.cardinal} · ${leg.bearingDeg}°', key: const ValueKey('banner-instruction'), style: TextStyle(fontSize: 18, color: k.text)),
              if (info.isNotEmpty) Text(info.join(' · '), style: TextStyle(fontSize: 15, color: k.secondary)),
            ],
          ),
        ),
      ],
    );
  }
}

/// The strip at the bottom while guiding: arrival time, time and distance left, the voice switch, and End.
class GuidanceBar extends StatelessWidget {
  const GuidanceBar({super.key, required this.nav, required this.fmt});

  final NavState nav;
  final Fmt fmt;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = nav.progress;
    final r = nav.route;
    final eta = p?.eta;
    final remainingM = p?.remainingM ?? r?.distanceM ?? 0;
    final remainingS = p?.remainingS ?? r?.durationS ?? 0;
    Widget stat(String big, String small, {Key? key}) => Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(big, key: key, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: k.text)),
                Text(small, style: TextStyle(fontSize: 13, color: k.secondary)),
              ],
            ),
          ),
        );
    return Container(
      key: const ValueKey('guidance-bar'),
      decoration: mapPanel(context, radius: 20, alpha: 0.98),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: SafeArea(
        top: false,
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
                    icon: Icon(nav.voiceOn ? Icons.volume_up : Icons.volume_off, color: nav.voiceOn ? k.accent : k.secondary, size: 28),
                    onPressed: nav.toggleVoice,
                  ),
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
                    style: FilledButton.styleFrom(backgroundColor: k.emergency, foregroundColor: k.background, minimumSize: const Size(72, 52)),
                    onPressed: nav.end,
                    child: const Text('End'),
                  ),
                ],
              ),
      ),
    );
  }
}

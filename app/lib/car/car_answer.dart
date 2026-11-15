import '../nav/nav_state.dart';
import '../nav/units.dart';
import 'car_trip.dart';

/// What the phone says when the assistant asks about the trip (Android Auto's `geo.action:?act=eta` and the like): navigation
/// information only, from the trip the phone already has, in the units and clock the phone shows.
const String kNoRouteAnswer = 'No route is running.';

/// The words for [kind]: `eta`, `distance`, `turn` or `destination` (the car side maps the assistant's codes onto these; any other
/// kind, such as the overview asked for with no route, gets the no-route answer). With no guidance running, always
/// [kNoRouteAnswer].
String carAnswer(NavState nav, String? kind, {DateTime Function()? now}) {
  final p = nav.progress;
  if (!nav.guiding || p == null) return kNoRouteAnswer;
  final fmt = nav.fmt;
  String distance() => '${_capital(fmt.spoken(p.remainingM))} to go.';
  switch (kind) {
    case 'eta':
      final at = shownArrival(p.eta, p.remainingS, leftS: nav.leftS) ?? (now ?? DateTime.now)().add(Duration(seconds: shownSeconds(nav.leftS ?? p.remainingS)));
      return 'Arriving at ${clockTime(at)}.';
    case 'distance':
      return distance();
    case 'turn':
      final next = p.next;
      if (next == null) return distance();
      var step = (carStep(next, fmt)['cue'] as String).trim();
      if (step.endsWith('.')) step = step.substring(0, step.length - 1);
      return 'Next: $step in ${fmt.spoken(next.distanceM)}.';
    case 'destination':
      final named = nav.route?.destinationName ?? '';
      final name = named.isNotEmpty ? named : (nav.selected?.name ?? '');
      return 'Going to ${name.isEmpty ? 'your destination' : name}.';
  }
  return kNoRouteAnswer;
}

String _capital(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

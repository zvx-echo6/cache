import 'package:cache_search/cache_search.dart';

import '../nav/guidance.dart';
import '../nav/nav_state.dart';
import '../nav/units.dart';
import '../nav/elevation/elevation_profile.dart';
import '../theme.dart';
import 'car_overlay.dart';

/// What the car screen shows, made from the phone's own guidance state ([NavState]). Android Auto draws it with its own
/// templates (app/android/.../car), so the car never works anything out for itself: the route, the maneuver, the distances and
/// the voice prompts all come from the one guidance the phone runs.
///
/// Plain values only (the platform channel's standard codec): numbers in meters and seconds, the turn as a [TurnIcon] name, and
/// the units the phone's region uses, so the car shows the same miles or kilometers as the phone.
///
/// [elevation] is the current route's profile (null: none yet), [theme] the phone's chosen theme, and [overlay] the two switches
/// of the climb card and the route mini map (see car_overlay.dart): the car paints those from the `climb`, `overview` and
/// `palette` blocks while guiding.
Map<String, dynamic> carTrip(NavState nav, {GeoPoint? position, double? heading, ElevationProfile? elevation, CacheThemeId theme = CacheThemeId.dark, Map<String, bool>? overlay}) {
  final p = nav.progress;
  final r = nav.route;
  final dest = nav.selected;
  return {
    'phase': nav.phase.name,
    'available': nav.available,
    'units': nav.fmt.units.name,
    'routing': nav.routing,
    'error': nav.phase == NavPhase.previewing ? carRouteError(nav) : null,
    'destination': dest == null
        ? null
        : {'name': r?.destinationName.isNotEmpty == true ? r!.destinationName : dest.name, 'address': dest.address, 'lat': dest.lat, 'lon': dest.lon},
    'routes': [
      for (final (i, x) in nav.routes.indexed)
        {'index': i, 'distanceM': x.distanceM, 'durationS': x.durationS, 'via': routeVia(x)},
    ],
    // The stops still ahead, in order (Add stop): the car names them on its route screen and in its route overview, each with
    // the number the turn card says for it when it is reached.
    'stops': [
      for (final (n, s) in nav.numberedStopsAhead) {'number': n, 'name': s.name, 'address': s.address},
    ],
    'routeIndex': nav.routeIndex,
    'routeId': r?.routeId,
    'voiceOn': nav.voiceOn,
    'arrived': nav.arrived,
    'rerouting': nav.rerouting,
    if (position != null) 'position': {'lat': position.lat, 'lon': position.lon, 'heading': ?heading},
    if (nav.guiding && p != null && !nav.rerouting) ...{
      'step': p.next == null ? null : carStep(p.next!, nav.fmt),
      'then': p.then == null || (p.then!.isArrival && (p.next?.isArrival ?? false)) ? null : carStep(p.then!, nav.fmt),
      'currentRoad': p.current.streetNames.isEmpty ? null : p.current.streetNames.first,
      'remainingM': p.remainingM,
      'remainingS': p.remainingS,
      'etaMs': p.eta?.millisecondsSinceEpoch,
      'overlay': overlay ?? carOverlaySwitches(),
      'palette': carOverlayPalette(theme),
      if (r != null) ...{
        // Never on arrival: there is no climb ahead of a vehicle that is there.
        'climb': ?(nav.arrived ? null : carClimb(elevation, distanceAlongM: p.distanceAlongM, routeM: r.distanceM)),
        'overview': ?carOverview(r, distanceAlongM: p.distanceAlongM, profile: elevation, destination: dest == null ? null : GeoPoint(dest.lat, dest.lon)),
      },
    },
  };
}

/// One maneuver for the car: the turn picture (the same choice the phone's banner makes), the words, the road and how far.
Map<String, dynamic> carStep(ProgressManeuver m, Fmt fmt) {
  final turn = turnIconFor(m.type, offroad: m.isOffroad);
  return {
    'turn': turn.name,
    'type': m.type,
    'cue': m.isOffroad ? _offroadCue(m, fmt) : m.instruction,
    'road': m.isOffroad || m.streetNames.isEmpty ? null : m.streetNames.first,
    'distanceM': m.distanceM,
  };
}

String _offroadCue(ProgressManeuver m, Fmt fmt) {
  final way = cardinalWord(m.cardinal);
  if (m.kind == 'offroad_follow') {
    final what = m.followName ?? (m.trailKind == 'road' ? 'the road' : m.trailKind == 'track' ? 'the track' : 'the trail');
    return 'Follow $what${way.isEmpty ? '' : ' $way'} for ${fmt.distance(m.lengthM)}';
  }
  return 'Head${way.isEmpty ? ' on' : ' $way'} for ${fmt.distance(m.lengthM)}';
}

/// "Via US-30" from the route's main road, or null.
String? routeVia(MapRoute r) {
  final roads = r.raw['major_roads'];
  if (roads is List && roads.isNotEmpty && roads.first is Map) {
    final name = (roads.first as Map)['name'];
    if (name is String && name.trim().isNotEmpty) return 'Via ${name.trim()}';
  }
  return null;
}

/// Why there are no directions, in words for the car screen. Nothing on the car screen asks the driver to use the phone: a missing
/// position reads as waiting for it.
String? carRouteError(NavState nav) {
  final e = nav.routeError;
  if (e == null) return null;
  if (nav.here == null && nav.fromPlace == null) return 'Waiting for your position';
  return e;
}

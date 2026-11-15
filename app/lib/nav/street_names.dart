/// How a road is called, the one rule for the phone's banner, the turn list, the drive screen, the voice, CarPlay and Android
/// Auto (the car gets the words the phone sends).
///
/// On screen: the road's name first, with its route number after it in brackets when it has both
/// ("Lakeside Boulevard (US 99 Bus)", the first number only, so the banner stays short); a road with only numbers keeps all of
/// them as Valhalla joins them ("SH 98/SH 99"), on screen and spoken, so none is lost. Spoken: the name alone, or the numbers
/// when it has only numbers. A road with more than one name keeps its first, as the map orders them. Which is a name and which a
/// number is the map's own word ([StreetName.isRouteNumber], from Valhalla); nothing here reads the text to decide.
library;

import 'package:cache_search/cache_search.dart';

StreetName? _first(List<StreetName> s, {required bool routeNumber}) {
  for (final n in s) {
    if (n.isRouteNumber == routeNumber) return n;
  }
  return null;
}

/// A road with no name: all its numbers, joined as Valhalla joins them; null when it has none either.
String? _numbers(List<StreetName> s) {
  final n = [for (final x in s) if (x.isRouteNumber) x.text];
  return n.isEmpty ? null : n.join('/');
}

/// The road as the screens show it, or null when it has no name or number.
String? shownRoad(List<StreetName> s) {
  final name = _first(s, routeNumber: false), number = _first(s, routeNumber: true);
  if (name == null) return _numbers(s);
  return number == null ? name.text : '${name.text} (${number.text})';
}

/// The road as the voice says it, or null when it has no name or number.
String? spokenRoad(List<StreetName> s) => _first(s, routeNumber: false)?.text ?? _numbers(s);

/// Valhalla's [instruction] with the road worded by [word] ([shownRoad] or [spokenRoad]); the rest stays as Valhalla wrote it.
///
/// Valhalla writes a maneuver's names into its instruction joined by "/" in the map's order ("Turn right onto US 99 Bus/Lakeside
/// Boulevard."): that stretch, found as those exact names, is what is replaced. The names where the maneuver starts
/// ([beginStreets], "Turn right onto A. Continue on B.") come first in Valhalla's text, so they are replaced first and the
/// maneuver's own names after them. Names the text does not hold leave it as it is.
String instructionWith(String instruction, List<StreetName> streets, List<StreetName> beginStreets, String? Function(List<StreetName>) word) {
  final (afterBegin, from) = _replaceNames(instruction, 0, beginStreets, word);
  return _replaceNames(afterBegin, from, streets, word).$1;
}

/// [text] with the first stretch at or after [from] that is [names] as Valhalla joins them (all of them, else the longest
/// leading run of them) replaced by [word]'s choice; and where the replacement ends (or [from] when nothing was replaced).
(String, int) _replaceNames(String text, int from, List<StreetName> names, String? Function(List<StreetName>) word) {
  if (names.isEmpty) return (text, from);
  final chosen = word(names);
  if (chosen == null) return (text, from);
  for (var k = names.length; k >= 1; k--) {
    final joined = names.take(k).map((n) => n.text).join('/');
    final at = text.indexOf(joined, from);
    if (at >= 0) return (text.replaceRange(at, at + joined.length, chosen), at + chosen.length);
  }
  return (text, from);
}

/// A route's main road as the screens show it: a `major_roads` entry (`name`, and `streets` from the core), or null.
String? majorRoadShown(Object? road) {
  if (road is! Map) return null;
  final name = road['name'];
  final shown = shownRoad(StreetName.listFrom(road['streets'], fallback: [if (name is String) name.trim()]));
  return shown == null || shown.trim().isEmpty ? null : shown.trim();
}

extension ProgressManeuverWords on ProgressManeuver {
  /// The instruction as the banner, the "Then" line and the car show it.
  String get shownInstruction => instructionWith(instruction, streets, beginStreets, shownRoad);

  /// The instruction as the voice says it.
  String get spokenInstruction => instructionWith(instruction, streets, beginStreets, spokenRoad);

  /// The road the maneuver goes onto (or the one being driven, for `current`), as the screens show it.
  String? get shownRoadName => shownRoad(streets);
}

extension ManeuverWords on Maneuver {
  /// The instruction as the turn list shows it.
  String get shownInstruction => instructionWith(instruction, streets, beginStreets, shownRoad);

  /// The road, as the screens show it.
  String? get shownRoadName => shownRoad(streets);
}

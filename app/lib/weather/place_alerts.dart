import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../files.dart';

/// The file in the app's support folder that holds the places' alert rules.
const String kPlaceAlertsFile = 'place_alerts.json';

/// How a place's alerts pop up: as the alert setting says (the default), a rule of its own, or not at all. The place's alerts
/// are listed in Weather either way.
enum PlaceAlertMode { same, custom, off }

/// The kinds of alerts a custom rule can pop up for: the catalogue categories of the sources that give something happening.
/// Labels say what the source gives.
const Map<String, String> kAlertKinds = {
  'alerts': 'Weather alerts',
  'fire': 'Fires',
  'earthquakes': 'Earthquakes',
  'hydrology': 'River levels',
  'avalanche': 'Avalanche danger',
  'roads': 'Road events',
  'traffic': 'Traffic',
};

/// "How far out" choices of a custom rule, in miles.
const List<int> kAlertMiles = [5, 10, 25, 50, 100];

/// One place's rule.
@immutable
class PlaceAlertRule {
  const PlaceAlertRule({this.mode = PlaceAlertMode.same, this.miles = 25, this.kinds = const {'alerts', 'fire'}});

  final PlaceAlertMode mode;

  /// Custom only: alerts further away than this do not pop up (an alert without a distance always does).
  final int miles;

  /// Custom only: the kinds that pop up.
  final Set<String> kinds;

  static const PlaceAlertRule same = PlaceAlertRule();

  PlaceAlertRule copyWith({PlaceAlertMode? mode, int? miles, Set<String>? kinds}) =>
      PlaceAlertRule(mode: mode ?? this.mode, miles: miles ?? this.miles, kinds: kinds ?? this.kinds);

  Map<String, dynamic> toJson() => {'mode': mode.name, 'miles': miles, 'kinds': [...kinds]..sort()};

  static PlaceAlertRule fromJson(Object? j) {
    if (j is! Map) return same;
    final mode = PlaceAlertMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => PlaceAlertMode.same);
    final miles = j['miles'] is num ? (j['miles'] as num).toInt() : 25;
    final kinds = j['kinds'] is List ? {for (final k in j['kinds'] as List) if (kAlertKinds.containsKey(k)) '$k'} : const {'alerts', 'fire'};
    return PlaceAlertRule(mode: mode, miles: miles, kinds: kinds);
  }

  @override
  bool operator ==(Object other) =>
      other is PlaceAlertRule && other.mode == mode && other.miles == miles && setEquals(other.kinds, kinds);

  @override
  int get hashCode => Object.hash(mode, miles, Object.hashAllUnordered(kinds));
}

/// The places' alert rules, by watched-place id (`here`, `place:<key>`), kept in a small file. A place without one follows the
/// alert setting.
class PlaceAlerts extends ChangeNotifier {
  PlaceAlerts(Future<File> Function() file) : _file = file;

  /// Rules kept in memory only (tests).
  PlaceAlerts.memory() : _file = null;

  final Future<File> Function()? _file;
  Map<String, PlaceAlertRule> _rules = {};
  bool _read = false;

  PlaceAlertRule ruleFor(String placeId) => _rules[placeId] ?? PlaceAlertRule.same;

  Future<void> load() async {
    if (_read) return;
    _read = true;
    final file = _file;
    if (file == null) return;
    try {
      final f = await file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map) _rules = {for (final e in j.entries) '${e.key}': PlaceAlertRule.fromJson(e.value)};
      notifyListeners();
    } catch (e) {
      debugPrint('cache place alerts: could not read ($e)');
    }
  }

  Future<void> set(String placeId, PlaceAlertRule rule) async {
    await load();
    if (rule == PlaceAlertRule.same) {
      _rules.remove(placeId);
    } else {
      _rules[placeId] = rule;
    }
    notifyListeners();
    final file = _file;
    if (file == null) return;
    final f = await file();
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode({for (final e in _rules.entries) e.key: e.value.toJson()}));
  }

  /// A place that is gone takes its rule along.
  Future<void> forget(String placeId) async {
    await load();
    if (!_rules.containsKey(placeId)) return;
    await set(placeId, PlaceAlertRule.same);
  }
}

/// Miles in a distance the sources write ("12 mi", "3.4 km", "800 m", "12 mi NE"); null when there is no number.
double? milesIn(String? text) {
  if (text == null) return null;
  final m = RegExp(r'(\d+(?:\.\d+)?)\s*(mi|km|m|ft)\b').firstMatch(text.toLowerCase());
  if (m == null) return null;
  final v = double.parse(m.group(1)!);
  return switch (m.group(2)) {
    'mi' => v,
    'km' => v / 1.609344,
    'm' => v / 1609.344,
    _ => v / 5280,
  };
}

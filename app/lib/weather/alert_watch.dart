import 'dart:convert';
import 'dart:io';

import 'live_view.dart';
import 'place_alerts.dart';
import 'places.dart';

/// Something happening near a watched place that the person has not been told about yet.
class NewAlert {
  const NewAlert({required this.item, required this.source, required this.place, required this.extreme, bool? serious, this.custom = false})
      : serious = serious ?? extreme;

  final LiveItem item;
  final String source;
  final WatchPlace place;

  /// The source marks it extreme (NWS "Severity: extreme": evacuation orders, tornado and flash flood warnings and the like).
  final bool extreme;

  /// Serious ([isSerious]): what "Serious only" pops up, and what still rings in quiet hours.
  final bool serious;

  /// Picked by the place's own Custom rule: it pops up whatever "Pop up for" says (the place's rule overrides it).
  final bool custom;

  /// What the notification carries back to the app when tapped.
  String get payload => jsonEncode({'place': place.id, 'address': item.address});

  /// "Red Flag Warning near Cabin".
  String get title => '${item.label} near ${place.name}';

  /// The item's distance and first details, for the notification body.
  String get body => [if (item.distance != null) item.distance!, if (item.summary.isNotEmpty) item.summary].join(' · ');
}

/// What a tapped notification points at.
class AlertFocus {
  const AlertFocus({required this.placeId, required this.address});

  final String placeId;
  final String address;

  static AlertFocus? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final j = jsonDecode(payload);
      if (j is Map && j['place'] is String && j['address'] is String) {
        return AlertFocus(placeId: j['place'] as String, address: j['address'] as String);
      }
    } catch (_) {}
    return null;
  }
}

/// The sources whose items raise a pop-up: warnings and fires (the same ones the Home Alerts card counts). Earthquakes, rivers and
/// the rest stay on the Weather screen.
bool raisesAlerts(SourceView v) => v.source.category == 'alerts' || v.source.category == 'fire' || v.source.id == 'alerts';

/// How far out a fire near a place counts as serious, in miles, when nothing else is set for the place.
const double kFireReachMiles = 10;

/// An item's distance in miles from its distance field ("12 mi SE", "8.5 km N"), or null when it gives none.
double? distanceMiles(LiveItem i) {
  final m = RegExp(r'^\s*([0-9]+(?:\.[0-9]+)?)\s*(mi|km|m)\b', caseSensitive: false).firstMatch(i.distance ?? '');
  if (m == null) return null;
  final v = double.parse(m.group(1)!);
  return switch (m.group(2)!.toLowerCase()) {
    'km' => v / 1.609344,
    'm' => v / 1609.344,
    _ => v,
  };
}

/// Whether an item is serious: an extreme or severe warning, an evacuation order (always), or a fire within [fireReachMiles] of the
/// place. Serious items pop up under "Serious only" and ring in quiet hours.
bool isSerious(LiveItem i, {required bool fire, String? severity, double fireReachMiles = kFireReachMiles}) {
  if (severity == 'extreme' || severity == 'severe') return true;
  final words = '${i.label} ${i.fields['Event'] ?? ''}'.toLowerCase();
  if (words.contains('evacuat')) return true;
  if (fire) {
    final d = distanceMiles(i);
    return d != null && d <= fireReachMiles;
  }
  return false;
}

/// The items in [views] (grouped by place) that have not been told about before ([told] holds their addresses), at most one fire
/// source per place (incidents and perimeters describe the same fires: the source with the most items speaks for them).
/// [rules] gives a place's own alert rule (Places notebook, the place's gear): off pops up nothing for it, custom pops up the
/// chosen kinds within its distance; the default follows [raisesAlerts]. [fireReach] is how far out fires count as serious for a
/// place (else a custom rule's distance, else [kFireReachMiles]).
List<NewAlert> pickNewAlerts(Map<WatchPlace, List<SourceView>> views, Set<String> told,
    {PlaceAlertRule Function(String placeId)? rules, double Function(WatchPlace place)? fireReach}) {
  final out = <NewAlert>[];
  for (final e in views.entries) {
    final place = e.key;
    final rule = rules?.call(place.id) ?? PlaceAlertRule.same;
    if (rule.mode == PlaceAlertMode.off) continue;
    final custom = rule.mode == PlaceAlertMode.custom;
    bool counts(SourceView v) => custom ? rule.kinds.contains(v.source.category == 'other' && v.source.id == 'alerts' ? 'alerts' : v.source.category) : raisesAlerts(v);
    final counted = [for (final v in e.value) if (counts(v) && !v.missing && !v.expired) v];
    final fires = [for (final v in counted) if (v.source.category == 'fire') v]..sort((a, b) => b.active.length.compareTo(a.active.length));
    final speaking = [for (final v in counted) if (v.source.category != 'fire') v, if (fires.isNotEmpty) fires.first];
    for (final v in speaking) {
      for (final i in v.active) {
        if (told.contains(i.address)) continue;
        if (custom) {
          final mi = milesIn(i.distance);
          if (mi != null && mi > rule.miles) continue;
        }
        final severity = i.fields.entries.where((f) => f.key.toLowerCase() == 'severity').map((f) => f.value.toLowerCase()).firstOrNull;
        out.add(NewAlert(
          item: i,
          source: v.source.id,
          place: place,
          extreme: severity == 'extreme',
          serious: isSerious(i, fire: v.source.category == 'fire', severity: severity, fireReachMiles: fireReach?.call(place) ?? (custom ? rule.miles.toDouble() : kFireReachMiles)),
          custom: custom,
        ));
      }
    }
  }
  return out;
}

/// The addresses already told about, kept in a small file so restarts and background runs never repeat a pop-up.
class ToldStore {
  ToldStore(File file) : _where = (() async => file);

  /// For when the folder is only known later (the app reads its support folder at start).
  ToldStore.lazy(this._where);

  final Future<File> Function() _where;

  /// The most kept; older ones drop off (an alert that old has long ended).
  static const int keep = 500;

  Future<Set<String>> read() async {
    try {
      final file = await _where();
      if (!await file.exists()) return {};
      final j = jsonDecode(await file.readAsString());
      return {if (j is List) for (final a in j) '$a'};
    } catch (_) {
      return {};
    }
  }

  Future<void> add(Iterable<String> addresses) async {
    final list = [...(await read()), ...addresses];
    final kept = list.length > keep ? list.sublist(list.length - keep) : list;
    final file = await _where();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(kept), flush: true);
    await tmp.rename(file.path);
  }
}

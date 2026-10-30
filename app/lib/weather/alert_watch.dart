import 'dart:convert';
import 'dart:io';

import 'alert_area.dart';
import 'live_view.dart';
import 'place_alerts.dart';
import 'places.dart';

/// Something happening near a watched place that the person has not been told about yet.
class NewAlert {
  const NewAlert({
    required this.item,
    required this.source,
    required this.place,
    required this.extreme,
    bool? serious,
    this.custom = false,
    List<WatchPlace>? places,
    List<String>? addresses,
    this.told = const [],
  }) : serious = serious ?? extreme,
       places = places ?? const [],
       addresses = addresses ?? const [];

  /// The copy the pop-up shows (the first source that has it).
  final LiveItem item;
  final String source;

  /// The first watched place it is near.
  final WatchPlace place;

  /// Every watched place it is near, [place] first (one pop-up for the same alert at Home and at Cabin). Empty means [place] only.
  final List<WatchPlace> places;

  /// The addresses of every copy (NWS and IPAWS, each place), all remembered as told. Empty means [item]'s only.
  final List<String> addresses;

  /// What is remembered of it so a copy that comes later (an update, another source) does not pop up again.
  final List<ToldAlert> told;

  /// The source marks it extreme (NWS "Severity: extreme": evacuation orders, tornado and flash flood warnings and the like).
  final bool extreme;

  /// Serious ([isSerious]): what "Serious only" pops up, and what still rings in quiet hours.
  final bool serious;

  /// Picked by the place's own Custom rule: it pops up whatever "Pop up for" says (the place's rule overrides it).
  final bool custom;

  /// What the notification carries back to the app when tapped.
  String get payload => jsonEncode({'place': place.id, 'address': item.address});

  /// "Red Flag Warning near Cabin", "Red Flag Warning near Home and Cabin".
  String get title => '${item.label} near ${placeWords([for (final p in (places.isEmpty ? [place] : places)) p.name])}';

  /// Every address to remember as told.
  List<String> get allAddresses => addresses.isEmpty ? [item.address] : addresses;

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

/// "Home", "Home and Cabin", "Home, Cabin and Shop".
String placeWords(List<String> names) {
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// An alert's CAP identifier: the item's key, without the ".IPAWS" IPAWS adds to the identifiers of the NWS messages it relays
/// (NWS gives `urn:oid:2.49.0.1.840.0.<id>.001.1`, IPAWS `urn:oid:2.49.0.1.840.0.<id>.001.1.IPAWS`: one message).
String capId(LiveItem i) {
  final k = i.key.trim();
  return k.endsWith('.IPAWS') ? k.substring(0, k.length - '.IPAWS'.length) : k;
}

/// What kind of alert it is: its "Event" field when the source gives one (IPAWS: the label is the headline), else its label
/// (NWS: the label is the event). Compared as written, ignoring case.
String alertEvent(LiveItem i) => (i.fields['Event'] ?? i.label).trim().toLowerCase();

/// When an alert is in force: from its time to its "Expires" field (written in the place's local time, which the time's offset
/// gives), else six hours after it starts. Null when it has no time.
({DateTime from, DateTime to})? alertSpan(LiveItem i) {
  final t = i.time == null ? null : DateTime.tryParse(i.time!);
  if (t == null) return null;
  DateTime? to;
  final e = RegExp(r'^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)').firstMatch(i.fields['Expires'] ?? '');
  final off = RegExp(r'([+-])(\d\d):(\d\d)$').firstMatch(i.time!.trim());
  if (e != null) {
    final naive = DateTime.utc(int.parse(e.group(1)!), int.parse(e.group(2)!), int.parse(e.group(3)!), int.parse(e.group(4)!), int.parse(e.group(5)!));
    final minutes = off == null ? 0 : (off.group(1) == '-' ? -1 : 1) * (int.parse(off.group(2)!) * 60 + int.parse(off.group(3)!));
    to = naive.subtract(Duration(minutes: minutes));
  }
  return (from: t.toUtc(), to: to ?? t.toUtc().add(const Duration(hours: 6)));
}

bool _spansMeet(({DateTime from, DateTime to})? a, ({DateTime from, DateTime to})? b) =>
    a == null || b == null || (!a.from.isAfter(b.to) && !b.from.isAfter(a.to));

/// What is remembered of an alert that was told about: its CAP identifier, its event, its box, when it was in force and the
/// places it was near. A copy that comes later is the same alert when it has the same identifier, or the same event over the same
/// ground at the same time (an NWS update has a new identifier; IPAWS carries the same message as NWS).
class ToldAlert {
  const ToldAlert({required this.id, required this.event, this.box, this.from, this.to, this.places = const []});

  final String id;
  final String event;

  /// [west, south, east, north], or null when the alert had no area.
  final List<double>? box;
  final DateTime? from;
  final DateTime? to;
  final List<String> places;

  static ToldAlert of(LiveItem i, Iterable<String> places) {
    final span = alertSpan(i);
    return ToldAlert(id: capId(i), event: alertEvent(i), box: boxOf(i.area), from: span?.from, to: span?.to, places: [...places]);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'event': event,
    if (box != null) 'box': box,
    if (from != null) 'from': from!.toUtc().toIso8601String(),
    if (to != null) 'to': to!.toUtc().toIso8601String(),
    'places': places,
  };

  static ToldAlert? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['event'] is! String) return null;
    final b = j['box'];
    return ToldAlert(
      id: j['id'] as String,
      event: j['event'] as String,
      box: b is List && b.length == 4 && b.every((x) => x is num) ? [for (final x in b) (x as num).toDouble()] : null,
      from: j['from'] is String ? DateTime.tryParse(j['from'] as String) : null,
      to: j['to'] is String ? DateTime.tryParse(j['to'] as String) : null,
      places: [if (j['places'] is List) for (final p in j['places'] as List) '$p'],
    );
  }

  /// Whether [i], seen at [place], is this alert again.
  bool matches(LiveItem i, String place) {
    if (capId(i) == id) return true;
    if (alertEvent(i) != event) return false;
    final mine = (from: from, to: to);
    final span = alertSpan(i);
    if (mine.from != null && mine.to != null && span != null && !_spansMeet((from: mine.from!, to: mine.to!), span)) return false;
    final b = boxOf(i.area);
    if (box != null && b != null) return areasMeet(boxPolygon(box!), boxPolygon(b));
    return places.contains(place);
  }
}

/// One item that may pop up, before copies of the same alert are joined.
class _Seen {
  _Seen(this.item, this.view, this.place, this.custom, this.serious, this.extreme);

  final LiveItem item;
  final SourceView view;
  final WatchPlace place;
  final bool custom;
  final bool serious;
  final bool extreme;

  /// A warning (an alerts source) rather than a fire or another kind of event: these are joined by their CAP identity.
  bool get alert => view.source.category == 'alerts' || view.source.id == 'alerts';
}

/// Whether [a] and [b] are copies of one alert (two sources, or two watched places): the same CAP identifier; or the same event,
/// over the same ground (their areas meet; without an area, both are near the same watched place) at the same time. Fires and
/// other events are the same when their source and key are.
bool sameAlert(LiveItem a, WatchPlace pa, bool alertA, LiveItem b, WatchPlace pb, bool alertB, {String? sourceA, String? sourceB}) {
  if (!alertA || !alertB) return !alertA && !alertB && sourceA == sourceB && a.key == b.key;
  if (capId(a) == capId(b)) return true;
  // a source lists an alert once per place: two identifiers of one source are two alerts
  if (sourceA != null && sourceA == sourceB) return false;
  if (alertEvent(a) != alertEvent(b)) return false;
  if (!_spansMeet(alertSpan(a), alertSpan(b))) return false;
  if (hasArea(a.area) && hasArea(b.area)) return areasMeet(a.area, b.area);
  return pa.id == pb.id;
}

/// The items in [views] (grouped by place) that have not been told about before, at most one fire source per place (incidents and
/// perimeters describe the same fires: the source with the most items speaks for them), one pop-up per alert: copies of the same
/// alert from several sources (NWS and FEMA IPAWS) and at several watched places are joined ([sameAlert]) and pop up once, near
/// all of those places. [told] holds the addresses told about; [toldAlerts] what is remembered of each alert told about, so an
/// update or another source's copy does not pop up again ([ToldAlert.matches]).
/// [rules] gives a place's own alert rule (Places notebook, the place's gear): off pops up nothing for it, custom pops up the
/// chosen kinds within its distance; the default follows [raisesAlerts]. [fireReach] is how far out fires count as serious for a
/// place (else a custom rule's distance, else [kFireReachMiles]).
List<NewAlert> pickNewAlerts(Map<WatchPlace, List<SourceView>> views, Set<String> told,
    {PlaceAlertRule Function(String placeId)? rules, double Function(WatchPlace place)? fireReach, List<ToldAlert> toldAlerts = const []}) {
  final seen = <_Seen>[];
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
        if (custom) {
          final mi = milesIn(i.distance);
          if (mi != null && mi > rule.miles) continue;
        }
        final severity = i.fields.entries.where((f) => f.key.toLowerCase() == 'severity').map((f) => f.value.toLowerCase()).firstOrNull;
        final serious = isSerious(i, fire: v.source.category == 'fire', severity: severity, fireReachMiles: fireReach?.call(place) ?? (custom ? rule.miles.toDouble() : kFireReachMiles));
        seen.add(_Seen(i, v, place, custom, serious, severity == 'extreme'));
      }
    }
  }
  // join the copies of one alert (each joins the first group it is the same as)
  final groups = <List<_Seen>>[];
  for (final s in seen) {
    final g = groups.where((g) => g.any((o) => sameAlert(o.item, o.place, o.alert, s.item, s.place, s.alert, sourceA: o.view.source.id, sourceB: s.view.source.id))).firstOrNull;
    if (g == null) {
      groups.add([s]);
    } else {
      g.add(s);
    }
  }
  final out = <NewAlert>[];
  for (final g in groups) {
    final isTold = g.any((s) => told.contains(s.item.address) || (s.alert && toldAlerts.any((t) => t.matches(s.item, s.place.id))));
    if (isTold) continue;
    final first = g.first;
    final places = <WatchPlace>[];
    for (final s in g) {
      if (!places.any((p) => p.id == s.place.id)) places.add(s.place);
    }
    out.add(NewAlert(
      item: first.item,
      source: first.view.source.id,
      place: first.place,
      places: places,
      addresses: [for (final s in g) s.item.address],
      extreme: g.any((s) => s.extreme),
      serious: g.any((s) => s.serious),
      custom: g.any((s) => s.custom),
      told: [for (final s in g) if (s.alert) ToldAlert.of(s.item, [for (final p in places) p.id])],
    ));
  }
  return out;
}

/// What has been told about, kept in a small file so restarts and background runs never repeat a pop-up: the addresses of the
/// items told about (the file's strings, as before) and what is remembered of each alert ([ToldAlert], the file's objects).
class ToldStore {
  ToldStore(File file) : _where = (() async => file);

  /// For when the folder is only known later (the app reads its support folder at start).
  ToldStore.lazy(this._where);

  final Future<File> Function() _where;

  /// The most kept; older ones drop off (an alert that old has long ended).
  static const int keep = 500;

  Future<List<Object?>> _all() async {
    try {
      final file = await _where();
      if (!await file.exists()) return [];
      final j = jsonDecode(await file.readAsString());
      return j is List ? j : [];
    } catch (_) {
      return [];
    }
  }

  /// The addresses told about.
  Future<Set<String>> read() async => {for (final a in await _all()) if (a is String) a};

  /// What is remembered of the alerts told about.
  Future<List<ToldAlert>> readAlerts() async => [for (final a in await _all()) ?ToldAlert.fromJson(a)];

  Future<void> add(Iterable<String> addresses, {Iterable<ToldAlert> alerts = const []}) async {
    final list = [...(await _all()), ...addresses, for (final a in alerts) a.toJson()];
    final kept = list.length > keep ? list.sublist(list.length - keep) : list;
    final file = await _where();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(kept), flush: true);
    await tmp.rename(file.path);
  }
}

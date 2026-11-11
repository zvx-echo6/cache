import 'dart:convert';
import 'dart:io';

import '../files.dart';
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
    this.marks = const [],
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

  /// Kept in the told list beside [allAddresses]: for a serious fire or other event at "Where I am", that it was told as serious
  /// ([seriousMark]).
  final List<String> marks;

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

/// An item's distance in miles, or null when it gives none: the number the core gives beside its distance field (0 when the
/// place is inside the item's area: a fire you are standing in is as near as a fire gets). The words of the field ("12 mi SE",
/// "8.5 km N") are read only for an item stored before the core gave the number; "inside the area" has no number in it, which
/// is how a place inside a fire's edge came to count as no distance at all.
double? distanceMiles(LiveItem i) {
  final km = i.distanceKm;
  if (km != null) return km / 1.609344;
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
String capId(LiveItem i) => _bareId(i.key);

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

String _bareId(String id) {
  final k = id.trim();
  return k.endsWith('.IPAWS') ? k.substring(0, k.length - '.IPAWS'.length) : k;
}

/// The alert's message type as the service gives it ("Alert", "Update", "Cancel"), or null when the source's definition does
/// not pass it on. A source that passes it on also passes on references and VTEC where a message has them, so an alert with a
/// message type is one whose identity can be told from those ([ToldAlert.matches]).
String? alertMessageType(LiveItem i) {
  final t = i.app['message_type'];
  return t is String && t.trim().isNotEmpty ? t.trim() : null;
}

/// A message that takes an alert back.
bool isCancel(LiveItem i) => alertMessageType(i)?.toLowerCase() == 'cancel';

/// The identifiers of the earlier messages [i] replaces (CAP references), as [capId] writes identifiers. NWS gives a list of
/// `{identifier, sender, sent}`; a CAP document gives one text of `sender,identifier,sent` groups with spaces between.
List<String> alertRefs(LiveItem i) {
  final out = <String>[];
  void one(Object? r) {
    if (r is Map && r['identifier'] is String) {
      out.add(_bareId(r['identifier'] as String));
    } else if (r is String) {
      for (final group in r.trim().split(RegExp(r'\s+'))) {
        if (group.isEmpty) continue;
        final parts = group.split(',');
        out.add(_bareId(parts.length >= 3 ? parts.sublist(1, parts.length - 1).join(',') : group));
      }
    }
  }

  final refs = i.app['references'];
  if (refs is List) {
    refs.forEach(one);
  } else {
    one(refs);
  }
  return out;
}

final RegExp _vtecLine = RegExp(r'/[A-Z]\.([A-Z]{3})\.([A-Z0-9]{4})\.([A-Z]{2})\.([A-Z])\.(\d{4})\.');

/// The NWS events a message belongs to, from its VTEC lines: office, phenomenon, significance and event number
/// ("KABQ.FF.W.0239"). An update of a warning keeps them; another warning of the same kind has another number. A line that
/// says the event was upgraded to another (action UPG) names the event that ended, not this message's, and is left out.
/// The definition gives the lines as `vtec`, or (a CAP document) among its `parameters` (`{valueName: "VTEC", value}`).
Set<String> alertVtec(LiveItem i) {
  final lines = <String>[];
  void take(Object? v) {
    if (v is String) {
      lines.add(v);
    } else if (v is List) {
      v.forEach(take);
    }
  }

  take(i.app['vtec']);
  final params = i.app['parameters'];
  for (final p in params is List ? params : [params]) {
    if (p is Map && '${p['valueName']}'.toUpperCase() == 'VTEC') take(p['value']);
  }
  return {
    for (final l in lines)
      for (final m in _vtecLine.allMatches(l))
        if (m.group(1) != 'UPG') '${m.group(2)}.${m.group(3)}.${m.group(4)}.${m.group(5)}',
  };
}

/// How grave an alert is, from its "Severity" field: extreme 4, severe 3, moderate 2, minor 1, anything else 0.
int severityRank(String? severity) => switch (severity?.trim().toLowerCase()) {
  'extreme' => 4,
  'severe' => 3,
  'moderate' => 2,
  'minor' => 1,
  _ => 0,
};

String? _severityOf(LiveItem i) => i.fields.entries.where((f) => f.key.toLowerCase() == 'severity').map((f) => f.value.toLowerCase()).firstOrNull;

/// Whether one of two messages names the other among its references, or both name the same earlier one, or they share an NWS
/// event ([alertVtec]): two messages of one alert.
bool _sameChain(LiveItem a, LiveItem b) {
  final ra = alertRefs(a), rb = alertRefs(b);
  return ra.contains(capId(b)) || rb.contains(capId(a)) || ra.any(rb.contains) || alertVtec(a).any(alertVtec(b).contains);
}

/// [items] without what was taken back: a cancel message is not something happening, and neither is the alert it references.
/// For the app's lists and pop-ups only (the assistant reads the source's own list).
List<LiveItem> withoutCancelled(List<LiveItem> items) {
  if (!items.any(isCancel)) return items;
  final gone = {for (final i in items) if (isCancel(i)) ...alertRefs(i)};
  return [for (final i in items) if (!isCancel(i) && !gone.contains(capId(i))) i];
}

bool _spansMeet(({DateTime from, DateTime to})? a, ({DateTime from, DateTime to})? b) =>
    a == null || b == null || (!a.from.isAfter(b.to) && !b.from.isAfter(a.to));

/// What is remembered of an alert that was told about: its CAP identifier, its event, its area, when it was in force, the places
/// it was near, how grave it was, and (where the source gives them) the messages it replaced and its NWS event ([alertVtec]).
/// A message that comes later is the same alert when [matches] says so. The first told lists kept the identifier, event, box,
/// times and places only: they read as before.
class ToldAlert {
  const ToldAlert({
    required this.id,
    required this.event,
    this.box,
    this.from,
    this.to,
    this.places = const [],
    this.area,
    this.severity,
    this.messageType,
    this.refs = const [],
    this.vtec = const [],
  });

  final String id;
  final String event;

  /// [west, south, east, north], or null when the alert had no area.
  final List<double>? box;
  final DateTime? from;
  final DateTime? to;
  final List<String> places;

  /// The alert's own area (GeoJSON), kept when it is small enough ([maxAreaChars]); else [box] stands in.
  final Map<String, dynamic>? area;

  /// "extreme", "severe", ... as it was told; null in a list from before it was kept.
  final String? severity;

  /// The message type, when the source gives one ([alertMessageType]): this alert's identity is known from [refs] and [vtec].
  final String? messageType;

  /// The identifiers of the messages this one replaced.
  final List<String> refs;

  /// Its NWS events ([alertVtec]).
  final List<String> vtec;

  /// The most an area may take in the told list, as JSON.
  static const int maxAreaChars = 2000;

  static ToldAlert of(LiveItem i, Iterable<String> places) {
    final span = alertSpan(i);
    final area = i.area != null && hasArea(i.area) && jsonEncode(i.area).length <= maxAreaChars ? i.area : null;
    return ToldAlert(
      id: capId(i),
      event: alertEvent(i),
      box: boxOf(i.area),
      from: span?.from,
      to: span?.to,
      places: [...places],
      area: area,
      severity: _severityOf(i),
      messageType: alertMessageType(i),
      refs: alertRefs(i),
      vtec: [...alertVtec(i)],
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'event': event,
    if (box != null) 'box': box,
    if (from != null) 'from': from!.toUtc().toIso8601String(),
    if (to != null) 'to': to!.toUtc().toIso8601String(),
    'places': places,
    if (area != null) 'area': area,
    if (severity != null) 'severity': severity,
    if (messageType != null) 'message_type': messageType,
    if (refs.isNotEmpty) 'refs': refs,
    if (vtec.isNotEmpty) 'vtec': vtec,
  };

  static ToldAlert? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['event'] is! String) return null;
    final b = j['box'];
    List<String> texts(Object? v) => [if (v is List) for (final x in v) if (x is String) x];
    return ToldAlert(
      id: j['id'] as String,
      event: j['event'] as String,
      box: b is List && b.length == 4 && b.every((x) => x is num) ? [for (final x in b) (x as num).toDouble()] : null,
      from: j['from'] is String ? DateTime.tryParse(j['from'] as String) : null,
      to: j['to'] is String ? DateTime.tryParse(j['to'] as String) : null,
      places: [if (j['places'] is List) for (final p in j['places'] as List) '$p'],
      area: j['area'] is Map ? (j['area'] as Map).cast<String, dynamic>() : null,
      severity: j['severity'] is String ? j['severity'] as String : null,
      messageType: j['message_type'] is String ? j['message_type'] as String : null,
      refs: texts(j['refs']),
      vtec: texts(j['vtec']),
    );
  }

  /// Whether [i], seen at [place], is this alert again: the same message, an update of it, or an earlier message of it.
  ///
  /// The same identifier always is. Where both this record and [i] come with a message type, the service says what belongs
  /// together and nothing is guessed: [i] is this alert when it has the same event name and one of the two references the other
  /// (or both reference the same earlier message), or they share an NWS event; a message with neither is another alert, even
  /// with the same event name, at the same time, on touching ground. Without a message type on either side (a source that
  /// passes none on, or a list from before) it is the comparison there was: the same event, at the same time, over the same
  /// ground, now by the areas themselves and not the boxes around them (a list from before has only the box).
  bool matches(LiveItem i, String place) {
    final other = capId(i);
    if (other == id) return true;
    if (alertEvent(i) != event) return false;
    final span = alertSpan(i);
    if (messageType != null && alertMessageType(i) != null) {
      final theirs = alertRefs(i);
      if (theirs.contains(id) || refs.contains(other) || refs.any(theirs.contains)) return true;
      // event numbers start again each year: an event that ended long before this message began is not it
      final longAgo = to != null && span != null && span.from.difference(to!) > const Duration(days: 10);
      return !longAgo && vtec.any(alertVtec(i).contains);
    }
    if (from != null && to != null && span != null && !_spansMeet((from: from!, to: to!), span)) return false;
    final mine = area ?? (box == null ? null : boxPolygon(box!));
    if (mine != null && hasArea(i.area)) return areasMeet(mine, i.area);
    return places.contains(place);
  }
}

/// The address of an item at "Where I am" without the position in it: `live:<source>/at:<lat>,<lon>/<item>` as
/// `live:<source>/at:/<item>`. The place key of "Where I am" is the position rounded to 0.01 degrees, so the same fire has a new
/// address each time the phone moves about a kilometre. Null for an item at any other place.
String? hereMark(String address) {
  final parts = address.split('/');
  if (parts.length < 3 || !parts[0].startsWith('live:') || !parts[1].startsWith('at:')) return null;
  // parameters other than a source's defaults are part of the place key ("at:42.54,-113.79~1a2b3c4d"): they stay
  final cut = parts[1].indexOf('~');
  return [parts[0], cut < 0 ? 'at:' : 'at:${parts[1].substring(cut)}', ...parts.sublist(2)].join('/');
}

/// What the told list keeps when the item of [hereMark] was told while it was serious.
String seriousMark(String mark) => 'serious:$mark';

/// One item that may pop up, before copies of the same alert are joined.
class _Seen {
  _Seen(this.item, this.view, this.place, this.custom, this.serious, this.extreme, {this.fireNamed = false});

  /// A fire with a name of its own in its source ([ownFireNames]): the same fire as another fire source's of that name.
  final bool fireNamed;

  /// Whether [o] is this fire as another fire source has it.
  bool sameFireAs(_Seen o) => fireNamed && o.fireNamed && view.source.id != o.view.source.id && fireName(item) == fireName(o.item);

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
  // an update listed beside the message it replaces, or two messages of one NWS event: one alert, whichever source lists them
  if (alertEvent(a) == alertEvent(b) && _sameChain(a, b)) return true;
  // a source lists an alert once per place: two identifiers of one source are two alerts
  if (sourceA != null && sourceA == sourceB) return false;
  if (alertEvent(a) != alertEvent(b)) return false;
  if (!_spansMeet(alertSpan(a), alertSpan(b))) return false;
  if (hasArea(a.area) && hasArea(b.area)) return areasMeet(a.area, b.area);
  return pa.id == pb.id;
}

/// A fire's name as two feeds would both write it: its label in small letters, without the "perimeter" a perimeter source puts
/// after it ("East Fork fire perimeter" is the "East Fork fire" of the incident source).
String fireName(LiveItem i) {
  final n = i.label.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return n.endsWith(' perimeter') ? n.substring(0, n.length - ' perimeter'.length) : n;
}

/// The names that tell a fire apart in [v]: those exactly one of its items has. A named incident has its own name; a feed of
/// satellite detections writes the same label on every one, and that label names no fire.
Set<String> ownFireNames(SourceView v) {
  final count = <String, int>{};
  for (final i in v.active) {
    count.update(fireName(i), (n) => n + 1, ifAbsent: () => 1);
  }
  return {for (final e in count.entries) if (e.value == 1) e.key};
}

/// The fires of every fire source at one place, as one list. Every item of every source is in it, except that a fire two
/// sources both name ([fireName], a name of its own in each: [ownFireNames]) is listed once, as the first source has it. The
/// feeds share nothing else the app can see (their item keys are each feed's own), so two feeds that write a fire's name
/// differently list it twice: twice is better than not at all. The sources take turns (each one's first item, which is its
/// nearest, before any one's second), so a source with many items, as satellite detections are, cannot push a named fire out of
/// the few lines Home has.
///
/// Before, one source spoke for all: the one with the most items, because incidents and their perimeters describe the same
/// fires. With satellite detections on, that was the detections, and no named fire was listed or popped up.
List<(LiveItem, SourceView)> firesOnce(List<SourceView> fireViews) {
  final seenNames = <String>{};
  final lists = <List<(LiveItem, SourceView)>>[];
  for (final v in fireViews) {
    final own = ownFireNames(v);
    lists.add([
      for (final i in v.active)
        if (!(own.contains(fireName(i)) && seenNames.contains(fireName(i)))) (i, v),
    ]);
    seenNames.addAll(own);
  }
  final out = <(LiveItem, SourceView)>[];
  for (var n = 0; lists.any((l) => l.length > n); n++) {
    for (final l in lists) {
      if (l.length > n) out.add(l[n]);
    }
  }
  return out;
}

/// The items in [views] (grouped by place) that have not been told about before. Every fire source speaks; the same fire from
/// two of them is one pop-up (see [firesOnce] for how they are told to be the same). One pop-up per alert: copies of the same
/// alert from several sources (NWS and FEMA IPAWS) and at several watched places are joined ([sameAlert]) and pop up once, near
/// all of those places. [told] holds the addresses told about (and the [seriousMark]s); [toldAlerts] what is remembered of each
/// alert told about, so an update or another source's copy does not pop up again ([ToldAlert.matches]).
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
    for (final v in counted) {
      final ownNames = v.source.category == 'fire' ? ownFireNames(v) : const <String>{};
      for (final i in v.active) {
        if (custom) {
          final mi = distanceMiles(i) ?? milesIn(i.distance);
          if (mi != null && mi > rule.miles) continue;
        }
        final severity = i.fields.entries.where((f) => f.key.toLowerCase() == 'severity').map((f) => f.value.toLowerCase()).firstOrNull;
        final serious = isSerious(i, fire: v.source.category == 'fire', severity: severity, fireReachMiles: fireReach?.call(place) ?? (custom ? rule.miles.toDouble() : kFireReachMiles));
        seen.add(_Seen(i, v, place, custom, serious, severity == 'extreme', fireNamed: ownNames.contains(fireName(i))));
      }
    }
  }
  // join the copies of one alert (each joins the first group it is the same as)
  final groups = <List<_Seen>>[];
  for (final s in seen) {
    final g = groups.where((g) => g.any((o) => o.sameFireAs(s) || sameAlert(o.item, o.place, o.alert, s.item, s.place, s.alert, sourceA: o.view.source.id, sourceB: s.view.source.id))).firstOrNull;
    if (g == null) {
      groups.add([s]);
    } else {
      g.add(s);
    }
  }
  // "Where I am" moved: a fire (or another event that is not a warning; warnings are known by their identifiers) told at one
  // position is the same one at the next, though its address differs. It pops up again only when it is serious now and was not
  // told as serious before: a fire first seen far away still pops up once it is close.
  final toldHere = {for (final a in told) ?hereMark(a)};
  bool toldAtAnotherPosition(_Seen s) {
    if (s.alert) return false;
    final mark = hereMark(s.item.address);
    if (mark == null || !toldHere.contains(mark)) return false;
    return !s.serious || told.contains(seriousMark(mark));
  }

  // A warning at one place: told when this very copy was (its address), or when the told list has this alert ([ToldAlert.matches])
  // for this place and as grave as it is now. An alert told for another place is news here (it reaches a watched place it did
  // not reach), and one that has become graver is news again; a later end or other words are not.
  bool warningTold(_Seen s) {
    if (told.contains(s.item.address)) return true;
    final here = [for (final t in toldAlerts) if (t.matches(s.item, s.place.id) && t.places.contains(s.place.id)) t];
    if (here.isEmpty) return false;
    // a list from before kept no severity: nothing to compare, so not graver
    final known = [for (final t in here) if (t.severity != null) severityRank(t.severity)];
    return known.isEmpty || severityRank(_severityOf(s.item)) <= known.reduce((a, b) => a > b ? a : b);
  }

  final out = <NewAlert>[];
  for (final g in groups) {
    // the copies that are news: of a warning, those at the places it was not told for; of a fire or another event, all of
    // them or none (as before)
    final news = g.first.alert
        ? [for (final s in g) if (!warningTold(s)) s]
        : (g.any((s) => told.contains(s.item.address) || toldAtAnotherPosition(s)) ? const <_Seen>[] : g);
    if (news.isEmpty) continue;
    final first = news.first;
    final places = <WatchPlace>[];
    for (final s in news) {
      if (!places.any((p) => p.id == s.place.id)) places.add(s.place);
    }
    // remembered for every place it is near now, the ones told before too
    final near = {for (final s in g) s.place.id};
    out.add(NewAlert(
      item: first.item,
      source: first.view.source.id,
      place: first.place,
      places: places,
      addresses: [for (final s in g) s.item.address],
      extreme: news.any((s) => s.extreme),
      serious: news.any((s) => s.serious),
      custom: news.any((s) => s.custom),
      told: [for (final s in g) if (s.alert) ToldAlert.of(s.item, near)],
      marks: [
        for (final s in g)
          if (!s.alert && s.serious)
            if (hereMark(s.item.address) case final m?) seriousMark(m),
      ],
    ));
  }
  return out;
}

/// What a [ToldStore] holds: the addresses told about and what is remembered of each alert. [known] is false when the list
/// is there but cannot be read and no earlier copy of it is left: then nothing is known of what was told, and the list is
/// empty (the alert check then tells what is in force once more, and logs it: repeating an alert is better than missing one).
typedef ToldList = ({Set<String> addresses, List<ToldAlert> alerts, bool known});

/// What has been told about, kept in a small file so restarts and background runs never repeat a pop-up: the addresses of the
/// items told about (the file's strings, as before) and what is remembered of each alert ([ToldAlert], the file's objects).
/// A second copy is kept beside it (`<file>.bak`), and the store remembers the last list it read or wrote: a file that cannot
/// be read falls back to those, and only when none is left is it an empty list (see [ToldList]).
class ToldStore {
  ToldStore(File file) : _where = (() async => file);

  /// For when the folder is only known later (the app reads its support folder at start).
  ToldStore.lazy(this._where);

  final Future<File> Function() _where;

  /// The most kept; older ones drop off (an alert that old has long ended).
  static const int keep = 500;

  /// The last list read from the file or written to it by this store.
  List<Object?>? _last;

  /// The list in [f]; null when it cannot be read as one.
  static Future<List<Object?>?> _listIn(File f) async {
    try {
      final j = jsonDecode(await f.readAsString());
      return j is List ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// The list, and whether it is known: from the file; when that cannot be read, from the copy beside it, then from what this
  /// store last had. No file at all is a list that is known to be empty (nothing was told yet).
  Future<({List<Object?> list, bool known})> _all() async {
    final File file;
    try {
      file = await _where();
    } catch (_) {
      return (list: _last ?? const <Object?>[], known: _last != null);
    }
    var there = true;
    try {
      there = await file.exists();
    } catch (_) {}
    if (there) {
      final list = await _listIn(file);
      if (list != null) {
        _last = list;
        return (list: list, known: true);
      }
    }
    final copy = await _listIn(File('${file.path}.bak'));
    if (copy != null) {
      _last = copy;
      return (list: copy, known: true);
    }
    final last = _last;
    if (last != null) return (list: last, known: true);
    return (list: const <Object?>[], known: !there);
  }

  /// Everything told about, read once.
  Future<ToldList> load() async {
    final all = await _all();
    return (
      addresses: {for (final a in all.list) if (a is String) a},
      alerts: [for (final a in all.list) ?ToldAlert.fromJson(a)],
      known: all.known,
    );
  }

  /// The addresses told about.
  Future<Set<String>> read() async => (await load()).addresses;

  /// What is remembered of the alerts told about.
  Future<List<ToldAlert>> readAlerts() async => (await load()).alerts;

  /// Adds to the list. Each file is written whole under a name of its own and renamed into place, so a reader never sees half
  /// a list and two writers (the app and a background run) never share a temporary file. When it cannot be saved, this store
  /// still remembers it for as long as it lives.
  Future<void> add(Iterable<String> addresses, {Iterable<ToldAlert> alerts = const []}) async {
    final list = [...(await _all()).list, ...addresses, for (final a in alerts) a.toJson()];
    final kept = list.length > keep ? list.sublist(list.length - keep) : list;
    _last = kept;
    try {
      final file = await _where();
      await file.parent.create(recursive: true);
      final text = jsonEncode(kept);
      await writeStringAtomic(file, text);
      await writeStringAtomic(File('${file.path}.bak'), text);
    } catch (_) {}
  }
}

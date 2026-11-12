import 'alert_watch.dart';
import 'connector.dart';
import 'live_view.dart';
import 'place_alerts.dart';
import 'places.dart';
import 'words.dart';

/// How long a reading (a forecast's "Now", a station's latest) stands for the weather now, counted from its own time. The
/// forecast source ends its "Now" three hours after it was taken and the core then leaves it out; a copy the app kept is held to
/// the same, so a temperature from this morning is never shown as the temperature now.
const Duration kReadingLasts = Duration(hours: 3);

/// From this age a reading is shown with the time it was taken ("As of 2:15 PM").
const Duration kReadingAsOf = Duration(hours: 1);

/// How many fires that are not serious "Happening nearby" lists before "N more fires".
const int kFiresListed = 3;

/// A source of warnings (weather and emergency alerts): its items carry a severity and are one alert when [sameAlert] says so.
bool isWarningSource(Connector c) => c.category == 'alerts' || c.id == 'alerts';

/// A source of fires: its items are serious by how near they are ([isSerious]).
bool isFireSource(Connector c) => c.category == 'fire';

/// What kind of event a row of "Happening nearby" is.
enum NearbyKind {
  /// A weather or emergency alert.
  warning,

  /// A fire.
  fire,

  /// Another kind the place's own alert rule names (earthquakes, river levels and the rest).
  other,
}

/// One event of "Happening nearby" the app can rank: a warning, a fire, or an item of a kind the place's own alert rule names.
class NearbyEvent {
  const NearbyEvent({required this.item, required this.view, required this.kind, required this.serious, this.severity, this.same = const []});

  /// The copy shown: of an alert two sources carry, the first source's; of items that share a name, the nearest.
  final LiveItem item;
  final SourceView view;
  final NearbyKind kind;

  /// Serious by the app's own test ([isSerious]), the one "Serious only" pops up by.
  final bool serious;

  /// "extreme", "severe", "moderate", "minor" as the source gives it, or null.
  final String? severity;

  /// The items of one source that share this name, nearest first ([item] is the first): a feed of satellite detections writes
  /// the same label on every one. Empty for an item with a name of its own.
  final List<LiveItem> same;

  double? get miles => distanceMiles(item);
}

/// "Happening nearby" for one place, in the order it is listed.
class Nearby {
  const Nearby({this.serious = const [], this.warnings = const [], this.fires = const [], this.ruled = const [], this.sources = const []});

  /// Serious events: warnings by severity, then fires nearest first, then other kinds.
  final List<NearbyEvent> serious;

  /// The other warnings (watches, advisories, statements), by severity as the service ranks them.
  final List<NearbyEvent> warnings;

  /// The other fires, nearest first.
  final List<NearbyEvent> fires;

  /// The other items of the kinds the place's own alert rule names, nearest first.
  final List<NearbyEvent> ruled;

  /// Every other source that is on, one row each: kinds the app has no way to rank.
  final List<SourceView> sources;

  /// Every ranked event, most serious first.
  List<NearbyEvent> get ranked => [...serious, ...warnings, ...fires, ...ruled];

  /// The ranked events the list shows: of the fires that are not serious, the nearest [kFiresListed].
  List<NearbyEvent> get listed => [...serious, ...warnings, ...fires.take(kFiresListed), ...ruled];

  /// The fires behind "N more fires".
  List<NearbyEvent> get moreFires => fires.length > kFiresListed ? fires.sublist(kFiresListed) : const [];

  /// Whether a warning or a fire is listed (what the calm line speaks for).
  bool get anyAlertOrFire => ranked.any((e) => e.kind != NearbyKind.other);
}

/// A source's kind as a place's alert rule names it ([kAlertKinds]): its catalogue category; the built-in alerts source has
/// none, and is "alerts".
String _kindOf(Connector c) => c.category == 'other' && c.id == 'alerts' ? 'alerts' : c.category;

double _near(LiveItem i) => distanceMiles(i) ?? double.infinity;

/// [list] sorted by [compare], items that compare equal staying in the order they came in.
List<T> _sorted<T>(List<T> list, int Function(T a, T b) compare) {
  final numbered = [for (var n = 0; n < list.length; n++) (n, list[n])];
  numbered.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in numbered) e.$2];
}

/// What is happening near [place], from what the sources hold for it ([views]), ordered by the rule the pop-ups go by:
///
/// 1. serious events ([isSerious]): warnings by severity (extreme, then severe, then an evacuation of any severity), then fires
///    within reach nearest first;
/// 2. the other warnings, by severity;
/// 3. the other fires, nearest first;
/// 4. the items of any other kind the place's own [rule] names, within its distance, nearest first;
/// 5. every other source, one row each.
///
/// The same alert from two sources is one event ([sameAlert]), a fire two sources name is one event ([firesOnce]), and the
/// items of one fire source that share a name are one event with the nearest in front. A place whose rule is "off" pops up
/// nothing, but its alerts are listed here as any other place's.
Nearby nearbyOf(WatchPlace place, List<SourceView> views, {PlaceAlertRule rule = PlaceAlertRule.same}) {
  final custom = rule.mode == PlaceAlertMode.custom;
  final reach = fireReachOf(rule);
  final happening = [for (final v in views) if (v.group == LiveGroup.alerts) v];

  final warnings = <NearbyEvent>[];
  for (final v in happening) {
    if (v.missing || !isWarningSource(v.source)) continue;
    for (final i in v.active) {
      if (warnings.any((e) => sameAlert(e.item, place, true, i, place, true, sourceA: e.view.source.id, sourceB: v.source.id))) continue;
      final severity = severityOf(i);
      warnings.add(NearbyEvent(item: i, view: v, kind: NearbyKind.warning, severity: severity, serious: isSerious(i, fire: false, severity: severity, fireReachMiles: reach)));
    }
  }

  // the fires of every fire source, a fire two of them name once; then the items of one source that share a name as one event
  final fireViews = [for (final v in happening) if (!v.missing && isFireSource(v.source)) v];
  final named = <String, List<LiveItem>>{};
  final firstOf = <String, SourceView>{};
  for (final (i, v) in firesOnce(fireViews)) {
    final name = '${v.source.id}\n${fireName(i)}';
    firstOf.putIfAbsent(name, () => v);
    named.putIfAbsent(name, () => []).add(i);
  }
  final fires = <NearbyEvent>[];
  for (final e in named.entries) {
    final items = _sorted(e.value, (a, b) => _near(a).compareTo(_near(b)));
    final first = items.first;
    final severity = severityOf(first);
    fires.add(NearbyEvent(
      item: first,
      view: firstOf[e.key]!,
      kind: NearbyKind.fire,
      severity: severity,
      serious: isSerious(first, fire: true, severity: severity, fireReachMiles: reach),
      same: items.length > 1 ? items : const [],
    ));
  }

  final ruled = <NearbyEvent>[];
  final sources = <SourceView>[];
  for (final v in happening) {
    if (isWarningSource(v.source) || isFireSource(v.source)) continue;
    if (v.missing || !custom || !rule.kinds.contains(_kindOf(v.source))) {
      sources.add(v);
      continue;
    }
    var beyond = false;
    for (final i in v.active) {
      final miles = distanceMiles(i) ?? milesIn(i.distance);
      if (miles != null && miles > rule.miles) {
        beyond = true;
        continue;
      }
      final severity = severityOf(i);
      ruled.add(NearbyEvent(item: i, view: v, kind: NearbyKind.other, severity: severity, serious: isSerious(i, fire: false, severity: severity, fireReachMiles: reach)));
    }
    // what the rule leaves out (too far), or nothing at all, is still one row of the source
    if (beyond || v.active.isEmpty) sources.add(v);
  }

  int bySeverity(NearbyEvent a, NearbyEvent b) => severityRank(b.severity).compareTo(severityRank(a.severity));
  int byDistance(NearbyEvent a, NearbyEvent b) => _near(a.item).compareTo(_near(b.item));
  final rankedWarnings = _sorted(warnings, bySeverity);
  final rankedFires = _sorted(fires, byDistance);
  final rankedRuled = _sorted(ruled, byDistance);
  return Nearby(
    serious: [
      for (final e in rankedWarnings) if (e.serious) e,
      for (final e in rankedFires) if (e.serious) e,
      for (final e in rankedRuled) if (e.serious) e,
    ],
    warnings: [for (final e in rankedWarnings) if (!e.serious) e],
    fires: [for (final e in rankedFires) if (!e.serious) e],
    ruled: [for (final e in rankedRuled) if (!e.serious) e],
    sources: sources,
  );
}

/// The date an item is for, when its time is a date alone ("2026-11-11", as a forecast's days are); null for any other item.
DateTime? _dateOf(LiveItem i) {
  final m = RegExp(r'^(\d{4})-(\d\d)-(\d\d)$').firstMatch(i.time?.trim() ?? '');
  return m == null ? null : DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// The start of a period with a time of day; null for a day, or an item without a time.
DateTime? _startOf(LiveItem i) => _dateOf(i) != null ? null : DateTime.tryParse(i.time?.trim() ?? '');

/// The conditions of a reading or a period in the source's words: "Conditions", or what the other weather sources call it (a
/// station's "Sky", a named period's "Summary"). Null when it gives none.
String? conditionsOf(LiveItem? i) => i == null ? null : (i.fields['Conditions'] ?? i.fields['Sky'] ?? i.fields['Summary']);

/// A day's high and low: "Daytime high" and "Low (early morning)", or the names definitions used before them.
String? highOf(LiveItem i) => i.fields['Daytime high'] ?? i.fields['High'];
String? lowOf(LiveItem i) => i.fields['Low (early morning)'] ?? i.fields['Low'];

/// The name a day's high and low go by in [i] ("Daytime high" or "High"), for the names shown beside the values.
String? highNameOf(LiveItem i) => i.fields['Daytime high'] != null ? 'Daytime high' : (i.fields['High'] != null ? 'High' : null);
String? lowNameOf(LiveItem i) => i.fields['Low (early morning)'] != null ? 'Low (early morning)' : (i.fields['Low'] != null ? 'Low' : null);

/// A day's chance of rain, by its name now and the one before it.
String? rainOf(LiveItem i) => i.fields['Chance of rain'] ?? i.fields['Rain chance'];

/// The name a day's chance of rain goes by in [i].
String? rainNameOf(LiveItem i) => i.fields['Chance of rain'] != null ? 'Chance of rain' : (i.fields['Rain chance'] != null ? 'Rain chance' : null);

/// Everything the Weather screen says about one place, worked out from what the sources hold for it: the top card's picks
/// (the reading, the period that covers now), the days, and what is happening nearby. Nothing is fetched here.
class PlaceSummary {
  const PlaceSummary._({
    required this.place,
    required this.views,
    required this.pending,
    required this.today,
    required this.forecastOn,
    required this.forecast,
    required this.reading,
    required this.readingAt,
    required this.now,
    required this.days,
    required this.otherWeather,
    required this.nearby,
    required this.warningsOn,
    required this.firesOn,
    required this.warningsChecked,
    required this.firesChecked,
    required this.tooOld,
    required this.checkedAt,
  });

  /// [views] is what the sources that are on hold for [place] (the core's answer, or what the app kept of the last one);
  /// [pending] says the core has not answered yet, so a source that is not in [views] is not known to hold nothing.
  /// [enabled] is every source that is on, [clock] the time now, [rule] the place's own alert rule.
  factory PlaceSummary.of({
    required WatchPlace place,
    required List<SourceView> views,
    required List<Connector> enabled,
    required DateTime clock,
    PlaceAlertRule rule = PlaceAlertRule.same,
    bool pending = false,
  }) {
    final forecastViews = [for (final v in views) if (v.group == LiveGroup.forecast) v];
    final known = [for (final v in forecastViews) if (!v.missing) v];
    // The top card and the days come from the first forecast that gives a "Now" or days; else the first that holds anything.
    bool fills(SourceView v) => v.items.any((i) => i.address.endsWith('/now') || _dateOf(i) != null);
    final main = known.where(fills).firstOrNull ?? known.where((v) => v.items.isNotEmpty).firstOrNull ?? known.firstOrNull;
    final today = placeToday(clock, main?.fetchedAt);

    // the one rule for what a reading is and how long it stands, Home's too
    final pick = main == null ? null : readingOf(main, clock);
    final reading = pick?.reading;
    final readingAt = pick?.at;
    final upcoming = periodsNotPassed(pick?.periods ?? const <LiveItem>[], clock, today);
    final dated = [for (final i in upcoming) if (_dateOf(i) != null) i];
    final days = dated.isNotEmpty ? dated : upcoming;
    LiveItem? now;
    final first = days.firstOrNull;
    if (first != null) {
      final date = _dateOf(first);
      final start = _startOf(first);
      if (date != null ? date == today : (start == null || !start.isAfter(clock))) now = first;
    }

    final counted = [for (final v in views) if (!v.missing && (isWarningSource(v.source) || isFireSource(v.source))) v];
    DateTime? checkedAt;
    for (final v in counted) {
      final at = DateTime.tryParse(v.fetchedAt?.trim() ?? '');
      if (at != null && (checkedAt == null || at.isBefore(checkedAt))) checkedAt = at;
    }
    return PlaceSummary._(
      place: place,
      views: views,
      pending: pending,
      today: today,
      forecastOn: enabled.any((c) => groupOf(c) == LiveGroup.forecast),
      forecast: main,
      reading: reading,
      readingAt: readingAt,
      now: now,
      days: days,
      otherWeather: main == null ? const [] : [for (final v in forecastViews) if (!identical(v, main)) v],
      nearby: nearbyOf(place, views, rule: rule),
      warningsOn: enabled.any(isWarningSource),
      firesOn: enabled.any(isFireSource),
      warningsChecked: counted.any((v) => isWarningSource(v.source) && !v.expired),
      firesChecked: counted.any((v) => isFireSource(v.source) && !v.expired),
      tooOld: counted.any((v) => v.expired),
      checkedAt: checkedAt,
    );
  }

  final WatchPlace place;
  final List<SourceView> views;

  /// The core has not answered for this place yet: [views] is what the app kept, and a source it kept nothing of may still
  /// hold data.
  final bool pending;

  /// The date at the place now (as midnight UTC, see [placeToday]).
  final DateTime today;

  /// A forecast source is switched on.
  final bool forecastOn;

  /// The source that fills the top card and the days; null when no forecast source holds anything for the place.
  final SourceView? forecast;

  /// The weather now: a forecast's "Now", or the nearest station's latest, while it stands ([kReadingLasts]). Null when there is
  /// none or it has ended: then no temperature is known for now.
  final LiveItem? reading;

  /// When [reading] was taken (its own time, else when it was downloaded).
  final DateTime? readingAt;

  /// The period of [days] that covers now (today's day, or a named period that has started); null when none is known to.
  final LiveItem? now;

  /// The periods that have not passed, one line each: the forecast's days, or its named periods when it has no days.
  final List<LiveItem> days;

  /// The other weather sources that are on, one row each under the forecast.
  final List<SourceView> otherWeather;

  final Nearby nearby;

  /// A warning source, a fire source is switched on.
  final bool warningsOn;
  final bool firesOn;

  /// A warning source, a fire source holds a check for the place that still speaks for now.
  final bool warningsChecked;
  final bool firesChecked;

  /// A warning or fire source's last check is too old to speak for now (the source's own time limit has passed).
  final bool tooOld;

  /// The oldest of the warning and fire sources' last checks.
  final DateTime? checkedAt;

  bool get alertsOn => warningsOn || firesOn;

  /// Something is held for the place.
  bool get anyStored => views.any((v) => !v.missing);

  /// Every day of the stored forecast has passed.
  bool get forecastExpired => forecast != null && forecast!.expired && reading == null && days.isEmpty;

  /// The reading is old enough to say when it was taken ([kReadingAsOf]).
  bool readingIsOld(DateTime clock) => reading != null && readingAt != null && clock.difference(readingAt!) > kReadingAsOf;

  /// Whether [i] is today's day (a day by date, on the place's date now).
  bool isToday(LiveItem i) => _dateOf(i) == today;

  /// No warning or fire is listed and the check still speaks for now: the list may say so.
  bool get calm => !tooOld && (warningsChecked || firesChecked) && !nearby.anyAlertOrFire;

  /// Warning or fire sources are on and none holds a check for the place.
  bool get notChecked => alertsOn && !warningsChecked && !firesChecked && !tooOld;
}

/// What a weather source holds, as [readingOf] reads it: the reading that stands for the weather now (null when it holds none,
/// or its reading has ended), when that reading was taken (also once it has ended), and the periods beside it.
typedef ReadingPick = ({LiveItem? reading, DateTime? at, List<LiveItem> periods});

/// The weather now as [v] holds it at [clock]. The one rule for what a reading is and how long it stands: the Weather
/// screen's top card and Home's card both go by it.
///
/// - A forecast's own "Now" is its reading; its other items are its periods.
/// - A list of readings (weather stations) has no "Now" of its own, no day, and nothing that is still to come: its nearest
///   station that reports a temperature is the reading, and it has no periods.
/// - Any other source holds no reading. A forecast written in periods gives a temperature for each of them (NWS by point:
///   "Tonight", "Thursday"), and a period's temperature is a forecast, never the temperature now.
/// - A reading stands for [kReadingLasts], counted from its own time (else from when it was downloaded). After that it is
///   not the weather now, in the core's answer and in a copy the app kept alike.
ReadingPick readingOf(SourceView v, DateTime clock) {
  final own = v.items.where((i) => i.address.endsWith('/now')).firstOrNull;
  final rest = [for (final i in v.items) if (!identical(i, own)) i];
  final stations = own == null &&
      rest.any((i) => i.fields['Temperature'] != null) &&
      rest.every((i) => _dateOf(i) == null && !(_startOf(i)?.isAfter(clock) ?? false));
  var reading = own ?? (stations ? _nearestReading(rest) : null);
  DateTime? at;
  if (reading != null) {
    at = DateTime.tryParse(reading.time?.trim() ?? '') ?? DateTime.tryParse(v.fetchedAt?.trim() ?? '');
    if (at != null && clock.difference(at) > kReadingLasts) reading = null;
  }
  return (reading: reading, at: at, periods: stations ? const <LiveItem>[] : rest);
}

/// The nearest of [items] that reports a temperature (the first, when none says how far it is); null when none does.
LiveItem? _nearestReading(List<LiveItem> items) {
  LiveItem? pick;
  double? best;
  for (final i in items) {
    if (i.fields['Temperature'] == null) continue;
    final d = distanceMiles(i);
    if (pick == null || (d != null && (best == null || d < best))) {
      pick = i;
      best = d;
    }
  }
  return pick;
}

/// [periods] without those that have passed: a day before [today]; a period with a start time, once a later one has started.
/// The core leaves out what has ended, but a copy the app kept is as the core gave it then. The Weather screen's days and
/// Home's card both go by it, so yesterday's high and low are never shown as today's.
List<LiveItem> periodsNotPassed(List<LiveItem> periods, DateTime clock, DateTime today) {
  DateTime? latest;
  for (final i in periods) {
    final start = _startOf(i);
    if (start != null && !start.isAfter(clock) && (latest == null || start.isAfter(latest))) latest = start;
  }
  final from = latest;
  bool keeps(LiveItem i) {
    final date = _dateOf(i);
    if (date != null) return !date.isBefore(today);
    final start = _startOf(i);
    return start == null || from == null || !start.isBefore(from);
  }

  return [for (final i in periods) if (keeps(i)) i];
}

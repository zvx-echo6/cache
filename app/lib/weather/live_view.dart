import 'connector.dart';
import 'places.dart';

/// Which part of the Weather screen a source belongs to.
enum LiveGroup {
  /// Forecasts and current conditions.
  forecast,

  /// Things that are happening: warnings, fires, earthquakes, river and avalanche danger, road events.
  alerts,
}

/// The group of a source, from its catalogue category (built-in sources have none, so their ids decide).
LiveGroup groupOf(Connector c) {
  final cat = c.category == 'other' ? (c.id == 'weather' ? 'weather' : c.id == 'alerts' ? 'alerts' : 'other') : c.category;
  return cat == 'weather' ? LiveGroup.forecast : LiveGroup.alerts;
}

/// One stored item of a source for a place, as the core gives it to the app.
class LiveItem {
  const LiveItem({required this.address, required this.label, this.time, this.fields = const {}, this.noneActive = false});

  factory LiveItem.fromJson(Map<String, dynamic> j) => LiveItem(
    address: '${j['address'] ?? ''}',
    label: '${j['label'] ?? ''}',
    time: j['time'] as String?,
    fields: {
      if (j['fields'] is Map)
        for (final e in (j['fields'] as Map).entries)
          if (e.value != null) '${e.key}': '${e.value}',
    },
    noneActive: j['none_active'] == true,
  );

  final String address;
  final String label;

  /// The item's own time (an alert's start, a forecast day), as the core writes it.
  final String? time;
  final Map<String, String> fields;

  /// The "no active alerts" entry a source gives when it has nothing.
  final bool noneActive;

  /// The published definitions' label for how far the item is from the place ("From the place", as WFIGS gives it now).
  static const String fromThePlace = 'From the place';

  /// Whether [label] is the item's distance: "From the place", or the older "Distance" and "Distance to fire edge".
  static bool isDistance(String label) => label == fromThePlace || label.toLowerCase().startsWith('distance');

  /// How far the item is from the place, when the source gives it ("From the place" first, then a "Distance" field).
  String? get distance => fields[fromThePlace] ?? [for (final e in fields.entries) if (isDistance(e.key)) e.value].firstOrNull;

  /// A short line under the label: the first two fields that are not the distance.
  String get summary => [
    for (final e in fields.entries)
      if (!isDistance(e.key)) '${e.key} ${e.value}',
  ].take(2).join(' · ');
}

/// What one source holds for one place.
class SourceView {
  const SourceView({
    required this.source,
    required this.place,
    this.items = const [],
    this.age,
    this.fetchedAt,
    this.expired = false,
    this.missing = false,
    this.error,
  });

  final Connector source;
  final WatchPlace place;
  final List<LiveItem> items;

  /// "2 hours old".
  final String? age;
  final String? fetchedAt;
  final bool expired;

  /// Nothing has been downloaded for this place yet.
  final bool missing;

  /// The last download's failure, in words.
  final String? error;

  LiveGroup get group => groupOf(source);

  /// Items that are something happening (not the "none active" entry).
  List<LiveItem> get active => [for (final i in items) if (!i.noneActive) i];
}

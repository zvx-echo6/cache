import '../maps/layers/layer_def.dart';

enum PlaceKind { here, saved, region }

/// A place weather, alerts and fires can be kept for.
class WatchPlace {
  const WatchPlace({required this.id, required this.kind, required this.name, required this.subtitle, this.lat, this.lon, this.key});

  /// What AppSettings stores: `here`, `place:<key>` or `region:<name>`.
  final String id;
  final PlaceKind kind;
  final String name;
  final String subtitle;

  /// Null when the position is not known ("Where I am" before the first fix).
  final double? lat;
  final double? lon;

  /// The key the core stores the data under (see [WeatherState.placeRequest]).
  final String? key;

  bool get located => lat != null && lon != null;
}

/// A downloaded map region and the point its weather is kept for (the middle of its area).
class WatchRegion {
  const WatchRegion({required this.name, required this.lat, required this.lon});

  final String name;
  final double lat;
  final double lon;
}

/// The regions downloaded on the phone: the finished map areas, one per name (the part of the label before " · "), at the middle of
/// all the areas of that name.
List<WatchRegion> regionsFromAreas(Iterable<DownloadedArea> areas) {
  final byName = <String, List<DownloadedArea>>{};
  for (final a in areas) {
    if (a.phase != AreaPhase.done) continue;
    byName.putIfAbsent(a.label.split(' · ').first, () => []).add(a);
  }
  final out = <WatchRegion>[];
  for (final e in byName.entries) {
    if (e.key == 'This region') continue;
    var s = 90.0, n = -90.0, w = 180.0, ea = -180.0;
    for (final a in e.value) {
      if (a.bounds.south < s) s = a.bounds.south;
      if (a.bounds.north > n) n = a.bounds.north;
      if (a.bounds.west < w) w = a.bounds.west;
      if (a.bounds.east > ea) ea = a.bounds.east;
    }
    out.add(WatchRegion(name: e.key, lat: (s + n) / 2, lon: (w + ea) / 2));
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

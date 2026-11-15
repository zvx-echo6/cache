import 'package:cache_search/cache_search.dart' show MapPlace, SavedPlaceRecord;

/// Saved places first: the one rule every place search follows (the phone's Maps search, CarPlay and Android Auto through
/// CarBridge, and Home's Places). The saved places are the core's (cache_user's `places`, which the saved-places notebook is
/// kept in step with: cache_search nbplaces.rs).

/// A name as the place search compares it: lower case, its words split at every character that is not a letter or a digit, as
/// the core's place search splits them (cache_places map.rs `words`).
List<String> searchWords(String s) => [
      for (final w in s.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        if (w.isNotEmpty) w,
    ];

/// How a saved place's [name] matches what was typed: 0 the whole name, 1 the name or one of its words starts with it, 2 the
/// name holds it, null not at all. The characters between words are left out of the comparison too, so a name typed without
/// its apostrophe or spaces still matches.
int? savedMatch(String name, String query) {
  final n = searchWords(name);
  final q = searchWords(query).join();
  if (n.isEmpty || q.isEmpty) return null;
  if (n.join() == q) return 0;
  for (var i = 0; i < n.length; i++) {
    if (n.sublist(i).join().startsWith(q)) return 1;
  }
  return n.join().contains(q) ? 2 : null;
}

/// A saved place as a place to go to.
MapPlace savedAsPlace(SavedPlaceRecord s) => MapPlace(
    id: 'place:${s.lat.toStringAsFixed(6)},${s.lon.toStringAsFixed(6)}',
    type: 'place',
    name: s.name,
    kind: 'Saved place',
    address: s.label ?? '',
    lat: s.lat,
    lon: s.lon,
    matched: 'saved');

/// The saved places that match [query] (whole name, then a start, then the rest, each in the saved places' order), then
/// [found] as it came, less a place that is one of those saved places (the same name at the same spot).
List<MapPlace> savedFirst(String query, Iterable<MapPlace> saved, List<MapPlace> found) {
  final hits = <(int, int, MapPlace)>[];
  var i = 0;
  for (final s in saved) {
    final m = savedMatch(s.name, query);
    if (m != null) hits.add((m, i, s));
    i++;
  }
  if (hits.isEmpty) return found;
  hits.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final mine = [for (final h in hits) h.$3];
  bool same(MapPlace a, MapPlace b) =>
      searchWords(a.name).join() == searchWords(b.name).join() && (a.lat - b.lat).abs() < 1e-4 && (a.lon - b.lon).abs() < 1e-4;
  return [
    ...mine,
    for (final p in found)
      if (!mine.any((s) => same(s, p))) p,
  ];
}

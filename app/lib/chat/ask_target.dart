/// What a tap on something in Ask points at, for the shell to open (the routes are the shell's own: Maps, Notebooks, Weather,
/// Home's search). App-side only: nothing here is ever sent to the model, and it never changes what the core numbers or says.
sealed class AskTarget {
  const AskTarget();
}

/// A place: a citation of `place:`, `town:`, `addr:` or `loc:`, or a named place of a confirm card. Opens Maps with it selected.
/// [lat] and [lon] are given when the app already has them (a card's place); otherwise the shell finds the place from [address].
final class AskPlace extends AskTarget {
  const AskPlace({required this.address, required this.title, this.lat, this.lon});

  final String address;
  final String title;
  final double? lat;
  final double? lon;

  @override
  String toString() => 'AskPlace($address, $title, $lat, $lon)';
}

/// A point of a map layer the person imported (`layer:<layer>/<point>`). Opens Maps with the layer on and the point selected.
final class AskLayerPoint extends AskTarget {
  const AskLayerPoint({required this.address, required this.title});

  final String address;
  final String title;

  @override
  String toString() => 'AskLayerPoint($address)';
}

/// A repeater of an imported list (`repeater:<list>/<item>`). Opens Maps on it with its card.
final class AskRepeaterPoint extends AskTarget {
  const AskRepeaterPoint({required this.address});

  final String address;

  @override
  String toString() => 'AskRepeaterPoint($address)';
}

/// A Notebooks entry (`repeater:<entry id>`). Opens the entry.
final class AskNotebookEntry extends AskTarget {
  const AskNotebookEntry({required this.entryId});

  final String entryId;

  @override
  String toString() => 'AskNotebookEntry($entryId)';
}

/// A whole notebook (a confirm card's notebook, or the one an entry was added to).
final class AskNotebook extends AskTarget {
  const AskNotebook({required this.notebookId});

  final String notebookId;

  @override
  String toString() => 'AskNotebook($notebookId)';
}

/// Live data (`live:<source>/<place>/<item>`). Opens the Weather screen on that place and item.
final class AskLive extends AskTarget {
  const AskLive({required this.address});

  final String address;

  @override
  String toString() => 'AskLive($address)';
}

/// Home's search with [query] typed in.
final class AskHomeSearch extends AskTarget {
  const AskHomeSearch({required this.query});

  final String query;

  @override
  String toString() => 'AskHomeSearch($query)';
}

/// Maps' search with [query] typed in (a kind of place).
final class AskMapSearch extends AskTarget {
  const AskMapSearch({required this.query});

  final String query;

  @override
  String toString() => 'AskMapSearch($query)';
}

/// Where the address of a citation points, by the kind of address the core gave it: null when the address is one the readers
/// and players open (a ZIM page, a library passage, a video moment), or one that points at nothing the app can show.
AskTarget? askTargetOfAddress(String address, String title) {
  String rest(String prefix) => address.substring(prefix.length);
  for (final p in const ['place:', 'town:', 'addr:', 'loc:']) {
    if (address.startsWith(p) && rest(p).isNotEmpty) return AskPlace(address: address, title: title);
  }
  if (address.startsWith('layer:') && rest('layer:').contains('/')) return AskLayerPoint(address: address, title: title);
  if (address.startsWith('repeater:') && rest('repeater:').isNotEmpty) {
    final r = rest('repeater:');
    // A repeater of an imported list is `<list>/<item>`; a repeater of a notebook is the notebook entry's own id.
    return r.contains('/') ? AskRepeaterPoint(address: address) : AskNotebookEntry(entryId: r);
  }
  if (address.startsWith('live:') && rest('live:').contains('/')) return AskLive(address: address);
  return null;
}

/// A `live:<source>/<place key>/<item key>` address in its parts, or null.
({String source, String placeKey, String item})? liveParts(String address) {
  if (!address.startsWith('live:')) return null;
  final p = address.substring('live:'.length).split('/');
  if (p.length < 3) return null;
  return (source: p[0], placeKey: p[1], item: p.sublist(2).join('/'));
}

/// A `layer:<layer>/<point>` or `repeater:<list>/<item>` address in its parts, or null.
({String list, int ord})? listItemParts(String address) {
  final i = address.indexOf(':');
  if (i < 0) return null;
  final r = address.substring(i + 1);
  final s = r.lastIndexOf('/');
  if (s <= 0) return null;
  final ord = int.tryParse(r.substring(s + 1));
  return ord == null ? null : (list: r.substring(0, s), ord: ord);
}

/// A place a card's field carries (`{lat, lon, name?, label?}`), as a target; null when it has no position. [name] is what the card
/// calls it, else the field's own name or label.
AskPlace? askPlaceOf(Object? v, {String? name}) {
  if (v is! Map || v['lat'] is! num || v['lon'] is! num) return null;
  final lat = (v['lat'] as num).toDouble(), lon = (v['lon'] as num).toDouble();
  final own = v['name'] is String && (v['name'] as String).trim().isNotEmpty ? v['name'] as String : (v['label'] is String ? v['label'] as String : '');
  final title = name != null && name.trim().isNotEmpty ? name : own;
  return AskPlace(address: 'loc:${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}', title: title, lat: lat, lon: lon);
}

import 'dart:convert';
import 'dart:math' as math;

import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter/foundation.dart';

/// The core's user-layer calls (cs_userlayer*): `import`, `list`, `get`, `set_visible`, `delete`, `export`.
typedef UserLayerCall = Future<Map<String, dynamic>> Function(String call, [String? arg]);

/// One repeater list or map layer of the user's map data, as cs_userlayers_list gives it.
class UserLayer {
  const UserLayer({required this.id, required this.kind, required this.name, required this.visible, this.notebookId, this.count = 0});

  final String id;

  /// `layer` or `repeaters`.
  final String kind;
  final String name;
  final bool visible;

  /// The Places notebook a layer belongs to (its places are the notebook's entries; the map draws them as notebook pins).
  final String? notebookId;

  /// Repeaters (a list) or points (a layer).
  final int count;

  bool get isRepeaters => kind == 'repeaters';

  static UserLayer fromJson(Map j) => UserLayer(
        id: '${j['id']}',
        kind: '${j['kind']}',
        name: '${j['name'] ?? ''}',
        visible: j['visible'] != false,
        notebookId: j['notebook_id'] as String?,
        count: ((j['repeaters'] ?? j['points']) as num?)?.toInt() ?? 0,
      );
}

/// One repeater of an imported list, as the core's `get` gives it (app only: the model reads repeaters through nearby, S12, which
/// this does not touch). What a repeater card and a list notebook's row show.
class Repeater {
  const Repeater({
    required this.listId,
    required this.listName,
    required this.item,
    required this.address,
    required this.name,
    this.town,
    this.lat,
    this.lon,
    this.frequency,
    this.offset,
    this.tone,
    this.mode,
    this.onAir,
    this.detailsLink,
  });

  final String listId;
  final String listName;

  /// The repeater's number in its list, and its address (`repeater:<list>/<item>`).
  final int item;
  final String address;

  /// The callsign.
  final String name;
  final String? town;
  final double? lat;
  final double? lon;

  /// "146.940 MHz", "-0.600 MHz", "100.0 Hz" and so on, in the core's words.
  final String? frequency;
  final String? offset;
  final String? tone;
  final String? mode;

  /// "yes" or "no", when the list says.
  final String? onAir;

  /// The list's page for the repeater, when it has one.
  final String? detailsLink;

  bool get located => lat != null && lon != null;

  static Repeater fromJson(String listId, String listName, Map j) {
    String? str(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    return Repeater(
      listId: listId,
      listName: listName,
      item: (j['item'] as num?)?.toInt() ?? 0,
      address: str('address') ?? 'repeater:$listId/${j['item']}',
      name: '${j['name'] ?? ''}',
      town: str('town'),
      lat: (j['lat'] as num?)?.toDouble(),
      lon: (j['lon'] as num?)?.toDouble(),
      frequency: str('frequency'),
      offset: str('offset'),
      tone: str('tone'),
      mode: str('mode'),
      onAir: str('on_air'),
      detailsLink: str('details_link'),
    );
  }
}

/// An imported repeater list as a notebook source: what the Notebooks shelf lists as `Repeaters: <name>` and the list notebook
/// shows as rows (frequency, offset, tone, mode, town, distance). The shelf's screen drops in later; this is its data.
class RepeaterNotebookSource {
  const RepeaterNotebookSource({required this.list, required this.rows});

  final UserLayer list;

  /// The list's repeaters in its own order.
  final List<Repeater> rows;

  /// The shelf's name for it: `Repeaters: <list name>`.
  String get title => 'Repeaters: ${list.name}';

  /// The rows nearest [lat], [lon] first (repeaters with no position last, in list order), with each one's distance in metres.
  List<({Repeater repeater, double? metres})> nearest(double lat, double lon) {
    final out = [for (final r in rows) (repeater: r, metres: r.located ? metresBetween(lat, lon, r.lat!, r.lon!) : null)];
    out.sort((a, b) => (a.metres ?? double.infinity).compareTo(b.metres ?? double.infinity));
    return out;
  }

  /// The great-circle distance between two points, in metres.
  static double metresBetween(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a.toDouble()));
  }
}

/// The user's repeater lists and the lines and areas of files imported into Places notebooks: listed under My layers and
/// drawn on the map. Places themselves are notebook entries (NotebookState).
class UserLayersState extends ChangeNotifier {
  UserLayersState(this._call);

  final UserLayerCall _call;
  List<UserLayer> _all = const [];
  int _revision = 0;

  /// Goes up with every change (the map draws again).
  int get revision => _revision;

  List<UserLayer> get repeaterLists => [for (final l in _all) if (l.isRepeaters) l];

  /// The repeaters the map drew last, by list id and item number (a tap on the map finds its repeater here).
  final Map<(String, int), Repeater> _drawn = {};

  /// The repeater the map's tap picked, for its card (null: none). The card's screen listens to this.
  final ValueNotifier<Repeater?> selectedRepeater = ValueNotifier(null);

  /// The repeater [listId]/[item] the map drew, or null.
  Repeater? repeaterAt(String listId, int item) => _drawn[(listId, item)];

  /// A tap on a repeater on the map: selects it so its card can open. Unknown ones are ignored.
  Repeater? selectRepeater(String listId, int item) {
    final r = repeaterAt(listId, item);
    if (r != null) selectedRepeater.value = r;
    return r;
  }

  void clearRepeater() => selectedRepeater.value = null;

  /// A repeater chosen outside the map (a row of its list notebook): the map opens on it with its card. [focusPending] tells the map
  /// to bring it into view once.
  void showRepeater(Repeater r) {
    focusPending = true;
    selectedRepeater.value = r;
  }

  bool focusPending = false;

  /// The repeaters of list [listId], in its own order (null when it cannot be read).
  Future<RepeaterNotebookSource?> repeaterSource(String listId) async {
    final l = repeaterLists.where((x) => x.id == listId).firstOrNull;
    if (l == null) return null;
    final g = await _call('get', l.id);
    return RepeaterNotebookSource(list: l, rows: [for (final r in (g['repeaters'] as List? ?? const [])) Repeater.fromJson(l.id, l.name, r as Map)]);
  }

  /// Each imported repeater list as a notebook source (hidden lists too: the shelf lists every list).
  Future<List<RepeaterNotebookSource>> repeaterNotebookSources() async {
    final out = <RepeaterNotebookSource>[];
    for (final l in repeaterLists) {
      try {
        final g = await _call('get', l.id);
        out.add(RepeaterNotebookSource(list: l, rows: [for (final r in (g['repeaters'] as List? ?? const [])) Repeater.fromJson(l.id, l.name, r as Map)]));
      } catch (_) {}
    }
    return out;
  }

  Future<void> reload() async {
    try {
      final r = await _call('list');
      _all = [
        for (final l in (r['layers'] as List? ?? const [])) UserLayer.fromJson(l as Map),
        for (final l in (r['repeater_lists'] as List? ?? const [])) UserLayer.fromJson(l as Map),
      ];
      _revision++;
      notifyListeners();
    } on CacheSearchException catch (e) {
      debugPrint('cache user layers: ${e.message}');
    } catch (e) {
      debugPrint('cache user layers: $e');
    }
  }

  /// A RepeaterBook-style KML (or KMZ) and/or a CHIRP CSV, merged into one repeater list. Returns the list as the core
  /// summarises it (`repeaters`, `with_position`, `skipped`...).
  Future<Map<String, dynamic>> importRepeaters(List<String> paths, {String? name}) async {
    final r = await _call('import', jsonEncode({'kind': 'repeaters', 'paths': paths, 'name': ?name}));
    await reload();
    return r;
  }

  Future<void> setVisible(UserLayer l, bool on) async {
    await _call('set_visible', jsonEncode({'id': l.id, 'visible': on}));
    await reload();
  }

  Future<void> delete(UserLayer l) async {
    await _call('delete', l.id);
    await reload();
  }

  /// What the map draws (kUserSource): the repeaters of the lists that are shown, and the lines and areas of the Places
  /// notebooks' layers that are shown.
  Future<Map<String, dynamic>> mapGeoJson() async {
    final features = <Object>[];
    _drawn.clear();
    for (final l in _all) {
      if (!l.visible) continue;
      try {
        final g = await _call('get', l.id);
        if (l.isRepeaters) {
          for (final r in (g['repeaters'] as List? ?? const [])) {
            final m = r as Map;
            if (m['lat'] is! num || m['lon'] is! num) continue;
            final rep = Repeater.fromJson(l.id, l.name, m);
            _drawn[(l.id, rep.item)] = rep;
            features.add({
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': [m['lon'], m['lat']]},
              'properties': {'list': l.id, 'item': rep.item, 'name': m['name'], 'frequency': m['frequency']},
            });
          }
        } else {
          for (final f in (g['features'] as List? ?? const [])) {
            final m = f as Map;
            if ((m['geometry'] as Map?)?['type'] == 'Point') continue;
            features.add({'type': 'Feature', 'geometry': m['geometry'], 'properties': {'layer': l.id, 'name': (m['properties'] as Map?)?['name']}});
          }
        }
      } catch (_) {}
    }
    return {'type': 'FeatureCollection', 'features': features};
  }
}

/// The repeater a map feature's properties name (the `list` and `item` [UserLayersState.mapGeoJson] gave it), or null.
(String, int)? repeaterRef(Object? properties) {
  if (properties is! Map) return null;
  final list = properties['list'];
  final item = properties['item'];
  if (list is! String || item is! num) return null;
  return (list, item.toInt());
}

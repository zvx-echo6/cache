import 'dart:convert';

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
    for (final l in _all) {
      if (!l.visible) continue;
      try {
        final g = await _call('get', l.id);
        if (l.isRepeaters) {
          for (final r in (g['repeaters'] as List? ?? const [])) {
            final m = r as Map;
            if (m['lat'] is! num || m['lon'] is! num) continue;
            features.add({
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': [m['lon'], m['lat']]},
              'properties': {'list': l.id, 'name': m['name'], 'frequency': m['frequency']},
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

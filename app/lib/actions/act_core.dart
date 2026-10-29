/// What the app needs from the core's `act` tool, behind a seam until the core's hook is in the FFI: the core renders the tool
/// description from the definitions, checks every call and asks the app to run read and open actions; a change action runs on the
/// confirm card's tap with the machine values cs_act_resolve gave when the card was shown.
abstract class ActCore {
  /// Gives the core the installed definitions and the way to run an action. [run] returns the contract's tool result.
  Future<void> install(List<Map<String, dynamic>> definitions, Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> fields) run);

  /// cs_act_resolve: the same checks and resolution as the `act` call. `{"ok":true,"action":...,"fields":{...}}` with each `place`
  /// field as `{"lat","lon","name"?,"label"?}`, or `{"ok":false,"error":{"type","detail","field"?}}`.
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields);
}

/// Stands in until the core has `act`: nothing is installed, so the model is never offered the tool, and only `lat,lon` places
/// resolve. Tests use it too.
class ActCoreStandIn implements ActCore {
  const ActCoreStandIn({this.placeFields = const {}});

  /// Per action, the fields of type `place`.
  final Map<String, Set<String>> placeFields;

  @override
  Future<void> install(List<Map<String, dynamic>> definitions, Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) run) async {}

  @override
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields) async {
    final out = <String, dynamic>{};
    for (final e in fields.entries) {
      if (!(placeFields[action]?.contains(e.key) ?? false)) {
        out[e.key] = e.value;
        continue;
      }
      final p = _latLon(e.value);
      if (p == null) {
        final query = e.value is String ? e.value as String : '${e.value}';
        return {
          'ok': false,
          'error': {'type': 'place_not_found', 'detail': 'No place found for "$query".', 'field': e.key, 'query': query},
        };
      }
      out[e.key] = p;
    }
    return {'ok': true, 'action': action, 'fields': out};
  }

  static Map<String, dynamic>? _latLon(dynamic v) {
    if (v is Map && v['lat'] is num && v['lon'] is num) return v.cast<String, dynamic>();
    final parts = v is String ? v.split(',') : const <String>[];
    final lat = parts.length == 2 ? double.tryParse(parts[0].trim()) : null;
    final lon = parts.length == 2 ? double.tryParse(parts[1].trim()) : null;
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
    return {'lat': lat, 'lon': lon};
  }
}

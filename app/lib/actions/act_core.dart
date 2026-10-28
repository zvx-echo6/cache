import 'action_registry.dart';

/// What the app needs from the core's `act` tool, behind a seam until the core's hook is in the FFI: the core renders the tool
/// description from the definitions, checks every call and asks the app to run read and open actions; change actions run on the
/// confirm card's tap with fields the core resolves the same way as for the card.
abstract class ActCore {
  /// Gives the core the installed definitions and the way to run an action. [run] returns the contract's tool result.
  Future<void> install(List<Map<String, dynamic>> definitions, Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> fields) run);

  /// The fields of a change call resolved as for its confirm card (a `place` becomes `{"lat","lon","name"?,"label"?}`). Throws
  /// [ActionFailure] when they no longer resolve.
  Future<Map<String, dynamic>> resolve(String action, Map<String, dynamic> fields);
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
  Future<Map<String, dynamic>> resolve(String action, Map<String, dynamic> fields) async => {
        for (final e in fields.entries) e.key: (placeFields[action]?.contains(e.key) ?? false) ? _latLon(e.key, e.value) : e.value,
      };

  static Map<String, dynamic> _latLon(String field, dynamic v) {
    if (v is Map && v['lat'] is num && v['lon'] is num) return v.cast<String, dynamic>();
    final parts = v is String ? v.split(',') : const <String>[];
    final lat = parts.length == 2 ? double.tryParse(parts[0].trim()) : null;
    final lon = parts.length == 2 ? double.tryParse(parts[1].trim()) : null;
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      throw ActionFailure('place_not_found', 'The place in $field could not be found.');
    }
    return {'lat': lat, 'lon': lon};
  }
}

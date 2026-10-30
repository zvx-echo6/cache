import 'package:cache/actions/act_core.dart';
import 'package:cache/chat/tool.dart';

/// Without the core: nothing is installed, so the model is never offered the tool, and only `lat,lon` places resolve. The tests' stand-in for the core's act tool (the app always has the core's, CoreActCore).
class ActCoreStandIn implements ActCore {
  const ActCoreStandIn({this.placeFields = const {}});

  /// Per action, the fields of type `place`.
  final Map<String, Set<String>> placeFields;

  @override
  Future<bool> install(List<Map<String, dynamic>> definitions) async => false;

  @override
  Future<void> setModulesOff(List<String> modules) async {}

  @override
  Future<String> outcome(ResultNumbering? numbering, Map<String, dynamic> outcome) async => hostEventContent(outcome);

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

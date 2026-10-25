import 'dart:convert';

/// An error from the search core: [code] is one of the core's stable codes (bad_json, not_found,
/// index_missing, index_stale, busy, unsupported, io, cancelled, no_space, damaged, internal).
class CacheSearchException implements Exception {
  const CacheSearchException(this.code, this.message);

  /// Reads the `{"code","message"}` JSON of cs_last_error (or of a job error). Anything else becomes an
  /// "internal" error that keeps the text.
  factory CacheSearchException.fromJson(String? json) {
    if (json == null) return const CacheSearchException('internal', 'The search core failed without a reason');
    try {
      final j = jsonDecode(json);
      if (j is Map && j['code'] is String) {
        return CacheSearchException(j['code'] as String, (j['message'] ?? '').toString());
      }
    } catch (_) {}
    return CacheSearchException('internal', json);
  }

  final String code;
  final String message;

  @override
  String toString() => message.isEmpty ? code : message;
}

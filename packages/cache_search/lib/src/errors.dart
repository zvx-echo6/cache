import 'dart:convert';

/// An error from the search core: [code] is one of the core's stable codes (bad_json, not_found,
/// index_missing, index_stale, busy, unsupported, io, cancelled, no_space, damaged, not_configured, fetch_failed,
/// quota, bad_response, auth_failed, otp_required, internal).
class CacheSearchException implements Exception {
  const CacheSearchException(this.code, this.message, {this.needed, this.available});

  /// Reads the `{"code","message"}` JSON of cs_last_error (or of a job error). Anything else becomes an
  /// "internal" error that keeps the text.
  factory CacheSearchException.fromJson(String? json) {
    if (json == null) return const CacheSearchException('internal', 'The search core failed without a reason');
    try {
      final j = jsonDecode(json);
      if (j is Map && j['code'] is String) {
        return CacheSearchException(j['code'] as String, (j['message'] ?? '').toString(),
            needed: (j['needed'] as num?)?.toInt(), available: (j['available'] as num?)?.toInt());
      }
    } catch (_) {}
    return CacheSearchException('internal', json);
  }

  final String code;
  final String message;

  /// For `no_space`: the bytes the work needs and those free, when the core says them.
  final int? needed;
  final int? available;

  @override
  String toString() => message.isEmpty ? code : message;
}

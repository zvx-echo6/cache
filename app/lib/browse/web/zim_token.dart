import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The token could not be had (the device did not answer, or the session is over).
class ZimTokenException implements Exception {
  const ZimTokenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The token the browser's reader puts in the address of every ZIM page (`/zim/<token>/<zim id>/<path>`). The pages are other
/// people's content shown in a sandboxed frame with no cookies, so the token is what lets the server know the page is wanted by
/// the signed-in person; it opens nothing but ZIM pages. It lasts 12 hours, belongs to this sign-in, and is gone when the person
/// signs out. One token is shared by every reader until shortly before it ends.
class ZimTokens {
  ZimTokens({http.Client? client, DateTime Function()? clock, this.endpoint = '/api/zim/token'})
      // ignore: prefer_initializing_formals
      : _client = client,
        _clock = clock ?? DateTime.now;

  /// The one the app uses.
  static final ZimTokens shared = ZimTokens();

  final String endpoint;
  http.Client? _client;
  final DateTime Function() _clock;
  String? _token;
  DateTime? _until;
  Future<String>? _asking;

  /// Asked for again this long before the token ends.
  static const Duration margin = Duration(minutes: 10);

  /// A token that is good now; a new one is asked for when none is held or the held one is about to end.
  Future<String> get() {
    final t = _token, until = _until;
    if (t != null && until != null && _clock().isBefore(until)) return Future.value(t);
    return _asking ??= _ask().whenComplete(() => _asking = null);
  }

  /// Forget the held token (the server said it is not good any more).
  void forget() {
    _token = null;
    _until = null;
  }

  Future<String> _ask() async {
    try {
      final r = await (_client ??= http.Client()).post(Uri.parse(endpoint)).timeout(const Duration(seconds: 30));
      if (r.statusCode == 401) throw const ZimTokenException('Sign in again to read this.');
      if (r.statusCode != 200) throw const ZimTokenException('This device could not be reached.');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final res = j is Map ? j['result'] : null;
      final token = res is Map ? res['token'] : null;
      final ttl = res is Map ? (res['ttl'] as num?)?.toInt() : null;
      if (token is! String || token.isEmpty) throw const ZimTokenException('This device could not be reached.');
      _token = token;
      _until = _clock().add(Duration(seconds: ttl ?? 3600) - margin);
      return token;
    } on ZimTokenException {
      rethrow;
    } catch (_) {
      throw const ZimTokenException('This device could not be reached.');
    }
  }
}

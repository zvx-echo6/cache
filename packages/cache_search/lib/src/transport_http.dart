import 'dart:convert';

import 'package:http/http.dart' as http;

import 'core_transport.dart';
import 'errors.dart';
import 'wire.dart';

/// The browser's transport: each call is one POST of `{"op","args"}` to Cache Server's `/api/core` (same origin, so the
/// session cookie goes along). The answer is `{"ok":true,"result":...}` or `{"ok":false,"error":{"code","message"}}`; an
/// error is raised as the same [CacheSearchException] the phone would get. Byte arrays travel as `{"$bytes": base64}`.
class HttpTransport implements CoreTransport {
  HttpTransport({http.Client? client, Uri? endpoint})
      : _client = client ?? http.Client(),
        _endpoint = endpoint ?? Uri.parse('/api/core');

  /// Called when the server answers 401 (the browser's session ended): the app shows its way back to the sign-in page.
  static void Function()? onUnauthorized;

  final http.Client _client;
  final Uri _endpoint;

  @override
  Future<dynamic> call(String op, Map<String, dynamic> args) async {
    final http.Response res;
    try {
      res = await _client.post(
        _endpoint,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'op': op, 'args': wireEncode(args)}),
      );
    } catch (e) {
      throw CacheSearchException('internal', 'Cache Server could not be reached: $e');
    }
    if (res.statusCode == 401) {
      onUnauthorized?.call();
      throw const CacheSearchException('unauthorized', 'Sign in to Cache Server again');
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw CacheSearchException('internal', 'Cache Server answered ${res.statusCode} without a result');
    }
    if (body is! Map) throw CacheSearchException('internal', 'Cache Server answered ${res.statusCode} without a result');
    if (body['ok'] == true) return wireDecode(body['result']);
    final err = body['error'];
    if (err is Map) {
      throw CacheSearchException((err['code'] ?? 'internal').toString(), (err['message'] ?? '').toString());
    }
    if (err is List && err.length >= 2) throw CacheSearchException(err[0].toString(), err[1].toString());
    throw CacheSearchException('internal', 'Cache Server answered ${res.statusCode} with an error');
  }

  @override
  Future<void> close() async => _client.close();
}

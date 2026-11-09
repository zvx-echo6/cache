import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../browse/web/device_api.dart' show DeviceException, kDeviceCallTimeout;

/// What Bookshelves in a browser asks of Cache Server (`/api/build/bookshelves...`, server/BUILD-API.md "Bookshelves in the browser").
/// The browser has no files and no log of its own: the server reads the person's Bookshelves log, resolves it and writes every change
/// into its own file of it, so the app only reads the view and sends what the person did.
abstract class ShelfServer {
  /// The server's id in the log, a text that changes when the logs or the libraries' books do ([stamp]), and the resolved view
  /// (server/builder/LIBRARY-LOG.md "The Bookshelves view", format 1).
  Future<({String device, String stamp, Map<String, dynamic> view})> view();

  /// Only the stamp: cheap, so a page can ask whether anything changed.
  Future<String> stamp();

  /// The first line of each book's newest pack, without its `samebook` block: library id, then doc id.
  Future<Map<String, Map<String, Map<String, dynamic>>>> facts();

  /// Sends the events a book page writes (a log line's object each). The server shelves a book it built by its own filing, renames
  /// through the book's rename and appends the rest as they came.
  Future<void> events(List<Map<String, dynamic>> events);
}

/// The browser's [ShelfServer]: same origin, so the session goes along.
class HttpShelfServer implements ShelfServer {
  HttpShelfServer({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<dynamic> _call(String method, String path, {Object? body}) async {
    final req = http.Request(method, Uri.parse(path));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(kDeviceCallTimeout)).timeout(kDeviceCallTimeout);
    } catch (_) {
      throw const DeviceException('unreachable', 'This device could not be reached.');
    }
    if (r.statusCode == 401) throw const DeviceException('unauthorized', 'Sign in again.', status: 401);
    Object? j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final e = j is Map ? j['error'] : null;
      if (e is Map) throw DeviceException((e['code'] ?? 'failed').toString(), (e['message'] ?? '').toString(), status: r.statusCode);
      throw DeviceException('failed', 'This device answered ${r.statusCode}.', status: r.statusCode);
    }
    if (j is Map && j['ok'] == true) return j['result'];
    throw const DeviceException('failed', 'This device answered with something unexpected.');
  }

  static Map<String, dynamic> _map(Object? o) => (o as Map).cast<String, dynamic>();

  @override
  Future<({String device, String stamp, Map<String, dynamic> view})> view() async {
    final j = _map(await _call('GET', '/api/build/bookshelves'));
    return (device: '${j['device']}', stamp: '${j['stamp']}', view: _map(j['view']));
  }

  @override
  Future<String> stamp() async => '${_map(await _call('GET', '/api/build/bookshelves/stamp'))['stamp']}';

  @override
  Future<Map<String, Map<String, Map<String, dynamic>>>> facts() async {
    final j = _map(_map(await _call('GET', '/api/build/bookshelves/facts'))['libraries']);
    return {
      for (final lib in j.entries) lib.key: {for (final d in _map(lib.value).entries) d.key: _map(d.value)},
    };
  }

  @override
  Future<void> events(List<Map<String, dynamic>> events) async {
    await _call('POST', '/api/build/bookshelves/events', body: {'events': events});
  }
}

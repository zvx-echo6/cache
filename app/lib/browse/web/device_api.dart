import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why a call to this device failed: [code] is the device's own word for it (`no_space`, `unauthorized`, `host_not_allowed`), [status]
/// the HTTP status (0: no answer at all).
class DeviceException implements Exception {
  const DeviceException(this.code, this.message, {this.status = 0});

  final String code;
  final String message;
  final int status;

  @override
  String toString() => 'DeviceException($code, $status): $message';
}

/// One thing installed on the device: a ZIM file or a library folder.
class DeviceItem {
  const DeviceItem({required this.id, required this.kind, required this.name, required this.title, required this.bytes, required this.path});

  final String id;

  /// `zim` or `library`.
  final String kind;

  /// The file name of a ZIM, the folder name of a library.
  final String name;
  final String title;
  final int bytes;

  /// Where it is, relative to the device's data folder.
  final String path;

  static DeviceItem fromJson(Map<String, dynamic> j) => DeviceItem(
        id: j['id'] as String,
        kind: j['kind'] as String,
        name: j['name'] as String,
        title: (j['title'] ?? j['name']) as String,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        path: (j['path'] ?? '') as String,
      );
}

/// One transfer the device runs for a download link: it goes on with the browser closed.
class DeviceJob {
  const DeviceJob({
    required this.id,
    required this.url,
    required this.kind,
    required this.name,
    required this.bytes,
    required this.total,
    required this.state,
    this.error,
    this.createdAt,
    this.finishedAt,
  });

  final String id;
  final String url;
  final String kind;
  final String name;
  final int bytes;
  final int total;

  /// `queued`, `running`, `done`, `failed` or `cancelled`.
  final String state;
  final String? error;

  /// When the server took the job and when it finished, failed or was cancelled (UTC); null when not known or not yet.
  final DateTime? createdAt;
  final DateTime? finishedAt;

  bool get active => state == 'queued' || state == 'running';
  bool get failed => state == 'failed';
  bool get done => state == 'done';
  double? get fraction => total <= 0 ? null : (bytes / total).clamp(0.0, 1.0);

  static DeviceJob fromJson(Map<String, dynamic> j) => DeviceJob(
        id: j['id'] as String,
        url: (j['url'] ?? '') as String,
        kind: (j['kind'] ?? 'zim') as String,
        name: (j['name'] ?? '') as String,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        state: (j['state'] ?? 'failed') as String,
        error: j['error'] as String?,
        createdAt: DateTime.tryParse((j['created_at'] ?? '') as String),
        finishedAt: DateTime.tryParse((j['finished_at'] ?? '') as String),
      );
}

/// The disk the device keeps its files on; a number that cannot be told is null.
class DeviceSpaceInfo {
  const DeviceSpaceInfo({this.free, this.total});

  final int? free;
  final int? total;
}

/// What the browser can ask of the device about the Library. A class so tests can give their own answers.
abstract class DeviceApi {
  Future<List<DeviceItem>> items();
  Future<List<DeviceJob>> jobs();
  Future<DeviceSpaceInfo> space();

  /// Asks the device to download [url]. A ZIM is installed by the device; a library package is put in the docs root, ready to add.
  Future<DeviceJob> download({
    required String url,
    required String kind,
    String? name,
    String? sha256,
    Map<String, dynamic>? origin,
    String? iconUrl,
  });

  /// Cancels a waiting or running transfer, or takes a finished one off the list.
  Future<void> cancelJob(String id);
  Future<void> removeItem(String id);

  /// The search core reads the library folders again (after the browser put a library in place).
  Future<void> rescan();

  /// Reads a catalogue address through the device (it only reads the catalogue hosts the app uses).
  Future<List<int>> fetch(Uri url);
}

/// How long a call to the device may take before it counts as not answering. Without a limit one call that never ends would stop the
/// Library from being read again, and its cards would stay as they were.
const Duration kDeviceCallTimeout = Duration(seconds: 30);

/// The browser's [DeviceApi]: Cache Server's `/api/library/...` and `/api/fetch`, same origin, so the session goes along.
class HttpDeviceApi implements DeviceApi {
  HttpDeviceApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<http.Response> _send(String method, String path, {Object? body}) async {
    final uri = Uri.parse(path);
    try {
      switch (method) {
        case 'GET':
          return await _client.get(uri).timeout(kDeviceCallTimeout);
        case 'DELETE':
          return await _client.delete(uri).timeout(kDeviceCallTimeout);
        default:
          return await _client
              .post(uri, headers: const {'content-type': 'application/json'}, body: body == null ? null : jsonEncode(body))
              .timeout(kDeviceCallTimeout);
      }
    } catch (e) {
      throw DeviceException('unreachable', 'This device could not be reached.');
    }
  }

  static DeviceException _error(http.Response r) {
    if (r.statusCode == 401) return const DeviceException('unauthorized', 'Sign in again.', status: 401);
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final e = j is Map ? j['error'] : null;
      if (e is Map) return DeviceException((e['code'] ?? 'failed').toString(), (e['message'] ?? '').toString(), status: r.statusCode);
    } catch (_) {}
    return DeviceException('failed', 'This device answered ${r.statusCode}.', status: r.statusCode);
  }

  Future<dynamic> _result(String method, String path, {Object? body}) async {
    final r = await _send(method, path, body: body);
    if (r.statusCode < 200 || r.statusCode >= 300) throw _error(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map && j['ok'] == true) return j['result'];
    throw const DeviceException('failed', 'This device answered with something unexpected.');
  }

  @override
  Future<List<DeviceItem>> items() async => [for (final j in (await _result('GET', '/api/library/items')) as List) DeviceItem.fromJson((j as Map).cast<String, dynamic>())];

  @override
  Future<List<DeviceJob>> jobs() async => [for (final j in (await _result('GET', '/api/library/jobs')) as List) DeviceJob.fromJson((j as Map).cast<String, dynamic>())];

  @override
  Future<DeviceSpaceInfo> space() async {
    final j = (await _result('GET', '/api/library/space')) as Map;
    return DeviceSpaceInfo(free: (j['free_bytes'] as num?)?.toInt(), total: (j['total_bytes'] as num?)?.toInt());
  }

  @override
  Future<DeviceJob> download({required String url, required String kind, String? name, String? sha256, Map<String, dynamic>? origin, String? iconUrl}) async =>
      DeviceJob.fromJson(((await _result('POST', '/api/library/download', body: {
        'url': url,
        'kind': kind,
        'name': ?name,
        'sha256': ?sha256,
        'origin': ?origin,
        'icon_url': ?iconUrl,
      })) as Map)
          .cast<String, dynamic>());

  @override
  Future<void> cancelJob(String id) async {
    await _result('DELETE', '/api/library/jobs/${Uri.encodeComponent(id)}');
  }

  @override
  Future<void> removeItem(String id) async {
    await _result('DELETE', '/api/library/items/${Uri.encodeComponent(id)}');
  }

  @override
  Future<void> rescan() async {
    await _result('POST', '/api/library/rescan');
  }

  @override
  Future<List<int>> fetch(Uri url) async {
    final r = await _send('GET', '/api/fetch?url=${Uri.encodeComponent(url.toString())}');
    if (r.statusCode != 200) throw _error(r);
    return r.bodyBytes;
  }
}

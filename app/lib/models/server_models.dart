import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../browse/web/device_api.dart' show DeviceException;
import '../browse/web/local_files.dart' show LocalFile, RawUploader, createRawUploader;
import '../platform/memory.dart' show MemoryReading, memoryFromServerBody;
import 'hf_hub.dart';

/// One download the server runs for the browser (`GET /api/models/downloads`, server/src/models.rs).
class ServerDownload {
  const ServerDownload({required this.name, required this.state, this.done = 0, this.total = 0, this.error});

  final String name;

  /// queued, running, verifying, paused, failed or done.
  final String state;
  final int done;
  final int total;
  final String? error;

  bool get active => state == 'queued' || state == 'running' || state == 'verifying';

  static ServerDownload? parse(Object? j) {
    if (j is! Map || j['name'] is! String || j['state'] is! String) return null;
    return ServerDownload(
      name: j['name'] as String,
      state: j['state'] as String,
      done: (j['done'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
      error: j['error'] as String?,
    );
  }
}

/// The server said no, or could not be asked; [message] is for people.
class ServerModelsException implements Exception {
  const ServerModelsException(this.message, {this.status = 0});
  final String message;

  /// The HTTP status the server answered with (401: the session ended); 0 when it did not answer at all.
  final int status;
  @override
  String toString() => message;
}

typedef ServerHttp = Future<({int status, String body})> Function(String method, String path, String? body);

Future<({int status, String body})> _sameOrigin(String method, String path, String? body) async {
  final uri = Uri.parse(path);
  final r = switch (method) {
    'GET' => await http.get(uri),
    'DELETE' => await http.delete(uri),
    _ => await http.post(uri, headers: const {'Content-Type': 'application/json'}, body: body ?? '{}'),
  };
  return (status: r.statusCode, body: utf8.decode(r.bodyBytes));
}

/// The model files on the server, for the browser build: downloads that the server runs (so they go on with no tab open), delete, upload
/// and the host's memory. Same origin: the page's session cookie goes along. Nothing here runs on a phone.
class ServerModels {
  ServerModels({ServerHttp? http, RawUploader Function()? uploader}) : _http = http ?? _sameOrigin, _uploader = uploader ?? createRawUploader;

  final ServerHttp _http;
  final RawUploader Function() _uploader;

  static String _why(int status, String body) {
    try {
      final j = jsonDecode(body);
      final m = j is Map && j['error'] is Map ? (j['error'] as Map)['message'] : null;
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return status == 401 ? 'Sign in again.' : 'The server answered $status.';
  }

  Future<Object?> _result(String method, String path, [String? body]) async {
    final ({int status, String body}) r;
    try {
      r = await _http(method, path, body);
    } catch (e) {
      throw ServerModelsException('The server could not be reached: $e');
    }
    if (r.status != 200) throw ServerModelsException(_why(r.status, r.body), status: r.status);
    try {
      final j = jsonDecode(r.body);
      return j is Map ? j['result'] : null;
    } on FormatException {
      throw const ServerModelsException('The server sent an answer this page cannot read.');
    }
  }

  static String _enc(String name) => Uri.encodeComponent(name);

  /// Every download the server knows (and the search model's own).
  Future<List<ServerDownload>> downloads() async {
    final r = await _result('GET', '/api/models/downloads');
    final list = r is Map ? r['downloads'] : null;
    return [
      if (list is List)
        for (final d in list) ?ServerDownload.parse(d),
    ];
  }

  /// Queues [f] (or continues it). [search]: the server starts the search model after this file when it is missing.
  Future<void> add(HfFile f, {bool search = false}) async {
    final body = <String, Object?>{
      'name': f.fileName,
      'size': f.size,
      if (f.sha256 != null) 'sha256': f.sha256,
      if (search) 'search': true,
      if (f.url != null) 'url': f.url.toString() else ...{'repo': f.repo, 'revision': f.revision, 'path': f.path},
    };
    await _result('POST', '/api/models/downloads', jsonEncode(body));
  }

  Future<void> pause(String name) => _result('POST', '/api/models/downloads/${_enc(name)}/pause');

  /// Stops a download and throws away what it saved.
  Future<void> remove(String name) => _result('DELETE', '/api/models/downloads/${_enc(name)}');

  /// Deletes a model file from the server's models folder.
  Future<void> deleteFile(String name) => _result('DELETE', '/api/models/files/${_enc(name)}');

  /// Has the server download the search model.
  Future<void> startSearchModel() => _result('POST', '/api/models/embedder/download');

  /// Whether the server has the search model.
  Future<bool> searchModelReady() async {
    final r = await _result('GET', '/api/models/embedder');
    return r is Map && r['state'] == 'ready';
  }

  /// The chat models on the server: (file name, size).
  Future<List<({String id, int size})>> chatModels() async {
    final r = await _result('GET', '/api/llm/models?v=1');
    final list = r is Map ? r['models'] : null;
    return [
      if (list is List)
        for (final m in list)
          if (m is Map && m['id'] is String) (id: m['id'] as String, size: (m['size'] as num?)?.toInt() ?? 0),
    ];
  }

  /// The server's memory, for the fit check; null when it cannot say.
  Future<MemoryReading?> memory() async {
    try {
      final r = await _http('GET', '/api/system/memory', null);
      return r.status == 200 ? memoryFromServerBody(r.body) : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends [file] to the server's models folder as [name] (streamed by the browser, never held in memory).
  Future<void> upload(LocalFile file, String name, void Function(int sent, int total) onProgress) async {
    final task = _uploader().post(file, '/api/models/upload?name=${_enc(name)}', onProgress);
    try {
      await task.done;
    } on DeviceException catch (e) {
      throw ServerModelsException(e.message);
    }
  }
}

// The server's embedder as Dart values: `POST /api/embed` and `GET /api/models/embedder` (server/BUILD-API.md). Plain Dart (no
// dart:io, dart:ffi, dart:js_interop or Flutter), so the browser's CacheEmbedder and SearchModel use it and the VM tests import it.
import 'dart:convert';

/// One HTTP call to the server: [body] is the JSON to send (null for a GET); the answer is the status and the body text.
typedef EmbedHttp = Future<({int status, String body})> Function(String method, String path, String? body);

/// The server could not make the vectors. [code] is the server's (`model_missing`: the model is not there and its download has
/// started; `embed_unavailable`: it cannot load), or `bad_reply` / `http_<status>` when the answer is not the server's.
class EmbedRemoteException implements Exception {
  const EmbedRemoteException(this.code, this.message);
  final String code;
  final String message;

  /// The model is not on the server (yet).
  bool get modelMissing => code == 'model_missing';

  @override
  String toString() => 'EmbedRemoteException($code): $message';
}

/// The vectors of [texts] (1 to 64, in order) from `POST /api/embed`. Throws [EmbedRemoteException].
Future<List<List<double>>> embedRemote(EmbedHttp http, List<String> texts) async {
  final r = await http('POST', '/api/embed', jsonEncode({'texts': texts}));
  final j = _json(r.body);
  if (r.status != 200 || j == null || j['ok'] != true) throw _failure(r.status, j);
  final result = j['result'];
  final raw = result is Map ? result['vectors'] : null;
  if (raw is! List || raw.length != texts.length) throw const EmbedRemoteException('bad_reply', 'The server sent no vectors for the text');
  try {
    return [
      for (final v in raw) [for (final x in v as List) (x as num).toDouble()],
    ];
  } catch (_) {
    throw const EmbedRemoteException('bad_reply', 'The server sent vectors in a form that cannot be read');
  }
}

/// What `GET /api/models/embedder` says about the server's search model.
enum ServerEmbedderState { missing, downloading, ready, error }

class ServerEmbedderStatus {
  const ServerEmbedderStatus(this.state, {this.file, this.size, this.bytes, this.total, this.error});

  final ServerEmbedderState state;

  /// The model file's name, which is also the model id a vector carries.
  final String? file;
  final int? size;

  /// While downloading: what has come and the whole size.
  final int? bytes;
  final int? total;

  /// When [state] is error: why the download stopped.
  final String? error;

  bool get ready => state == ServerEmbedderState.ready;

  /// 0..1 while downloading, else null.
  double? get fraction => state == ServerEmbedderState.downloading && (total ?? 0) > 0 ? ((bytes ?? 0) / total!).clamp(0.0, 1.0) : null;

  /// The reply body of the status (and of the download start, which answers the same), or null when it is not a status.
  static ServerEmbedderStatus? parse(String body) {
    final r = _json(body)?['result'];
    if (r is! Map) return null;
    final state = switch (r['state']) {
      'ready' => ServerEmbedderState.ready,
      'downloading' => ServerEmbedderState.downloading,
      'error' => ServerEmbedderState.error,
      'missing' => ServerEmbedderState.missing,
      _ => null,
    };
    if (state == null) return null;
    return ServerEmbedderStatus(
      state,
      file: r['file'] as String?,
      size: (r['size'] as num?)?.toInt(),
      bytes: (r['bytes'] as num?)?.toInt(),
      total: (r['total'] as num?)?.toInt(),
      error: r['error'] as String?,
    );
  }
}

Map<String, dynamic>? _json(String body) {
  try {
    final j = jsonDecode(body);
    return j is Map ? j.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

EmbedRemoteException _failure(int status, Map<String, dynamic>? j) {
  final e = j?['error'];
  if (e is Map && e['code'] is String) return EmbedRemoteException(e['code'] as String, (e['message'] as String?) ?? 'The server could not embed the text');
  return EmbedRemoteException('http_$status', 'The server could not embed the text (HTTP $status)');
}

// Web build: there is no llama.cpp in a browser. The bge-m3 model runs on the Cache server and a query is embedded there:
// `POST /api/embed` (same origin, with the page's cookies; server/BUILD-API.md), the same library code and settings as the phone's
// embedder, so the vector is the one the phone makes. Same public API as embedder_io.dart.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'embed_remote.dart';

class CacheEmbedder {
  /// [modelPath] is the model's file name on the web (the server keeps the file); [threads] and [idleFor] are the phone's: the
  /// server decides for its own model.
  CacheEmbedder({required this.modelPath, this.threads = 4, this.idleFor = const Duration(minutes: 2)});

  final String modelPath;
  final int threads;
  final Duration idleFor;

  /// The server keeps the model: nothing here to hold.
  bool keepLoaded = false;

  /// Timing lines for the log. The browser build embeds on the server, so nothing here calls it; the member exists so
  /// shared code that sets it compiles for the browser too.
  void Function(String line)? onTiming;

  /// The context length cl_embed_load is given.
  static const int nCtx = 512;

  /// The model id a query vector carries: the GGUF's file name.
  String get modelId => modelPath.split(RegExp(r'[\\/]')).last;

  /// The normalised vector of [text], made by the server. Throws [EmbedRemoteException] when it cannot (`model_missing`: the model is
  /// not there yet).
  Future<List<double>> embed(String text) async => (await embedRemote(_fetch, [text])).first;

  /// The server keeps the model: nothing to load here.
  Future<void> warm() async {}

  void free() {}

  Future<void> dispose() async {}
}

Future<({int status, String body})> _fetch(String method, String path, String? body) async {
  final init = web.RequestInit(
    method: method,
    headers: {'Content-Type': 'application/json'}.jsify() as JSObject,
    body: body?.toJS,
    credentials: 'same-origin',
  );
  final r = await web.window.fetch(path.toJS, init).toDart;
  return (status: r.status, body: (await r.text().toDart).toDart);
}

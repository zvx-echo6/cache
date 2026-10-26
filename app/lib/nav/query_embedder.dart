import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:cache_search/cache_search.dart';

/// The model the places pack's meaning search was built with (the decided embedder): bge-m3, Q8_0, 634,553,856 bytes, sha256
/// c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb. It sits next to the chat model, in the app's `models` folder.
const String kQueryEmbedModelFile = 'bge-m3-Q8_0.gguf';

/// Embeds the map search's query on the phone for meaning search. The model loads on first use and goes again after a couple
/// of idle minutes; with no model file the answer is null, and the core searches by keywords and says so.
class PhoneQueryEmbedder {
  PhoneQueryEmbedder({required this.modelsDir, CacheEmbedder Function(String path)? make}) : _make = make ?? ((p) => CacheEmbedder(modelPath: p));

  final Future<Directory> Function() modelsDir;
  final CacheEmbedder Function(String path) _make;
  CacheEmbedder? _embedder;

  Future<MapQueryVector?> call(String text) async {
    var e = _embedder;
    if (e == null) {
      final file = File('${(await modelsDir()).path}/$kQueryEmbedModelFile');
      if (!file.existsSync()) return null;
      e = _embedder = _make(file.path);
    }
    return MapQueryVector(e.modelId, await e.embed(text));
  }

  Future<void> dispose() async => _embedder?.dispose();
}

// Web build: there is no embedding model in a browser. Same public API as embedder_io.dart; embed throws.
class CacheEmbedder {
  CacheEmbedder({required this.modelPath, this.threads = 4, this.idleFor = const Duration(minutes: 2)});

  /// Where the GGUF is.
  final String modelPath;
  final int threads;
  final Duration idleFor;

  /// The context length cl_embed_load is given.
  static const int nCtx = 512;

  /// The model id a query vector carries: the GGUF's file name.
  String get modelId => modelPath.split(RegExp(r'[\\/]')).last;

  /// The normalised vector of [text]. Throws on the web.
  Future<List<double>> embed(String text) async => throw UnsupportedError('web: CacheEmbedder.embed');

  void free() {}

  Future<void> dispose() async {}
}

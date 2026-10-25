import 'package:cache_llama/cache_llama.dart';

import 'model_backend.dart';

/// Runs the model on this phone through the native layer.
class LocalLlamaBackend implements ModelBackend {
  LocalLlamaBackend(this.session);

  final LlamaSession session;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) => session.generate(request);

  @override
  void stop() => session.stop();
}

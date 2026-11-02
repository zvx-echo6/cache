import 'package:cache_llama/cache_llama.dart';

import 'model_backend.dart';

/// Runs the model on this phone through the native layer. [extras] are the loaded model's own settings for a request (from the
/// recommended list); what the request itself says wins, and with none the request goes as it is.
class LocalLlamaBackend implements ModelBackend {
  LocalLlamaBackend(this.session, {this.extras});

  final LlamaSession session;
  final Map<String, dynamic> Function()? extras;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    final e = extras?.call();
    return session.generate(e == null || e.isEmpty ? request : {...e, ...request});
  }

  @override
  void stop() => session.stop();
}

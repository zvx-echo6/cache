import 'package:cache_llama/cache_llama.dart';

/// Where answers come from. A remote backend can be added later; the tool loop only sees this.
abstract class ModelBackend {
  /// [request] is OpenAI style: {messages: [...], tools: [...]}. Emits the assistant message parsed so
  /// far as it streams, then a final message (isFinal = true).
  Stream<PartialMessage> generate(Map<String, dynamic> request);

  /// Ends the running generation early (the final message still arrives).
  void stop();
}

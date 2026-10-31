// Web build: there is no llama.cpp in a browser. Same public API as llama_session_io.dart; every call throws.
import 'partial_message.dart';

class LlamaSession {
  LlamaSession();

  bool get isLoaded => false;

  /// Loads the model. Throws on the web.
  Future<ModelInfo> load(String path, {int nCtx = 8192}) async => throw UnsupportedError('web: LlamaSession.load');

  /// Runs one generation. Throws on the web.
  Stream<PartialMessage> generate(Map<String, dynamic> request) => throw UnsupportedError('web: LlamaSession.generate');

  /// Ends the running generation early. Nothing runs on the web, so there is nothing to stop.
  void stop() {}

  Future<void> unload() async {}

  Future<void> dispose() async {}
}

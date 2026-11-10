import 'partial_message.dart';

/// Web build: there is no local template layer (the model runs on the server).
class RenderedPrompt {
  const RenderedPrompt({required this.prompt, required this.promptTokens, required this.stopOnToolOpen, this.split = 0});

  final String prompt;
  final int promptTokens;
  final bool stopOnToolOpen;
  final int split;
}

class ChatTemplate {
  ChatTemplate._();

  static ChatTemplate load(String ggufPath, {String? templateOverride, Object? lib}) =>
      throw UnsupportedError('No local chat template on the web');

  RenderedPrompt render(Map<String, dynamic> request) => throw UnsupportedError('No local chat template on the web');
  PartialMessage feed(String chunk) => throw UnsupportedError('No local chat template on the web');
  PartialMessage finish([String rest = '']) => throw UnsupportedError('No local chat template on the web');
  int count(String text) => throw UnsupportedError('No local chat template on the web');
  void dispose() {}
}

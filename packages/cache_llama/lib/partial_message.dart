import 'dart:convert';

/// A tool call requested by the model.
class ToolCall {
  const ToolCall({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;

  /// JSON text, as in the OpenAI API.
  final String arguments;

  Map<String, dynamic> get argumentsMap {
    try {
      final v = jsonDecode(arguments);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    return <String, dynamic>{};
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

/// The assistant message parsed so far (or finally). [content] is only the visible answer text:
/// thinking goes to [reasoning], tool-call syntax to [toolCalls].
class PartialMessage {
  const PartialMessage({
    this.content = '',
    this.reasoning = '',
    this.toolCalls = const [],
    this.isFinal = false,
    this.parseError,
    this.promptTokens = 0,
    this.generatedTokens = 0,
    this.reusedTokens,
    this.startMs,
    this.firstTokenMs,
    this.totalMs,
    this.prefixNote,
  });

  factory PartialMessage.fromJson(Map<String, dynamic> j,
      {bool isFinal = false, int promptTokens = 0, int generatedTokens = 0,
      int? reusedTokens, int? startMs, int? firstTokenMs, int? totalMs, String? prefixNote}) {
    final calls = <ToolCall>[];
    for (final c in (j['tool_calls'] as List? ?? const [])) {
      final f = (c as Map)['function'] as Map;
      calls.add(ToolCall(
        id: (c['id'] ?? '') as String,
        name: (f['name'] ?? '') as String,
        arguments: (f['arguments'] ?? '{}') as String,
      ));
    }
    return PartialMessage(
      content: (j['content'] ?? '') as String,
      reasoning: (j['reasoning_content'] ?? '') as String,
      toolCalls: calls,
      isFinal: isFinal,
      parseError: j['parse_error'] as String?,
      promptTokens: promptTokens,
      generatedTokens: generatedTokens,
      reusedTokens: reusedTokens,
      startMs: startMs,
      firstTokenMs: firstTokenMs,
      totalMs: totalMs,
      prefixNote: prefixNote,
    );
  }

  final String content;
  final String reasoning;
  final List<ToolCall> toolCalls;
  final bool isFinal;
  final String? parseError;
  final int promptTokens;
  final int generatedTokens;

  /// Prompt tokens already in the native KV cache; null for an older or remote backend.
  final int? reusedTokens;

  /// Native preparation, tokenization and prompt evaluation together.
  final int? startMs;

  /// Request start through its first generated token, including special tokens.
  final int? firstTokenMs;

  /// Native request start through its final parse.
  final int? totalMs;

  /// What the native layer did with the saved prompt prefix in this request ("Prompt prefix restored (N tokens, T ms)", "...
  /// saved ..."), for the app log; null when nothing.
  final String? prefixNote;

  int? get evaluatedPromptTokens => reusedTokens == null ? null : promptTokens - reusedTokens!;

  bool get hasToolCalls => toolCalls.isNotEmpty;

  /// The assistant message as an OpenAI style map (for the next request).
  Map<String, dynamic> toMessage() => {
        'role': 'assistant',
        'content': content,
        if (toolCalls.isNotEmpty) 'tool_calls': [for (final c in toolCalls) c.toJson()],
      };
}

/// What cl_info reports about the loaded model.
class ModelInfo {
  const ModelInfo({
    required this.description,
    required this.nCtx,
    required this.chatFormat,
    required this.supportsTools,
    this.weights,
    this.weightsReason,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        description: (j['description'] ?? '') as String,
        nCtx: (j['n_ctx'] ?? 0) as int,
        chatFormat: (j['chat_format'] ?? '') as String,
        supportsTools: (j['supports_tools'] ?? false) as bool,
        weights: j['weights'] as String?,
        weightsReason: j['weights_reason'] as String?,
      );

  final String description;
  final int nCtx;
  final String chatFormat;
  final bool supportsTools;

  /// How the weights were loaded: "mmap" (the Android default), "repacked" (Android, measurement opt-in only) or "default"
  /// (null from an older library or a remote model), and why.
  final String? weights;
  final String? weightsReason;
}

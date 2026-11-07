// The /api/llm v1 stream (server/docs/llm-protocol.md) as Dart values. Plain Dart (no dart:io, dart:ffi, dart:js_interop or Flutter),
// so the browser's LlamaSession uses it and the VM tests import it.
import 'dart:async';
import 'dart:convert';

import 'partial_message.dart';

/// One event of a `generate` stream.
sealed class LlmRemoteEvent {
  const LlmRemoteEvent();
}

/// The generation waits for another; [position] is how many are ahead (1 is next).
class LlmQueued extends LlmRemoteEvent {
  const LlmQueued(this.position);
  final int position;
}

/// The generation has its turn and is running: [id] is what `POST /api/llm/stop` takes to stop this generation and no other.
class LlmStarted extends LlmRemoteEvent {
  const LlmStarted(this.id);
  final String id;
}

/// The message so far: what the phone's worker sends after each token that produced text.
class LlmPartial extends LlmRemoteEvent {
  const LlmPartial(this.message);
  final PartialMessage message;
}

/// The end: the final message with the token counts (isFinal is true).
class LlmDone extends LlmRemoteEvent {
  const LlmDone(this.message);
  final PartialMessage message;
}

/// Something failed; the stream ends after it. [message] is the server's reason.
class LlmError extends LlmRemoteEvent {
  const LlmError(this.code, this.message);
  final String code;
  final String message;
}

/// Parses one NDJSON line. Null for a blank line or an event type this version does not know (ignored, as a newer server may add some).
/// A line that is not JSON throws a [FormatException].
LlmRemoteEvent? parseLlmEventLine(String line) {
  if (line.trim().isEmpty) return null;
  final j = jsonDecode(line);
  if (j is! Map<String, dynamic>) throw FormatException('Not an event: $line');
  switch (j['type']) {
    case 'queued':
      return LlmQueued((j['position'] as num?)?.toInt() ?? 0);
    case 'started':
      return LlmStarted((j['id'] ?? '') as String);
    case 'partial':
      return LlmPartial(PartialMessage.fromJson(j));
    case 'done':
      return LlmDone(PartialMessage.fromJson(j,
          isFinal: true,
          promptTokens: (j['prompt_tokens'] as num?)?.toInt() ?? 0,
          generatedTokens: (j['generated_tokens'] as num?)?.toInt() ?? 0));
    case 'error':
      return LlmError((j['code'] ?? '') as String, (j['message'] ?? '') as String);
  }
  return null;
}

/// Splits a byte stream (chunks cut anywhere, also inside a UTF-8 character) into lines.
Stream<String> llmLines(Stream<List<int>> bytes) => bytes.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());

/// The events of a `generate` response body, in order. Unknown lines are skipped.
Stream<LlmRemoteEvent> parseLlmEvents(Stream<List<int>> bytes) async* {
  await for (final line in llmLines(bytes)) {
    final e = parseLlmEventLine(line);
    if (e != null) yield e;
  }
}

/// The reason in a server error body (`{"ok":false,"error":{"code","message"}}`), or [fallback] when the body is not that.
String llmErrorMessage(String body, String fallback) {
  try {
    final j = jsonDecode(body);
    if (j is Map && j['error'] is Map) {
      final m = (j['error'] as Map)['message'];
      if (m is String && m.isNotEmpty) return m;
    }
  } catch (_) {}
  return fallback;
}

/// What a client does to stop its generation.
enum LlmStopAction {
  /// Not started yet (still waiting in the queue, or being prepared): close the request. The stream then ends with no message.
  abort,

  /// Started: ask the server to stop this generation by its id and go on reading; the final message still comes, as on the phone.
  requestStop,
}

/// What one generation stream has shown so far, to decide what [stop] does.
class LlmRunState {
  String? id;

  void see(LlmRemoteEvent e) {
    if (e is LlmStarted) id = e.id;
  }

  LlmStopAction get stopAction => id == null ? LlmStopAction.abort : LlmStopAction.requestStop;
}

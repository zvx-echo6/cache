// The browser's unload, apart from the browser: what llama_session_web.dart does for `unload()`, with the request sent by [post] so a
// test can stand in for fetch. See server/docs/llm-protocol.md (`POST /api/llm/unload`).
import 'dart:convert';

import 'llm_remote_events.dart' show llmErrorMessage;

/// An answer of the server: its HTTP status and body text.
class LlmHttpReply {
  const LlmHttpReply(this.status, this.body);
  final int status;
  final String body;
  bool get ok => status >= 200 && status < 300;
}

/// Sends one POST with a JSON body to [path] (same origin, with the page's cookies).
typedef LlmPost = Future<LlmHttpReply> Function(String path, Map<String, dynamic> body);

/// Asks the server to free the model it has loaded (shared by every browser). Nothing loaded is fine. Throws a [StateError] with the
/// reason when the server refuses or cannot be reached.
Future<void> unloadOnServer(LlmPost post) async {
  final LlmHttpReply r;
  try {
    r = await post('/api/llm/unload', {'v': 1});
  } catch (_) {
    throw StateError('The server could not be reached to unload the model');
  }
  if (!r.ok) throw StateError(llmErrorMessage(r.body, 'The server could not unload the model (HTTP ${r.status})'));
  try {
    final j = jsonDecode(r.body);
    if (j is Map && j['ok'] == true) return;
  } catch (_) {}
  throw StateError('The server sent no answer to the unload');
}

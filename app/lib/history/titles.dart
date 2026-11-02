import '../chat/model_backend.dart';
import '../chat/tool_loop.dart';

/// The one instruction behind generated titles. It is sent as the last user message of the conversation,
/// so the model reads what was asked and answered and writes a title in the same language.
const String kTitlePrompt =
    'Write a short title for this conversation, at most six words, in the language the user wrote in. '
    'Reply with the title only: no quotes, no markdown, no full stop.';

/// Whether the title request carries the conversation's tool definitions, so the model's cached start of
/// the prompt (system prompt, tools, conversation) stays valid for the next real question. The model is
/// not asked to use them: a tool call in the reply is ignored.
const bool kTitleKeepsToolSchemas = true;

/// How long the first question may be when it is used as the title.
const int kQuestionTitleLength = 40;

/// The first question, trimmed to about [kQuestionTitleLength] characters: whitespace collapsed, cut at a
/// space when there is one near the end, with an ellipsis when cut.
String questionTitle(String question) {
  final text = question.trim().split(RegExp(r'\s+')).join(' ');
  final chars = text.runes.toList();
  if (chars.length <= kQuestionTitleLength) return text;
  var cut = String.fromCharCodes(chars.take(kQuestionTitleLength));
  final space = cut.lastIndexOf(' ');
  if (space >= kQuestionTitleLength - 15) cut = cut.substring(0, space);
  return '${cut.trimRight()}…';
}

/// The model's reply as a title: the first line, trimmed and kept short. Null when there is nothing.
String? cleanTitle(String reply) {
  final line = reply.trim().split('\n').first.trim();
  if (line.isEmpty) return null;
  final chars = line.runes.toList();
  return chars.length <= 60 ? line : '${String.fromCharCodes(chars.take(60)).trimRight()}…';
}

/// Asks the loaded model for a title for [loop]'s conversation. Returns null when the model gave none
/// (an error, a tool call, an empty reply) or when [isCancelled] says to drop it.
Future<String?> generateTitle(ModelBackend backend, ToolLoop loop, {bool Function()? isCancelled}) async {
  try {
    final request = loop.requestWith(
      {'role': 'user', 'content': kTitlePrompt},
      withTools: kTitleKeepsToolSchemas,
    );
    var finalText = '';
    var toolCall = false;
    await for (final p in backend.generate(request)) {
      if (!p.isFinal) continue;
      finalText = p.content;
      toolCall = p.hasToolCalls;
    }
    if (toolCall || (isCancelled?.call() ?? false)) return null;
    return cleanTitle(finalText);
  } catch (_) {
    return null;
  }
}

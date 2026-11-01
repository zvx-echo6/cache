/// Gemma 4's tool call markers. A call the model writes as text instead of a parsed call ("<|tool_call>call:search{...}<tool_call|>")
/// must never reach the person: the answer they read has every span from an opening marker through the next closing marker taken
/// out, and an opening marker with no closing one takes the rest of the text with it. The conversation keeps exactly what the model
/// wrote; only the shown text is stripped.
const String kToolCallOpen = '<|tool_call>';
const String kToolCallClose = '<tool_call|>';

/// [text] without its written tool calls (back to back calls included).
String stripToolCalls(String text) {
  if (!text.contains(kToolCallOpen)) return text;
  final out = StringBuffer();
  var i = 0;
  while (true) {
    final open = text.indexOf(kToolCallOpen, i);
    if (open < 0) {
      out.write(text.substring(i));
      break;
    }
    out.write(text.substring(i, open));
    final close = text.indexOf(kToolCallClose, open + kToolCallOpen.length);
    if (close < 0) break;
    i = close + kToolCallClose.length;
  }
  return out.toString();
}

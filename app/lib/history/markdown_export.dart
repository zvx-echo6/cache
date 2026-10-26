import 'conversation_store.dart';

/// A conversation as Markdown for the share sheet: the title, the questions and answers, and the sources
/// the answers cited listed at the end under their numbers.
String conversationToMarkdown(Conversation conversation, List<StoredMessage> messages) {
  final out = StringBuffer('# ${conversation.title}\n\n');
  final sources = <int, StoredCitation>{};
  for (final m in messages) {
    if (!m.shown) continue;
    if (m.role == 'user') {
      out.write('**You**\n\n${m.content}\n\n');
    } else {
      out.write('**Cache**\n\n');
      out.write(m.error != null ? '_${m.error}_\n\n' : '${m.content}\n\n');
      for (final c in m.citations) {
        sources.putIfAbsent(c.n, () => c);
      }
    }
  }
  if (sources.isNotEmpty) {
    out.write('## Sources\n\n');
    for (final n in sources.keys.toList()..sort()) {
      final c = sources[n]!;
      out.write('- [$n] ${c.title}${c.address.isEmpty ? '' : ' (${c.address})'}\n');
    }
  }
  return out.toString().trimRight();
}

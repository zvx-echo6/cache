/// Result of the citation check.
class CitationCheck {
  const CitationCheck(this.text, this.kept);

  /// The answer with unknown [n] markers removed.
  final String text;

  /// Result IDs that are cited and valid, ascending, without duplicates.
  final List<int> kept;
}

final RegExp _marker = RegExp(r'[ \t]?\[(\d+)\]');

/// Machine-format check: keeps [n] markers that match a result ID returned in this conversation and
/// removes the others from the text.
CitationCheck checkCitations(String answer, Set<int> validIds) {
  final kept = <int>{};
  final text = answer.replaceAllMapped(_marker, (m) {
    final n = int.tryParse(m.group(1)!);
    if (n != null && validIds.contains(n)) {
      kept.add(n);
      return m.group(0)!;
    }
    return '';
  });
  return CitationCheck(text, kept.toList()..sort());
}

/// Result of the citation check.
class CitationCheck {
  const CitationCheck(this.text, this.kept);

  /// The answer with unknown citation numbers removed.
  final String text;

  /// Result IDs that are cited and valid, ascending, without duplicates.
  final List<int> kept;
}

/// A citation mark: one number ([1]), or a list or range of them ([1, 2], [1,2,3], [1-3], [1–3]).
final RegExp _marker = RegExp(r'[ \t]?\[\s*(\d+(?:\s*[,\-–]\s*\d+)*)\s*\]');
final RegExp _single = RegExp(r'^\d+$');
final RegExp _part = RegExp(r'(\d+)(?:\s*[\-–]\s*(\d+))?');

/// Machine-format check: keeps the citation numbers that match a result ID returned in this conversation and removes the others
/// from the text.
/// - A single mark ([n]) stays as written when n is valid, and is removed (with the space before it) when not.
/// - A list or range ([1, 2], [1-3]) stays as written when every number in it is valid. When only some are, it becomes the list of
///   the valid ones ([1, 3]); when none are, it is removed. A range counts the valid IDs inside it.
/// - Results are numbered from 1, so a list or range with a 0 in it is not a citation and stays as written (as the display does).
CitationCheck checkCitations(String answer, Set<int> validIds) {
  final kept = <int>{};
  final text = answer.replaceAllMapped(_marker, (m) {
    final body = m.group(1)!;
    if (_single.hasMatch(body)) {
      final n = int.tryParse(body);
      if (n != null && validIds.contains(n)) {
        kept.add(n);
        return m.group(0)!;
      }
      return '';
    }
    final cited = <int>[];
    var all = true;
    for (final p in _part.allMatches(body)) {
      final a = int.tryParse(p.group(1)!);
      final b = p.group(2) == null ? a : int.tryParse(p.group(2)!);
      if (a == null || b == null) return m.group(0)!;
      if (a == 0 || b == 0) return m.group(0)!;
      final lo = a < b ? a : b, hi = a < b ? b : a;
      if (p.group(2) == null) {
        if (validIds.contains(a)) {
          cited.add(a);
        } else {
          all = false;
        }
      } else {
        final inside = validIds.where((n) => n >= lo && n <= hi).toList()..sort();
        if (inside.length != hi - lo + 1) all = false;
        cited.addAll(inside);
      }
    }
    final valid = cited.toSet().toList()..sort();
    kept.addAll(valid);
    if (valid.isEmpty) return '';
    if (all) return m.group(0)!;
    final lead = m.group(0)!.startsWith('[') ? '' : m.group(0)![0];
    return '$lead[${valid.join(', ')}]';
  });
  return CitationCheck(text, kept.toList()..sort());
}

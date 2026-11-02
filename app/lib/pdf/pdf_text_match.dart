/// Finding a cited passage on a PDF page by comparing words.
///
/// A citation carries the passage's text as the search index holds it (`quote`, at most 300 words). The page's own text layer
/// (as PDFium reads it) differs from it in ways that are not about meaning: line breaks and spacing, a word broken across two
/// lines with a hyphen, ligatures (fi, fl), capitals and punctuation, a running head or page number in the middle when the
/// passage goes on to the next page. Both are cut into words (letters and digits), compared word by word, and the passage
/// counts as found only when most of its first words are there in order. Nothing here reads meaning; it is a text compare.
library;

/// One word of a text: what is compared ([norm]) and where it is in the text ([start], [end]: a range of the text's
/// UTF-16 indexes, which are the page's character indexes for a PDF page).
class PdfWord {
  const PdfWord(this.norm, this.start, this.end);

  final String norm;
  final int start;
  final int end;

  @override
  String toString() => '$norm@$start-$end';
}

final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Hyphens a printed line can end with (PDFium reports a line-end hyphen as U+0002 or a soft hyphen).
const String _hyphens = '-­‐‑\u0002';

const Map<String, String> _ligatures = {
  'ﬀ': 'ff',
  'ﬁ': 'fi',
  'ﬂ': 'fl',
  'ﬃ': 'ffi',
  'ﬄ': 'ffl',
  'ﬅ': 'st',
  'ﬆ': 'st',
};

String _norm(String s) {
  var out = s.toLowerCase();
  if (_ligatures.keys.any(out.contains)) {
    _ligatures.forEach((k, v) => out = out.replaceAll(k, v));
  }
  return out;
}

/// The words of [text], in order. A word broken at a line end with a hyphen ("prepared-" then "ness" on the next line) is one
/// word, spanning both pieces.
List<PdfWord> pdfWords(String text) {
  final raw = _word.allMatches(text).toList();
  final out = <PdfWord>[];
  var i = 0;
  while (i < raw.length) {
    var m = raw[i];
    var norm = _norm(m.group(0)!);
    final start = m.start;
    var end = m.end;
    while (i + 1 < raw.length) {
      final gap = text.substring(end, raw[i + 1].start);
      // A hyphen with only spacing after it, before the next word; a soft hyphen or PDFium's line-end mark even with none.
      if (gap.isEmpty || !_hyphens.contains(gap[0]) || gap.substring(1).trim().isNotEmpty) break;
      if (gap.length < 2 && gap[0] == '-') break;
      i++;
      m = raw[i];
      norm += _norm(m.group(0)!);
      end = m.end;
    }
    out.add(PdfWord(norm, start, end));
    i++;
  }
  return out;
}

/// A matched piece of the passage on one page: the page's character range [start] to [end].
class PdfTextSpan {
  const PdfTextSpan(this.page, this.start, this.end);

  /// The page, from 1.
  final int page;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is PdfTextSpan && other.page == page && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(page, start, end);

  @override
  String toString() => 'p$page[$start,$end)';
}

/// How many of the passage's first words are compared to place it.
const int kQuoteHeadWords = 12;

/// The share of those words that must be on the page, in order, for the passage to count as found.
const double kQuoteMinShare = 0.8;

class _Aligned {
  _Aligned(this.matched, this.used, this.quoteUsed, this.spans);

  /// Quote words matched.
  final int matched;

  /// Page words consumed (from the start).
  final int used;

  /// Quote words consumed.
  final int quoteUsed;

  /// The page words that matched, as indexes into the page words.
  final List<int> spans;
}

/// Aligns the quote words [q] with the page words [p] from [from]: equal words match; a word split in two on one side and not
/// on the other matches; a few extra page words (a running head, a page number, a footnote mark) are skipped when the quote
/// picks up right after them; anything else is a miss. Stops after [stopAfterMisses] misses in a row.
_Aligned _align(List<String> q, List<PdfWord> p, int from, {int stopAfterMisses = 1 << 30}) {
  var qi = 0;
  var pi = from;
  var matched = 0;
  var misses = 0;
  final hits = <int>[];
  while (qi < q.length && pi < p.length) {
    if (p[pi].norm == q[qi]) {
      hits.add(pi);
      matched++;
      qi++;
      pi++;
      misses = 0;
      continue;
    }
    if (pi + 1 < p.length && p[pi].norm + p[pi + 1].norm == q[qi]) {
      hits.addAll([pi, pi + 1]);
      matched++;
      qi++;
      pi += 2;
      misses = 0;
      continue;
    }
    if (qi + 1 < q.length && p[pi].norm == q[qi] + q[qi + 1]) {
      hits.add(pi);
      matched += 2;
      qi += 2;
      pi++;
      misses = 0;
      continue;
    }
    // Extra words on the page: the quote goes on a few words later (two quote words in a row must match there).
    var skipped = false;
    for (var k = 1; k <= 8 && pi + k < p.length; k++) {
      if (p[pi + k].norm == q[qi] && (qi + 1 >= q.length || (pi + k + 1 < p.length && p[pi + k + 1].norm == q[qi + 1]))) {
        pi += k;
        skipped = true;
        break;
      }
    }
    if (skipped) continue;
    // A quote word that is not on the page.
    if (qi + 1 < q.length && p[pi].norm == q[qi + 1]) {
      qi++;
    } else {
      qi++;
      pi++;
    }
    misses++;
    if (misses >= stopAfterMisses) break;
  }
  return _Aligned(matched, pi - from, qi, hits);
}

/// Where [quote] is on [page] (its words, as [pdfWords] gives them), and if it runs on, on [next] (the following page's words):
/// the matched ranges, one per page, or null when the passage is not found on [page] with enough confidence.
///
/// [pageNumber] numbers the spans; [next]'s span is on pageNumber + 1.
List<PdfTextSpan>? findQuote(String quote, {required int pageNumber, required List<PdfWord> page, List<PdfWord>? next}) {
  final q = [for (final w in pdfWords(quote)) w.norm];
  if (q.isEmpty || page.isEmpty) return null;
  final head = q.length < kQuoteHeadWords ? q : q.sublist(0, kQuoteHeadWords);
  // A short quote must match whole; a longer one by [kQuoteMinShare] of its first words.
  final need = head.length <= 3 ? head.length : (head.length * kQuoteMinShare).ceil();
  var best = -1;
  var bestScore = 0;
  for (var i = 0; i < page.length; i++) {
    final w = page[i].norm;
    // A start is a page word equal to one of the first two quote words (the very first may be cut or hyphenated).
    if (w != head[0] && !(head.length > 1 && w == head[1]) && !head[0].startsWith(w)) continue;
    final a = _align(head, page, i, stopAfterMisses: 4);
    if (a.matched > bestScore) {
      bestScore = a.matched;
      best = i;
      if (bestScore == head.length) break;
    }
  }
  if (best < 0 || bestScore < need) return null;
  // The whole passage, from there, over this page and the next.
  final words = [...page, ...?next];
  final a = _align(q, words, best, stopAfterMisses: 6);
  final hits = a.spans.isEmpty ? [best] : a.spans;
  final out = <PdfTextSpan>[];
  int? s0, e0, s1, e1;
  for (final h in hits) {
    if (h < page.length) {
      s0 ??= words[h].start;
      e0 = words[h].end;
    } else {
      s1 ??= words[h].start;
      e1 = words[h].end;
    }
  }
  if (s0 != null) out.add(PdfTextSpan(pageNumber, s0, e0!));
  if (s1 != null) out.add(PdfTextSpan(pageNumber + 1, s1, e1!));
  return out;
}

/// The first [n] words of [quote], as typed into find ("Find on other pages").
String quoteOpening(String quote, {int n = 6}) {
  final m = _word.allMatches(quote).take(n).toList();
  if (m.isEmpty) return quote.trim();
  return [for (final x in m) x.group(0)!].join(' ');
}

/// What find looks for: the words of [query] in order, with anything that is not a letter or digit between them (spaces,
/// line breaks, punctuation, a line-end hyphen); case is ignored. A query with no letters or digits is looked for as typed.
RegExp findPattern(String query) {
  final words = [for (final m in _word.allMatches(query)) RegExp.escape(m.group(0)!)];
  if (words.isEmpty) return RegExp(RegExp.escape(query.trim()), caseSensitive: false);
  return RegExp(words.join(r'[^\p{L}\p{N}]+'), caseSensitive: false, unicode: true);
}

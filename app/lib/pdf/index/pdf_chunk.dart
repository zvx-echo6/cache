import 'pdf_index_core.dart';

/// Words a piece aims at, at most, and shares with the one before it (the rule of cache_chunk, which the server and the builder
/// use; cs_pdf_chunk will give it on the device).
const int kPieceWords = 200;
const int kPieceMaxWords = 300;
const int kPieceOverlap = 40;

/// The pieces of a PDF's pages, the cache_chunk rule as far as a PDF read with pdfrx allows (no headings): about
/// [kPieceWords] words a piece with [kPieceOverlap] words of overlap, running across pages; each piece names the page it starts
/// on (its printed label, else its number) and, when it runs on, the page it ends on. Pages with no text are listed apart.
PdfChunks chunkPdfPages(List<PdfPageText> pages) {
  final words = <(String, int)>[];
  final labels = <int, String>{};
  final empty = <int>[];
  for (final p in pages) {
    labels[p.index] = (p.label == null || p.label!.trim().isEmpty) ? '${p.index + 1}' : p.label!;
    final ws = p.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (ws.isEmpty) {
      empty.add(p.index);
      continue;
    }
    for (final w in ws) {
      words.add((w, p.index));
    }
  }
  final pieces = <Map<String, dynamic>>[];
  const step = kPieceWords - kPieceOverlap;
  for (var at = 0; at < words.length; at += step) {
    var end = at + kPieceWords;
    // The last few words join the piece before rather than making a tiny one of their own (never past the most a piece holds).
    if (words.length - end < kPieceOverlap && words.length - at <= kPieceMaxWords) end = words.length;
    if (end > words.length) end = words.length;
    final first = words[at].$2, last = words[end - 1].$2;
    pieces.add({
      'i': pieces.length,
      'text': [for (var k = at; k < end; k++) words[k].$1].join(' '),
      'page': labels[first],
      'pdf_page': first + 1,
      if (last != first) 'pdf_page_end': last + 1,
      'heading_path': const <String>[],
    });
    if (end == words.length) break;
  }
  return PdfChunks(pieces: pieces, emptyPages: empty, pages: [
    for (final p in pages)
      if (p.text.trim().isNotEmpty) {'pdf_page': p.index + 1, 'label': p.label ?? '', 'text': p.text},
  ]);
}

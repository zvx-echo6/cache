// Split from pdf_pages.dart (which needs Flutter and pdfrx) so the server's helper, plain Dart, cleans titles by the same rule.

/// A PDF's metadata Title as cs_pdfindex_add's "title": trimmed, or "" when it is empty or is plainly a file name rather than a
/// title (an office program's "Microsoft Word - report.doc", or a name ending in a document extension); the core then makes a
/// readable name from the entry's file name.
String cleanPdfTitle(String? title) {
  var t = (title ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return '';
  if (RegExp(r'^microsoft (word|powerpoint|excel)\s*-', caseSensitive: false).hasMatch(t)) return '';
  if (RegExp(r'\.(docx?|pptx?|xlsx?|pdf|indd|rtf|odt|txt|qxd|pub|wpd)$', caseSensitive: false).hasMatch(t)) return '';
  if (!RegExp(r'[A-Za-z]').hasMatch(t)) return '';
  return t;
}

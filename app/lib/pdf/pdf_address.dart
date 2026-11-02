/// Addresses of PDFs and of pages in them.
///
/// A page of a PDF entry in a ZIM is the entry's `zim:<uuid>/<path>` address with a literal `#page=N` after it (N from 1), as
/// citations and search results write it: `zim:0f1e...9a/I/FM_21-76.pdf#page=47`. A `#` inside the path itself is always
/// escaped (`%23`), so the first `#` starts the fragment.
library;

final RegExp _pageFragment = RegExp(r'(?:^|&)page=(\d{1,7})(?:&|$)');

/// The address without its `#fragment`.
String withoutFragment(String address) {
  final i = address.indexOf('#');
  return i < 0 ? address : address.substring(0, i);
}

/// The page an address points at (`#page=47` gives 47), or null when it names none.
int? pdfPageOfAddress(String address) {
  final i = address.indexOf('#');
  if (i < 0) return null;
  final m = _pageFragment.firstMatch(address.substring(i + 1));
  final n = m == null ? null : int.tryParse(m.group(1)!);
  return n == null || n < 1 ? null : n;
}

/// [address] pointing at [page] (any fragment it had is replaced).
String withPdfPage(String address, int page) => '${withoutFragment(address)}#page=$page';

/// True when the address's path (without its query and fragment) names a .pdf file, or it points at a page (`#page=N`).
bool isPdfAddress(String address) {
  if (pdfPageOfAddress(address) != null) return true;
  var path = withoutFragment(address);
  final q = path.indexOf('?');
  if (q >= 0) path = path.substring(0, q);
  return path.toLowerCase().endsWith('.pdf');
}

/// True when [head] (the first bytes of a file) is a PDF: the `%PDF-` header, which the format allows within the first 1024
/// bytes.
bool looksLikePdf(List<int> head) {
  const sig = [0x25, 0x50, 0x44, 0x46, 0x2d];
  final end = head.length < 1024 ? head.length : 1024;
  for (var i = 0; i + sig.length <= end; i++) {
    var ok = true;
    for (var j = 0; j < sig.length; j++) {
      if (head[i + j] != sig[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

/// A file name or entry path as a title: its last part, unescaped, without ".pdf", underscores as spaces.
String pdfTitleOf(String pathOrName) {
  var s = withoutFragment(pathOrName);
  final q = s.indexOf('?');
  if (q >= 0) s = s.substring(0, q);
  s = s.split(RegExp(r'[\\/]')).last;
  try {
    s = Uri.decodeComponent(s);
  } catch (_) {
    // A name with a lone % stays as it is.
  }
  if (s.toLowerCase().endsWith('.pdf')) s = s.substring(0, s.length - 4);
  s = s.replaceAll('_', ' ').trim();
  return s.isEmpty ? 'PDF' : s;
}

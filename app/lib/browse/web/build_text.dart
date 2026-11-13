import '../../video/format.dart' show formatBytes;
import 'build_api.dart';
import 'local_files.dart';

/// "9 to 13 hours", "20 to 35 minutes" or "less than a minute": the words for a range of seconds.
String etaRange(int low, int high) {
  if (high < 90) return 'less than a minute';
  if (high < 90 * 60) {
    final a = (low / 60).round().clamp(1, 100000);
    final b = (high / 60).round().clamp(1, 100000);
    return a == b ? 'about $b minutes' : '$a to $b minutes';
  }
  final a = (low / 3600).round().clamp(1, 100000);
  final b = (high / 3600).round().clamp(1, 100000);
  return a == b ? 'about $b ${b == 1 ? 'hour' : 'hours'}' : '$a to $b hours';
}

/// The short form for the list: "9 to 13 h", "20 to 35 min".
String etaShort(int low, int high) {
  if (high < 90) return '1 min';
  if (high < 90 * 60) {
    final a = (low / 60).round().clamp(1, 100000);
    final b = (high / 60).round().clamp(1, 100000);
    return a == b ? '$b min' : '$a to $b min';
  }
  final a = (low / 3600).round().clamp(1, 100000);
  final b = (high / 3600).round().clamp(1, 100000);
  return a == b ? '$b h' : '$a to $b h';
}

/// "just now", "12 min ago", "1 h ago", "3 d ago", else the date.
String addedWords(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inSeconds < 90) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}

/// "14 Aug" (this year) or "14 Aug 2025".
String dateWords(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  final y = (now ?? DateTime.now()).year;
  return l.year == y ? '${l.day} ${months[l.month - 1]}' : '${l.day} ${months[l.month - 1]} ${l.year}';
}

/// 98430 -> "98,430".
String thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String bookCount(int n) => '${thousands(n)} ${n == 1 ? 'book' : 'books'}';

/// The line under a book in the queue.
String queueStateWords(QueueItem i) {
  switch (i.state) {
    case 'queued':
      return 'Waiting';
    case 'reading':
      // The scanned pages are being read by OCR (the same words the phones use).
      if (i.progress.ocrPages > 0) return 'Reading scanned pages (OCR) · ${thousands(i.progress.ocrDone)} of ${thousands(i.progress.ocrPages)}';
      return 'Reading the PDF';
    case 'building':
      final total = i.progress.piecesTotal;
      return total == null ? 'Building passages' : 'Building passages · ${thousands(i.progress.pieces)} of ${thousands(total)}';
    case 'skipped_duplicate':
      return 'Skipped. The same content is already in this library${i.duplicateOf == null ? '' : ' as "${i.duplicateOf}"'}.';
    case 'failed':
    case 'ocr_needed':
      return i.error ?? 'This PDF could not be built.';
    default:
      return '';
  }
}

/// 0..1 for the book being built, or its scanned pages being read; null while it is only being read.
double? queueFraction(QueueItem i) {
  if (i.state == 'reading' && i.progress.ocrPages > 0) return (i.progress.ocrDone / i.progress.ocrPages).clamp(0.0, 1.0);
  final total = i.progress.piecesTotal;
  if (i.state != 'building' || total == null || total <= 0) return null;
  return (i.progress.pieces / total).clamp(0.0, 1.0);
}

/// The kind of a file in the drop folder, for the Type column.
String dropKindWords(DropFile f) {
  final n = f.name.toLowerCase();
  if (n.endsWith('.pdf')) return 'PDF';
  if (n.endsWith('.zim') || n.endsWith('.cache-library') || n.endsWith('.gz')) return 'Library file';
  return 'Other';
}

/// Pieces of a drop: the PDFs, and the names of the other files that were left out.
class PdfSplit {
  const PdfSplit(this.pdfs, this.leftOut);

  final List<LocalFile> pdfs;
  final List<String> leftOut;

  String? get leftOutWords {
    if (leftOut.isEmpty) return null;
    final shown = leftOut.take(3).join(', ');
    final more = leftOut.length > 3 ? ', and ${leftOut.length - 3} more' : '';
    return '${leftOut.length} other ${leftOut.length == 1 ? 'file was' : 'files were'} left out ($shown$more).';
  }
}

bool isPdfName(String name) => name.toLowerCase().endsWith('.pdf');

PdfSplit splitPdfs(List<LocalFile> files) {
  final pdfs = <LocalFile>[];
  final out = <String>[];
  for (final f in files) {
    if (isPdfName(f.name)) {
      pdfs.add(f);
    } else if (!f.name.startsWith('.')) {
      out.add(f.name);
    }
  }
  return PdfSplit(pdfs, out);
}

int totalBytes(Iterable<LocalFile> files) => files.fold<int>(0, (s, f) => s + f.size);

String sizeWords(int bytes) => formatBytes(bytes);

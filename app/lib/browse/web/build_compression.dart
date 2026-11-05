import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../video/format.dart' show formatBytes;
import 'build_api.dart';

/// Only recorded sizes are used: old books without compression facts remain unknown.
int? storedBookBytes(BuildBook book) {
  final stored = book.compression?['stored_size'];
  if (stored is num && stored > 0) return stored.toInt();
  return book.size > 0 ? book.size : null;
}

/// Describes the stored result, including a smaller-scans attempt that fell back
/// to an unchanged-pages copy. No compression is inferred for legacy books.
String? compressionOutcomeWords(BuildBook book) {
  final c = book.compression;
  final stored = storedBookBytes(book);
  if (c == null) return stored == null ? null : 'Stored ${formatBytes(stored)}';
  final level = c['level'];
  if (level == 'off') return stored == null ? 'Not made smaller' : 'Stored ${formatBytes(stored)} · Not made smaller';
  if (c['kept_original'] == true) {
    final reason = c['kept_reason'];
    final words = reason == 'timed out' ? 'Making it smaller timed out.' : 'Cache kept the original because a smaller copy did not pass its checks.';
    return 'Kept as it came · $words';
  }
  if (stored == null) return null;
  final original = c['original_size'];
  final was = original is num && original > stored ? ' (was ${formatBytes(original.toInt())})' : '';
  // The native contract records a note when smaller_scans stores its lossless fallback.
  final unchanged = level == 'lossless' || (level == 'smaller_scans' && c['kept_reason'] != null);
  final label = unchanged
      ? 'Smaller file, pages unchanged'
      : level == 'smaller_scans'
      ? 'Smaller scans: ${switch (c['preset']) {
          'high' => 'High quality',
          'smallest' => 'Smallest',
          _ => 'Balanced',
        }}'
      : null;
  return 'Stored ${formatBytes(stored)}$was${label == null ? '' : ' · $label'}';
}

/// The original-kept result is informational, not an ingestion failure.
class CompressionOutcomeLine extends StatelessWidget {
  const CompressionOutcomeLine({super.key, required this.book});
  final BuildBook book;
  @override
  Widget build(BuildContext context) {
    final words = compressionOutcomeWords(book);
    if (words == null) return const SizedBox.shrink();
    final kept = book.compression?['kept_original'] == true && book.compression?['level'] != 'off';
    const prefix = 'Kept as it came';
    return Text.rich(
      TextSpan(
        children: kept
            ? [
                const TextSpan(
                  text: prefix,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Tooltip(
                      message: 'The original PDF is stored. Making it smaller did not stop the book from being built.',
                      child: Icon(Icons.info_outline, size: 12, color: context.t.secondary),
                    ),
                  ),
                ),
                TextSpan(text: words.substring(prefix.length)),
              ]
            : [TextSpan(text: words)],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: context.t.secondary),
    );
  }
}

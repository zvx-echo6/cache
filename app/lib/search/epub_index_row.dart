import 'package:cache_search/cache_search.dart' show ZimSubIndex;
import 'package:flutter/material.dart';

import '../theme.dart';
import '../maps/ui/format.dart' show formatCount;

/// The line about a ZIM's EPUBs next to its PDFs: null when it has none (or the core has not looked yet).
/// - being made searchable: "Making EPUBs searchable: 40 of 85" (the job's books read, of all of them);
/// - still to do: "Waiting to make EPUBs searchable";
/// - done: "EPUBs: searching ready".
String? epubLine(ZimSubIndex? e, (int, int)? progress) {
  if (e == null) return null;
  if (progress != null) return 'Making EPUBs searchable: ${formatCount(progress.$1)} of ${formatCount(progress.$2)}';
  if (e.state == 'ready') return 'EPUBs: searching ready';
  if (e.needsBuild == true) return 'Waiting to make EPUBs searchable';
  return null;
}

/// [epubLine] as a row beside the PDFs part (with a bar while it runs); nothing when there is no line.
class EpubIndexRow extends StatelessWidget {
  const EpubIndexRow({super.key, required this.epub, required this.progress});

  final ZimSubIndex? epub;
  final (int, int)? progress;

  @override
  Widget build(BuildContext context) {
    final line = epubLine(epub, progress);
    if (line == null) return const SizedBox.shrink();
    final k = context.t;
    final p = progress;
    return Padding(
      key: const ValueKey('epubindex-part'),
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(line, key: const ValueKey('epubindex-line'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
          if (p != null && p.$2 > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: (p.$1 / p.$2).clamp(0.0, 1.0), minHeight: 4),
              ),
            ),
        ],
      ),
    );
  }
}

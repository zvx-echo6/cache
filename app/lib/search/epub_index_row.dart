import 'package:cache_search/cache_search.dart' show ZimSubIndex;
import 'package:flutter/material.dart';

import '../platform/battery.dart';
import '../theme.dart';
import 'index_scheduler.dart';
import 'index_status.dart';

/// The line about a ZIM's EPUBs (or its caption files, [kind] "zim-captions") next to its PDFs: null when it has none (or the
/// core has not looked yet). The index scheduler's word comes first ([item]): only the work it runs says "Making", with
/// progress; queued work says "Waiting to make EPUBs searchable"; held work says why and what makes it go on. Without it:
/// - being made searchable: "Making EPUBs searchable · 40 of 85" (the job's books read, of all of them);
/// - still to do: "Waiting to make EPUBs searchable";
/// - done: "EPUBs: searching ready".
String? epubLine(ZimSubIndex? e, (int, int)? progress, {String kind = 'zim-epub', IndexItem? item, BatteryReading? battery}) {
  if (e == null) return null;
  if (item != null && item.state != IndexState.done) {
    final withProgress = item.progress == null && progress != null
        ? IndexItem(key: item.key, state: item.state, title: item.title, why: item.why, position: item.position, progress: progress, bytesNeeded: item.bytesNeeded, slowed: item.slowed)
        : item;
    return indexItemWords(withProgress, battery: battery);
  }
  if (progress != null) return '${indexDoingWords(kind)} · ${indexOf(progress)}';
  if (e.state == 'ready') return kind == 'zim-epub' ? 'EPUBs: searching ready' : 'Captions: searching ready';
  if (e.needsBuild == true) return indexWaitingWords(kind);
  return null;
}

/// [epubLine] as a row beside the PDFs part (with a bar while it runs); nothing when there is no line.
class EpubIndexRow extends StatelessWidget {
  const EpubIndexRow({super.key, required this.epub, required this.progress, this.kind = 'zim-epub', this.item, this.battery});

  final ZimSubIndex? epub;
  final (int, int)? progress;

  /// "zim-epub" or "zim-captions".
  final String kind;

  /// What the index scheduler says of this work, when it has it.
  final IndexItem? item;
  final BatteryReading? battery;

  @override
  Widget build(BuildContext context) {
    final line = epubLine(epub, progress, kind: kind, item: item, battery: battery);
    if (line == null) return const SizedBox.shrink();
    final k = context.t;
    final p = item?.progress ?? progress;
    final running = item == null ? progress != null : item!.state == IndexState.running;
    final tag = kind == 'zim-epub' ? 'epubindex' : 'captionsindex';
    return Padding(
      key: ValueKey('$tag-part'),
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(line, key: ValueKey('$tag-line'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
          if (running && p != null && p.$2 > 0)
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

import '../maps/ui/format.dart' show formatBytes, formatCount;
import '../platform/battery.dart';
import 'index_scheduler.dart';

/// What a kind of index work is about, as the person says it ("PDFs", "EPUBs", "captions"); the seal of an index built before
/// snapshots is "the search index".
String indexPartWord(String kind) => switch (kind) {
  'zim-pdf' => 'PDFs',
  'zim-epub' => 'EPUBs',
  'zim-captions' || 'captions' => 'captions',
  _ => 'the search index',
};

/// "Making PDFs searchable"; the seal of an older index: "Getting the search index ready".
String indexDoingWords(String kind) => switch (kind) {
  'zim-pdf' || 'zim-epub' || 'zim-captions' || 'captions' => 'Making ${indexPartWord(kind)} searchable',
  _ => 'Getting the search index ready',
};

/// "Waiting to make PDFs searchable"; the seal: "Waiting to get the search index ready".
String indexWaitingWords(String kind) => switch (kind) {
  'zim-pdf' || 'zim-epub' || 'zim-captions' || 'captions' => 'Waiting to make ${indexPartWord(kind)} searchable',
  _ => 'Waiting to get the search index ready',
};

/// Running, slowed for heat: "device is warm" only when the system's thermal status says so; on its forecast alone, keeping it cool.
String indexSlowedWords(bool warm) => warm ? 'Slowed down · device is warm' : 'Slowed down · keeping the device cool';

/// Why work waits, and what makes it go on, in the same words on the Library rows, their menus, the Library's overview and the
/// Settings line: "Paused · battery low (12%) · plug in to continue", "Waits for charging (long job)", "Paused · device is
/// warm", "Paused · Cache is in the background", "Paused · while Ask answers", "Needs 1.2 GB free · Free space", "Paused by
/// you · Resume". Null for none (running as usual or queued).
String? indexWaitWords(IndexWait w, {BatteryReading? battery, int bytesNeeded = 0, bool warm = false}) => switch (w) {
  IndexWait.none => null,
  IndexWait.battery => battery == null
      ? 'Paused · battery low · plug in to continue'
      : 'Paused · battery low (${battery.percent}%) · plug in to continue',
  IndexWait.charging => 'Waits for charging (long job)',
  // "warm" only when the system's thermal status says so; held on the forecast alone, it is keeping the device cool
  IndexWait.heat => warm ? 'Paused · device is warm' : 'Paused · keeping the device cool',
  IndexWait.closed => 'Paused · Cache is in the background',
  IndexWait.model => 'Paused · while Ask answers',
  IndexWait.storage => bytesNeeded > 0 ? 'Needs ${formatBytes(bytesNeeded)} free · Free space' : 'Needs more free space · Free space',
  IndexWait.person => 'Paused by you · Resume',
  IndexWait.stuck => 'Stuck · skipped for now · Retry',
};

/// "340 of 5,768".
String indexOf((int, int) p) => '${formatCount(p.$1)} of ${formatCount(p.$2)}';

/// One piece of work in a line: running "Making PDFs searchable · 340 of 5,768" (slowed: "Slowed down · device is warm · 340 of
/// 5,768"), held for a reason ([indexWaitWords]), queued "Waiting to make PDFs searchable", done null.
String? indexItemWords(IndexItem i, {BatteryReading? battery}) {
  final p = i.progress;
  final of = p == null || p.$2 <= 0 ? '' : ' · ${indexOf(p)}';
  switch (i.state) {
    case IndexState.running:
      final held = indexWaitWords(i.why, battery: battery, bytesNeeded: i.bytesNeeded, warm: i.warm);
      if (held != null) return '$held$of';
      if (i.slowed) return '${indexSlowedWords(i.warm)}$of';
      return '${indexDoingWords(i.kind)}$of';
    case IndexState.held:
      // stuck: where it stopped moving, so a screenshot shows the step it hangs in
      final at = i.step;
      if (i.why == IndexWait.stuck && at != null && at.isNotEmpty) return 'Stuck at: ${at[0].toLowerCase()}${at.substring(1)} · Retry';
      return indexWaitWords(i.why, battery: battery, bytesNeeded: i.bytesNeeded, warm: i.warm) ?? indexWaitingWords(i.kind);
    case IndexState.queued:
      return indexWaitingWords(i.kind);
    case IndexState.done:
      return null;
  }
}

/// The line Settings and the Library's overview show while there is work: "Getting search ready · 1 of 9 done", and why it does
/// not go on as usual: "Getting search ready · 1 of 9 done · Paused · battery low (12%) · plug in to continue". Null when there is
/// no work.
String? indexStatusLine(IndexScheduler s) {
  if (!s.busy) return null;
  final head = 'Getting search ready · ${s.doneCount} of ${s.totalCount} done';
  final running = s.running == null ? null : s.statusOf(s.running!);
  if (running != null && running.why == IndexWait.none && running.slowed) {
    return '$head · ${indexSlowedWords(running.warm)}';
  }
  final why = s.reason;
  final first = [for (final i in s.items) if (i.why == why) i].firstOrNull;
  final words = indexWaitWords(why, battery: s.reading, bytesNeeded: first?.bytesNeeded ?? 0, warm: s.deviceWarm);
  return words == null ? head : '$head · $words';
}

/// The work the overview names under its line: what runs now, "Army Publishing · PDFs 340 of 5,768"; else the next in turn,
/// "Army Publishing · PDFs"; null when there is none.
String? indexCurrentWords(IndexScheduler s) {
  final items = s.items;
  final i = items.where((i) => i.state == IndexState.running).firstOrNull ?? items.where((i) => i.state != IndexState.done).firstOrNull;
  if (i == null) return null;
  final name = i.title.isEmpty ? indexPartWord(i.kind) : '${i.title} · ${indexPartWord(i.kind)}';
  final p = i.progress;
  return p == null || p.$2 <= 0 ? name : '$name ${indexOf(p)}';
}

/// The keys of a ZIM's index work, as the scheduler lists them: its PDFs, EPUBs, captions, and the seal of an older index.
List<String> zimIndexKeys(String id) => ['zim-pdf/$id', 'zim-epub/$id', 'zim-captions/$id', 'zim/$id'];

/// The few words a Library row adds for its index work, from the scheduler alone: what runs on it now (with progress), else
/// why its first held work waits, else what is queued; null when the scheduler has nothing for it.
String? indexRowWords(IndexScheduler s, List<String> keys) {
  final items = [for (final k in keys) ?s.statusOf(k)];
  final running = items.where((i) => i.state == IndexState.running).firstOrNull;
  if (running != null) return indexItemWords(running, battery: s.reading);
  final held = [for (final i in items) if (i.state == IndexState.held) i]..sort((a, b) => a.position.compareTo(b.position));
  if (held.isNotEmpty) return indexItemWords(held.first, battery: s.reading);
  final queued = [for (final i in items) if (i.state == IndexState.queued) i]..sort((a, b) => a.position.compareTo(b.position));
  if (queued.isNotEmpty) return indexItemWords(queued.first, battery: s.reading);
  return null;
}

/// What tells one library from another of the same name, by work key (`zim-epub/<id>`): the catalogue's summary of that ZIM, or
/// its file name. Set by the app; null in tests.
String? Function(String key)? indexItemDetail;

/// An item's name in the queue: "Wikipedia · PDFs"; when another item of the same kind has the same name (several "Project
/// Gutenberg Library" ZIMs), with what tells them apart: "Project Gutenberg Library · Law books · EPUBs".
String indexItemTitle(IndexItem i, Iterable<IndexItem> all) {
  final part = indexPartWord(i.kind);
  if (i.title.isEmpty) return part;
  final same = all.any((o) => o.key != i.key && o.kind == i.kind && o.title == i.title);
  final detail = same ? indexItemDetail?.call(i.key) : null;
  return detail == null || detail.isEmpty ? '${i.title} · $part' : '${i.title} · $detail · $part';
}

/// One piece of work in the queue sheet: as [indexItemWords], but running work names its step as it goes ("Reading page 12 of
/// 300 · PDF 3 of 37 · 12 MB"; slowed or held: "Slowed down · device is warm · Reading page 12 of 300 · ...").
String? indexQueueWords(IndexItem i, {BatteryReading? battery}) {
  final step = i.step;
  if (i.state != IndexState.running || step == null || step.isEmpty) return indexItemWords(i, battery: battery);
  final held = indexWaitWords(i.why, battery: battery, bytesNeeded: i.bytesNeeded, warm: i.warm);
  if (held != null) return '$held · $step';
  if (i.slowed) return '${indexSlowedWords(i.warm)} · $step';
  return step;
}

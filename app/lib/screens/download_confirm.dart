import 'package:flutter/material.dart';

import '../settings/data_policy.dart';
import '../settings/space.dart';
import '../theme.dart';
import '../video/format.dart';

/// One thing a download brings, as the pop-up lists it: "WikiMed, medical encyclopedia  2.1 GB".
class DownloadLine {
  const DownloadLine(this.name, this.bytes, {this.note});

  final String name;
  final int bytes;

  /// Said in place of the size: a part that adds nothing ("Already on this phone").
  final String? note;
}

/// What the person chose in the download pop-up.
enum DownloadChoice {
  cancel,

  /// Download now (on mobile data with mobile-data downloads off: anyway).
  now,

  /// Start it, waiting for Wi-Fi before any data moves.
  whenWifi,
}

/// Where "Free up space" goes: Settings > Storage. The app's frame sets it; without it the button is left out.
void Function(BuildContext context)? openStorageForSpace;

/// The one confirm pop-up for every download (Library, Regions, Models and the rest): the items with their sizes, what it does to the
/// phone's storage, and, when it will not fit, how much more is needed and a way to Storage. On mobile data with mobile-data
/// downloads off it says so and offers "Wait for Wi-Fi" first. [space] is the storage the files go to.
///
/// [summary] is said in place of the list of items ("Map, directions, places and off-road."), with [bytes] the size in all (null:
/// not known, "Size unknown"); [action] is the button's word ("Download", "Carry on"); [name] is what is downloaded, for "Idaho needs
/// 1.8 GB" when it does not fit.
Future<DownloadChoice> confirmDownload(
  BuildContext context, {
  required String title,
  required List<DownloadLine> lines,
  required Space space,
  bool mobileBlocked = false,
  List<String>? summary,
  int? bytes,
  String action = 'Download',
  String? name,
}) async {
  final choice = await showDialog<DownloadChoice>(
    context: context,
    builder: (ctx) => _DownloadDialog(
      title: title,
      lines: lines,
      space: space,
      mobileBlocked: mobileBlocked,
      summary: summary,
      bytes: summary == null ? null : bytes,
      action: action,
      name: name,
    ),
  );
  return choice ?? DownloadChoice.cancel;
}

/// [confirmDownload] with the storage of [dir] and the mobile-data rule read now.
Future<DownloadChoice> askToDownload(
  BuildContext context, {
  required String title,
  List<DownloadLine> lines = const [],
  required String dir,
  DataPolicy? policy,
  Space Function(String dir) spaceOf = Space.of,
  List<String>? summary,
  int? bytes,
  String action = 'Download',
  String? name,
}) async {
  final blocked = policy != null && await policy.blocksDownload();
  if (!context.mounted) return DownloadChoice.cancel;
  return confirmDownload(context,
      title: title, lines: lines, space: spaceOf(dir), mobileBlocked: blocked, summary: summary, bytes: bytes, action: action, name: name);
}

/// Delete always asks first, in the same shape: what it frees, the storage after, that it can come back, and a red Delete.
Future<bool> confirmDelete(
  BuildContext context, {
  required String name,
  required int bytes,
  int? free,
  String again = 'You can download it again later.',
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final k = ctx.t;
      return AlertDialog(
        title: Text('Delete $name?', maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SizeLine(name: 'Frees', bytes: bytes),
            if (free != null) ...[
              const SizedBox(height: 8),
              _small(ctx, 'Phone storage', '${formatBytes(free)} free now, ${formatBytes(free + bytes)} after'),
            ],
            const SizedBox(height: 8),
            Text(again, style: TextStyle(fontSize: 13, color: k.secondary)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('confirm-delete'),
            style: FilledButton.styleFrom(backgroundColor: k.emergency, foregroundColor: k.background),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return yes == true;
}

Widget _small(BuildContext context, String left, String right) {
  final k = context.t;
  return Row(
    children: [
      Text(left, style: TextStyle(fontSize: 12, color: k.secondary)),
      const SizedBox(width: 8),
      Expanded(child: Text(right, textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: k.secondary))),
    ],
  );
}

class _SizeLine extends StatelessWidget {
  const _SizeLine({required this.name, required this.bytes, this.note});

  final String name;
  final int bytes;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.text))),
          const SizedBox(width: 12),
          if (note case final n?)
            Flexible(child: Text(n, textAlign: TextAlign.end, style: TextStyle(fontSize: 14, color: k.secondary)))
          else
            Text(formatBytes(bytes), style: TextStyle(fontSize: 14, color: k.text)),
        ],
      ),
    );
  }
}

class _DownloadDialog extends StatelessWidget {
  const _DownloadDialog({
    required this.title,
    required this.lines,
    required this.space,
    required this.mobileBlocked,
    this.summary,
    this.bytes,
    this.action = 'Download',
    this.name,
  });

  final String title;
  final List<DownloadLine> lines;
  final Space space;
  final bool mobileBlocked;
  final List<String>? summary;
  final int? bytes;
  final String action;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final said = summary;
    final known = said == null || bytes != null;
    final total = said == null ? lines.fold<int>(0, (s, l) => s + l.bytes) : (bytes ?? 0);
    final free = space.free;
    final short = space.shortBy(total);
    final fits = short == 0;
    final storage = openStorageForSpace;
    final body = TextStyle(fontSize: 15, height: 1.4, color: k.text);
    if (!fits && said != null) {
      // Not enough room: what it needs, what there is, and the way to make room as the button.
      final usable = space.usable ?? 0;
      return AlertDialog(
        title: const Text('Not enough space'),
        content: Text(
          '${name ?? 'This download'} needs ${formatBytes(total)}. You have ${formatBytes(usable)} to use; Cache keeps '
          '${formatBytes(space.reserve)} free for the phone.',
          key: const ValueKey('download-short'),
          style: body,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, DownloadChoice.cancel), child: const Text('Cancel')),
          if (storage != null)
            FilledButton(
              key: const ValueKey('free-up-space'),
              onPressed: () {
                Navigator.pop(context, DownloadChoice.cancel);
                storage(context);
              },
              child: const Text('Free up space'),
            ),
        ],
      );
    }
    return AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (said != null)
            for (final (i, line) in said.indexed)
              Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 6), child: Text(line, key: ValueKey('download-summary-$i'), style: body))
          else
            for (final l in lines) _SizeLine(name: l.name, bytes: l.bytes, note: l.note),
          if (free != null && known) ...[
            const SizedBox(height: 10),
            _Bar(free: free, bytes: total, fits: fits),
            const SizedBox(height: 6),
            _small(context, 'Phone storage', fits ? '${formatBytes(free)} free, ${formatBytes(free - total)} after' : '${formatBytes(free)} free, needs ${formatBytes(total)}'),
          ],
          if (!fits) ...[
            const SizedBox(height: 8),
            Text(
              'Needs ${formatBytes(short)} more. Cache always leaves ${formatBytes(space.reserve)} for the phone.',
              key: const ValueKey('download-short'),
              style: TextStyle(fontSize: 13, color: k.warning),
            ),
          ] else if (mobileBlocked) ...[
            const SizedBox(height: 8),
            Text(
              "You're on mobile data, and mobile data downloads are off. It can wait for Wi-Fi.",
              key: const ValueKey('download-mobile'),
              style: TextStyle(fontSize: 13, color: k.warning),
            ),
          ],
        ],
      ),
      actions: [
        if (!fits) ...[
          TextButton(onPressed: () => Navigator.pop(context, DownloadChoice.cancel), child: const Text('Cancel')),
          if (storage != null)
            FilledButton(
              key: const ValueKey('free-up-space'),
              onPressed: () {
                Navigator.pop(context, DownloadChoice.cancel);
                storage(context);
              },
              child: const Text('Free up space'),
            ),
        ] else if (mobileBlocked) ...[
          TextButton(key: const ValueKey('download-now'), onPressed: () => Navigator.pop(context, DownloadChoice.now), child: const Text('Download now')),
          FilledButton(key: const ValueKey('wait-for-wifi'), onPressed: () => Navigator.pop(context, DownloadChoice.whenWifi), child: const Text('Wait for Wi-Fi')),
        ] else ...[
          TextButton(onPressed: () => Navigator.pop(context, DownloadChoice.cancel), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('confirm-download'), onPressed: () => Navigator.pop(context, DownloadChoice.now), child: Text(action)),
        ],
      ],
    );
  }
}

/// The storage bar: the free space, with the part this download takes in the accent colour (all of it in the warning colour when it
/// does not fit). The words under it carry the same facts, so the colour is never the only sign.
class _Bar extends StatelessWidget {
  const _Bar({required this.free, required this.bytes, required this.fits});

  final int free;
  final int bytes;
  final bool fits;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final share = free <= 0 ? 1.0 : (bytes / free).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (share > 0) Expanded(flex: (share * 1000).round().clamp(1, 1000), child: ColoredBox(color: fits ? k.accent : k.warning)),
            if (share < 1) Expanded(flex: ((1 - share) * 1000).round().clamp(1, 1000), child: ColoredBox(color: k.secondary.withValues(alpha: 0.3))),
          ],
        ),
      ),
    );
  }
}

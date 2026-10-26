import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/format.dart';
import '../../video/video_state.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// Videos saved on the phone, and the downloads in progress. Everything here plays with no connection.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.video});

  final VideoState video;

  Future<void> _play(BuildContext context, DownloadedVideo d) async {
    try {
      final target = await video.resolve(d.uuid, instance: d.instance);
      if (!context.mounted) return;
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PlayerScreen(target: target, thumbnail: d.thumbnailPath)));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(videoErrorText(e))));
    }
  }

  Future<void> _confirmDelete(BuildContext context, DownloadedVideo d) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this video?'),
        content: Text('${d.title}\n\nIt is deleted from this phone (${formatBytes(d.size)}). You can download it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) await video.deleteSaved(d);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved videos')),
      body: ListenableBuilder(
        listenable: video,
        builder: (context, _) {
          final tasks = video.tasks.where((t) => t.phase != DownloadPhase.done).toList();
          if (video.saved.isEmpty && tasks.isEmpty) {
            return const Notice('Nothing saved yet. Open a video and choose Download to watch it without a connection.');
          }
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (final t in tasks) _task(context, t),
              if (video.saved.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                  child: Text('${video.saved.length} saved · ${formatBytes(video.savedBytes)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.secondary)),
                ),
              for (final d in video.saved)
                VideoTile(
                  onTap: () => _play(context, d),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                    child: Row(
                      children: [
                        VideoThumb(path: d.thumbnailPath, durationS: d.durationS, width: 110, audio: d.isAudio),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                              const SizedBox(height: 4),
                              Text('${d.isAudio ? 'Audio only' : d.resolutionLabel} · ${formatBytes(d.size)}', style: TextStyle(fontSize: 14, color: k.secondary)),
                              if (d.channelName.isNotEmpty) Text(d.channelName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
                            ],
                          ),
                        ),
                        IconButton(tooltip: 'Delete', icon: Icon(Icons.delete_outline, color: k.secondary), onPressed: () => _confirmDelete(context, d)),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _task(BuildContext context, DownloadTask t) {
    final k = context.t;
    final failed = t.phase == DownloadPhase.failed;
    return VideoTile(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 4),
            if (t.isActive) ...[
              LinearProgressIndicator(value: t.fraction),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: Text(t.total > 0 ? '${t.label} · ${formatBytes(t.done)} of ${formatBytes(t.total)}' : '${t.label} · starting…', style: TextStyle(fontSize: 14, color: k.secondary))),
                TextButton(onPressed: () => video.cancel(t), child: const Text('Stop')),
              ]),
            ] else
              Row(children: [
                Expanded(child: Text(failed ? (t.error ?? 'The download failed.') : 'Stopped', style: TextStyle(fontSize: 14, color: failed ? k.emergency : k.secondary))),
                if (t.blockedByMobile)
                  TextButton(key: const ValueKey('download-anyway'), onPressed: () => video.retry(t, anyway: true), child: const Text('Download anyway'))
                else
                  TextButton(onPressed: () => video.retry(t), child: const Text('Continue')),
                IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close), onPressed: () => video.dismiss(t)),
              ]),
          ],
        ),
      ),
    );
  }
}

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import 'video_dl.dart';

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
        content: Text('${d.title}\n\nIt is deleted from this device (${formatBytes(d.size)}). You can download it again later.'),
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

  Widget _task(BuildContext context, DownloadTask t) => DownloadRow(
        key: ValueKey('video-task-${t.key}'),
        keyBase: 'video-${t.uuid}',
        title: t.title,
        subtitle: t.label,
        state: videoDl(t),
        actions: videoActions(video, t),
      );
}

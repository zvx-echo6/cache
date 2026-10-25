import 'package:flutter/material.dart';

import '../theme.dart';
import '../video/format.dart';
import '../video/video_state.dart';
import 'videos/videos_screen.dart';

/// Browse: the places to read and watch. Videos is here today; pages (ZIMs and library items) come in step 3.
class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key, required this.video});

  final VideoState video;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Browse')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          ListenableBuilder(
            listenable: video,
            builder: (context, _) {
              final line = video.unavailable != null
                  ? 'Not available on this device'
                  : video.instances.isEmpty && video.saved.isEmpty
                      ? 'Connect a PeerTube site'
                      : '${video.instances.length} site${video.instances.length == 1 ? '' : 's'} · ${video.saved.length} saved (${formatBytes(video.savedBytes)})';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Material(
                  color: k.surface,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => VideosScreen(video: video))),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 72),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                        child: Row(
                          children: [
                            Icon(Icons.play_circle_outline, color: k.accent, size: 30),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Videos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                                  const SizedBox(height: 2),
                                  Text(line, style: TextStyle(fontSize: 15, color: k.secondary)),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: k.secondary),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
            child: Text('Pages and ZIMs come in step 3', style: TextStyle(fontSize: 15, color: k.secondary)),
          ),
        ],
      ),
    );
  }
}

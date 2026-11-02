import 'package:flutter/material.dart';

import '../../video/video_state.dart';
import 'videos_screen.dart';

/// Settings > Storage > Videos: the videos on this device and the downloads in progress, as Videos shows them (without the video
/// sites). A video opens its page, where it plays and is deleted.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.video});

  final VideoState video;

  @override
  Widget build(BuildContext context) => VideosScreen(video: video, showSites: false, title: 'Saved videos');
}

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../video/video_state.dart';
import 'video_list.dart';

/// The videos of one channel.
class ChannelScreen extends StatelessWidget {
  const ChannelScreen({super.key, required this.video, required this.instance, required this.channel});

  final VideoState video;
  final VideoInstance instance;
  final VideoChannel channel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(channel.displayName)),
      body: VideoList(
        video: video,
        instance: instance,
        load: (start) => video.list(instance.id, channel: channel.handle, start: start),
        empty: 'This channel has no videos',
      ),
    );
  }
}

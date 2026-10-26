import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/video_state.dart';
import 'video_screen.dart';
import 'widgets.dart';

typedef PageLoader = Future<VideoPage> Function(int start);

/// A list of videos loaded a page at a time from [load]. Reloads when [loadKey] changes.
class VideoList extends StatefulWidget {
  const VideoList({super.key, required this.video, required this.instance, required this.load, this.loadKey = '', this.empty = 'No videos'});

  final VideoState video;
  final VideoInstance instance;
  final PageLoader load;
  final Object loadKey;
  final String empty;

  @override
  State<VideoList> createState() => _VideoListState();
}

class _VideoListState extends State<VideoList> {
  final List<VideoItem> _items = [];
  int _total = 0;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void didUpdateWidget(VideoList old) {
    super.didUpdateWidget(old);
    if (old.loadKey != widget.loadKey) {
      _items.clear();
      _total = 0;
      _error = null;
      _more();
    }
  }

  Future<void> _more() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final key = widget.loadKey;
    try {
      final p = await widget.load(_items.length);
      if (!mounted || key != widget.loadKey) return;
      setState(() {
        _items.addAll(p.videos);
        _total = p.total;
      });
    } catch (e) {
      if (mounted && key == widget.loadKey) setState(() => _error = videoErrorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    if (_items.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) return Notice(_error!, error: true, action: _more);
      return Notice(widget.empty);
    }
    final more = _items.length < _total;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i == _items.length) {
          if (_error != null) return Padding(padding: const EdgeInsets.all(8), child: Notice(_error!, error: true, action: _more));
          if (!more) return const SizedBox(height: 24);
          if (!_loading) WidgetsBinding.instance.addPostFrameCallback((_) => _more());
          return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
        }
        final v = _items[i];
        return VideoTile(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => VideoScreen(video: widget.video, instance: widget.instance, uuid: v.uuid, title: v.title)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VideoThumb(url: v.thumbnail, durationS: v.durationS, width: 130),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                      const SizedBox(height: 4),
                      Text(v.channel.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
                      if (v.downloaded)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(children: [
                            Icon(Icons.download_done, size: 16, color: k.ok),
                            const SizedBox(width: 4),
                            Text('Saved', style: TextStyle(fontSize: 14, color: k.ok)),
                          ]),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/format.dart';
import '../../video/video_state.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// One video: the picture, the details, Play (the saved copy if there is one, else a stream) and Download.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.video, required this.instance, required this.uuid, required this.title});

  final VideoState video;
  final VideoInstance instance;
  final String uuid;
  final String title;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  VideoDetails? _d;
  String? _error;
  bool _expanded = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await widget.video.details(widget.instance.id, widget.uuid);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      // A video that is saved can still be played when the instance cannot be reached.
      if (mounted) setState(() => _error = videoErrorText(e));
    }
  }

  Future<void> _play() async {
    final d = _d;
    setState(() => _opening = true);
    try {
      final saved = widget.video.savedFor(widget.instance.id, widget.uuid);
      final target = await widget.video.resolve(widget.uuid, instance: widget.instance.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(target: target, captionUrls: target.isLocal ? const [] : (d?.captions ?? const []), thumbnail: saved?.thumbnailPath),
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(videoErrorText(e))));
    }
    if (mounted) setState(() => _opening = false);
  }

  Future<void> _download(VideoDetails d) async {
    final choice = await showModalBottomSheet<VideoOption>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.t.surface,
      builder: (ctx) => _ChoiceSheet(d: d),
    );
    if (choice == null) return;
    try {
      await widget.video.download(d, choice);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(videoErrorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final d = _d;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListenableBuilder(
        listenable: widget.video,
        builder: (context, _) {
          final saved = widget.video.savedFor(widget.instance.id, widget.uuid);
          if (d == null) {
            if (_error != null) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Notice(_error!, error: true, action: _load),
                  if (saved != null) FilledButton.icon(onPressed: _play, icon: const Icon(Icons.play_arrow), label: const Text('Play the saved copy')),
                ],
              );
            }
            return const Center(child: CircularProgressIndicator());
          }
          final task = widget.video.taskFor(d.instance, d.uuid);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              GestureDetector(
                onTap: _opening ? null : _play,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoThumb(url: d.preview ?? d.thumbnail, fallbackUrl: d.thumbnail, path: saved?.thumbnailPath, durationS: d.durationS, width: MediaQuery.sizeOf(context).width - 32),
                    DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                      child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.play_arrow, size: 44, color: Colors.white)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(d.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 4),
              Text(
                [d.channel.displayName, formatDuration(d.durationS), if (d.publishedAt != null && d.publishedAt!.length >= 10) d.publishedAt!.substring(0, 10)].join(' · '),
                style: TextStyle(fontSize: 15, color: k.secondary),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _opening || (!d.canStream && saved == null) ? null : _play,
                icon: const Icon(Icons.play_arrow),
                label: Text(saved != null ? 'Play saved copy' : (d.canStream ? 'Play' : 'Not playable')),
              ),
              const SizedBox(height: 10),
              _downloadArea(context, d, saved, task),
              if ((d.description ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(d.description!.trim(), maxLines: _expanded ? null : 4, overflow: _expanded ? null : TextOverflow.ellipsis, style: TextStyle(fontSize: 16, height: 1.4, color: k.text)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => setState(() => _expanded = !_expanded), child: Text(_expanded ? 'Show less' : 'Show more')),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _downloadArea(BuildContext context, VideoDetails d, DownloadedVideo? saved, DownloadTask? task) {
    final k = context.t;
    if (task != null && task.isActive) {
      return _Progress(video: widget.video, task: task);
    }
    if (task != null && (task.phase == DownloadPhase.failed || task.phase == DownloadPhase.cancelled)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(task.phase == DownloadPhase.cancelled ? 'Download stopped.' : (task.error ?? 'The download failed.'), style: TextStyle(fontSize: 15, color: task.phase == DownloadPhase.failed ? k.emergency : k.secondary)),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () => widget.video.retry(task), icon: const Icon(Icons.refresh), label: const Text('Continue download')),
        ],
      );
    }
    if (saved != null) {
      return Row(
        children: [
          Icon(Icons.download_done, color: k.ok),
          const SizedBox(width: 8),
          Expanded(child: Text('Saved on this phone · ${saved.resolutionLabel} · ${formatBytes(saved.size)}', style: TextStyle(fontSize: 15, color: k.ok))),
          TextButton(onPressed: () => widget.video.deleteSaved(saved), child: const Text('Delete')),
        ],
      );
    }
    if (d.isLive) return Text("A live stream can't be saved.", style: TextStyle(fontSize: 15, color: k.secondary));
    if (!d.downloadEnabled) {
      return Text("${widget.instance.name} doesn't allow downloading this video. You can still watch it online.", style: TextStyle(fontSize: 15, color: k.secondary));
    }
    if (d.options.isEmpty) return Text('This video has no file to download yet.', style: TextStyle(fontSize: 15, color: k.secondary));
    return OutlinedButton.icon(onPressed: () => _download(d), icon: const Icon(Icons.download), label: const Text('Download'));
  }
}

/// The sizes of every choice, to pick one before anything is downloaded.
class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({required this.d});

  final VideoDetails d;

  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  late VideoOption _picked;

  @override
  void initState() {
    super.initState();
    // The smallest video choice by default: the point of choosing is to save space.
    final video = widget.d.options.where((o) => !o.isAudio).toList();
    _picked = video.isNotEmpty ? video.last : widget.d.options.first;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Download', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 4),
            Text('Smaller sizes save space on the phone.', style: TextStyle(fontSize: 14, color: k.secondary)),
            const SizedBox(height: 8),
            RadioGroup<VideoOption>(
              groupValue: _picked,
              onChanged: (o) => setState(() => _picked = o ?? _picked),
              child: Column(
                children: [
                  for (final o in widget.d.options)
                    RadioListTile<VideoOption>(
                      value: o,
                      title: Text(o.isAudio ? 'Audio only' : o.label, style: TextStyle(fontSize: 17, color: k.text)),
                      secondary: Text(o.size == null ? '' : formatBytes(o.size!), style: TextStyle(fontSize: 16, color: k.secondary)),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: () => Navigator.pop(context, _picked), child: Text('Download ${optionLine(_picked)}')),
          ],
        ),
      ),
    );
  }
}

/// A running download: bar, size, Stop.
class _Progress extends StatelessWidget {
  const _Progress({required this.video, required this.task});

  final VideoState video;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: task.fraction),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                task.total > 0 ? 'Downloading ${task.label} · ${formatBytes(task.done)} of ${formatBytes(task.total)}' : 'Downloading ${task.label}…',
                style: TextStyle(fontSize: 15, color: k.secondary),
              ),
            ),
            TextButton(onPressed: () => video.cancel(task), child: const Text('Stop')),
          ],
        ),
      ],
    );
  }
}

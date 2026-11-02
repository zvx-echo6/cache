import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import '../../settings/space.dart';
import '../download_confirm.dart' show openStorageForSpace;
import '../../theme.dart';
import '../../video/captions.dart';
import '../../video/format.dart';
import '../../video/video_state.dart';
import 'video_dl.dart';
import 'video_nav.dart';
import 'widgets.dart';

/// One video: the picture (the one way to play it: the saved copy if there is one, else a stream), its details, where it is
/// (on this device, downloading, or not), its captions, and Download or Delete. A saved video shows from its own record with
/// no connection; the site's page fills in when it can be reached.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.video, required this.instanceId, required this.uuid, required this.title});

  final VideoState video;

  /// The video site's id (its host).
  final String instanceId;
  final String uuid;
  final String title;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  VideoDetails? _d;
  String? _error;
  bool _loading = false;
  bool _expanded = false;
  bool _opening = false;
  String? _captionsError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.video.instanceById(widget.instanceId) == null) {
      // A saved video whose site was removed shows from its own record.
      if (_saved == null) setState(() => _error = 'This video site is not on your list.');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final d = await widget.video.details(widget.instanceId, widget.uuid);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      // A saved video still plays and shows from its own record when the site cannot be reached.
      if (mounted) setState(() => _error = videoErrorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DownloadedVideo? get _saved => widget.video.savedFor(widget.instanceId, widget.uuid);

  Future<void> _play() async {
    setState(() => _opening = true);
    try {
      await playVideo(
        context,
        widget.video,
        video: widget.uuid,
        instance: widget.instanceId,
        captionUrls: _d?.captions ?? const [],
        channel: _d?.channel.displayName,
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
      isScrollControlled: true,
      backgroundColor: context.t.surface,
      builder: (ctx) => DownloadSheet(d: d, space: widget.video.space),
    );
    if (choice == null) return;
    try {
      await widget.video.download(d, choice);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(videoErrorText(e))));
    }
  }

  Future<void> _delete(DownloadedVideo saved) async {
    if (!await confirmDeleteVideo(context, bytes: saved.size)) return;
    try {
      await widget.video.deleteSaved(saved);
      // With the site's page not loaded (no connection, or the site removed) nothing is left to show.
      if (_d == null && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(videoErrorText(e))));
    }
  }

  Future<void> _fetchCaptions(DownloadedVideo saved) async {
    setState(() => _captionsError = null);
    final err = await widget.video.fetchMissingCaptions(saved);
    if (mounted) setState(() => _captionsError = err);
  }

  /// Why the picture cannot play, or null when it can.
  String? _cannotPlay(VideoDetails? d, DownloadedVideo? saved) {
    if (saved != null) return null;
    if (d == null) return _loading ? null : (_error ?? '');
    if (d.isLive) return "A live stream can't be played here.";
    if (d.needsAuth && widget.video.userOf(d.instance) == null) return 'This video needs you to log in to the site.';
    if (!d.canStream) return 'This video has no stream to play yet.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListenableBuilder(
        listenable: widget.video,
        builder: (context, _) {
          final saved = _saved;
          final d = _d;
          if (d == null && saved == null) {
            if (_error != null) return Notice(_error!, error: true, action: _load);
            return const Center(child: CircularProgressIndicator());
          }
          final task = widget.video.taskFor(widget.instanceId, widget.uuid);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: LayoutBuilder(builder: (context, box) => _page(context, box.maxWidth, d, saved, task)),
            ),
          );
        },
      ),
    );
  }

  Widget _page(BuildContext context, double width, VideoDetails? d, DownloadedVideo? saved, DownloadTask? task) {
    final k = context.t;
    final why = _cannotPlay(d, saved);
    final title = d?.title ?? saved?.title ?? widget.title;
    final channel = d?.channel.displayName ?? saved?.channelName ?? '';
    final duration = d?.durationS ?? saved?.durationS ?? 0;
    final published = d?.publishedAt ?? saved?.publishedAt;
    final description = (d?.description ?? saved?.description ?? '').trim();
    final captionNames = saved != null
        ? [for (final c in saved.captions) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic).name]
        : [for (final c in d?.captions ?? const <VideoCaptionInfo>[]) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic).name];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Semantics(
          button: why == null,
          label: why == null ? 'Play $title' : null,
          child: GestureDetector(
            key: const ValueKey('video-picture'),
            onTap: _opening || why != null ? null : _play,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoThumb(url: d?.preview ?? d?.thumbnail, fallbackUrl: d?.thumbnail, path: saved?.thumbnailPath, durationS: duration, width: width - 32, audio: saved?.isAudio ?? false),
                if (why == null)
                  DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: _opening
                          ? const SizedBox(width: 44, height: 44, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(color: Colors.white)))
                          : const Icon(Icons.play_arrow, size: 44, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (why != null && why.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(why, style: TextStyle(fontSize: 15, color: k.secondary))),
        const SizedBox(height: 14),
        Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
        const SizedBox(height: 4),
        Text(
          [if (channel.isNotEmpty) channel, if (duration > 0) formatDuration(duration), if (published != null && published.length >= 10) formatDay(published)].join(' · '),
          style: TextStyle(fontSize: 15, color: k.secondary),
        ),
        const SizedBox(height: 14),
        _where(context, d, saved, task),
        if (captionNames.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Captions: ${captionLanguages(captionNames)}', key: const ValueKey('video-captions-line'), style: TextStyle(fontSize: 15, color: k.text)),
        ],
        if (saved != null && saved.missingCaptions.isNotEmpty) _missingCaptions(context, saved),
        const SizedBox(height: 14),
        if (saved != null && (task == null || !task.isActive))
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('video-delete'),
              onPressed: () => _delete(saved),
              icon: Icon(Icons.delete_outline, color: k.emergency),
              label: Text('Delete from this device', style: TextStyle(color: k.emergency)),
            ),
          )
        else if (saved == null && (task == null || task.phase == DownloadPhase.done) && d != null)
          _downloadControl(context, d),
        if (saved != null && d == null && _error != null && !_loading)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(fontSize: 14, color: k.secondary))),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 18),
          LayoutBuilder(builder: (context, box) {
            final style = TextStyle(fontSize: 16, height: 1.4, color: k.text);
            final tp = TextPainter(text: TextSpan(text: description, style: style), maxLines: 3, textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))
              ..layout(maxWidth: box.maxWidth);
            final long = tp.didExceedMaxLines;
            tp.dispose();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description, maxLines: _expanded ? null : 3, overflow: _expanded ? null : TextOverflow.ellipsis, style: style),
                if (long)
                  TextButton(
                    key: const ValueKey('video-more'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? 'Less' : 'More'),
                  ),
              ],
            );
          }),
        ],
      ],
    );
  }

  /// One line for where the video is: on this device (with its size), downloading (the download row's status and control), or not.
  Widget _where(BuildContext context, VideoDetails? d, DownloadedVideo? saved, DownloadTask? task) {
    final k = context.t;
    if (task != null && task.phase != DownloadPhase.done) {
      final s = videoDl(task);
      final a = videoActions(widget.video, task);
      return Row(
        children: [
          Expanded(child: DlStatus(state: s, actions: a, keyBase: 'video-${task.uuid}')),
          const SizedBox(width: 8),
          dlControl(context, s, a, keyBase: 'video-${task.uuid}'),
        ],
      );
    }
    if (saved != null) {
      return Row(
        children: [
          Icon(Icons.download_done, size: 20, color: k.ok),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'On this device · ${saved.isAudio ? 'Audio only' : saved.resolutionLabel} · ${formatBytes(saved.size)}',
              key: const ValueKey('video-where'),
              style: TextStyle(fontSize: 15, color: k.text),
            ),
          ),
        ],
      );
    }
    return Text('Not on this device', key: const ValueKey('video-where'), style: TextStyle(fontSize: 15, color: k.secondary));
  }

  /// "Spanish captions did not save." and Try again, which fetches only the missing captions.
  Widget _missingCaptions(BuildContext context, DownloadedVideo saved) {
    final k = context.t;
    final busy = widget.video.fetchingCaptions.contains('${saved.instance}/${saved.uuid}');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: k.warning),
              const SizedBox(width: 6),
              Expanded(child: Text(missingCaptionsLine(saved), key: const ValueKey('video-missing-captions'), style: TextStyle(fontSize: 15, color: k.text))),
              busy
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)))
                  : TextButton(key: const ValueKey('video-captions-retry'), onPressed: () => _fetchCaptions(saved), child: const Text('Try again')),
            ],
          ),
          if (_captionsError != null) Text(_captionsError!, style: TextStyle(fontSize: 14, color: k.emergency)),
        ],
      ),
    );
  }

  Widget _downloadControl(BuildContext context, VideoDetails d) {
    final k = context.t;
    if (d.isLive) return Text("A live stream can't be saved.", style: TextStyle(fontSize: 15, color: k.secondary));
    final site = widget.video.instanceById(widget.instanceId)?.name ?? 'This site';
    if (!d.downloadEnabled) {
      return Text("$site doesn't allow downloading this video. You can still watch it online.", style: TextStyle(fontSize: 15, color: k.secondary));
    }
    if (d.options.isEmpty) return Text('This video has no file to download yet.', style: TextStyle(fontSize: 15, color: k.secondary));
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(key: const ValueKey('video-download'), onPressed: () => _download(d), icon: const Icon(Icons.download), label: const Text('Download')),
    );
  }
}

/// "14 Mar 2026" for an ISO date.
String formatDay(String iso) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final t = DateTime.tryParse(iso);
  if (t == null) return iso.length >= 10 ? iso.substring(0, 10) : iso;
  return '${t.day} ${months[t.month - 1]} ${t.year}';
}

/// The download choice, with the sizes of every choice before anything is downloaded, what captions come with it, and whether
/// it fits on this device.
class DownloadSheet extends StatefulWidget {
  const DownloadSheet({super.key, required this.d, this.space});

  final VideoDetails d;

  /// The storage the video goes to; null: not known (it is not checked).
  final Space? space;

  @override
  State<DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<DownloadSheet> {
  late VideoOption _picked;

  @override
  void initState() {
    super.initState();
    // The smallest video choice by default: the point of choosing is to save space.
    final video = widget.d.options.where((o) => !o.isAudio).toList();
    _picked = video.isNotEmpty ? video.last : widget.d.options.first;
  }

  /// "Best 720p", "Smaller 360p", "Audio only".
  String _name(VideoOption o) {
    if (o.isAudio) return 'Audio only';
    final best = widget.d.options.firstWhere((x) => !x.isAudio);
    return identical(o, best) || o.key == best.key ? 'Best ${o.label}' : 'Smaller ${o.label}';
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final caps = [for (final c in widget.d.captions) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic).name];
    final short = widget.space?.shortBy(_picked.size ?? 0) ?? 0;
    final storage = openStorageForSpace;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Download', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 4),
            Text('Smaller sizes use less space on this device.', style: TextStyle(fontSize: 15, color: k.secondary)),
            const SizedBox(height: 8),
            RadioGroup<VideoOption>(
              groupValue: _picked,
              onChanged: (o) => setState(() => _picked = o ?? _picked),
              child: Column(
                children: [
                  for (final o in widget.d.options)
                    RadioListTile<VideoOption>(
                      key: ValueKey('video-option-${o.key}'),
                      value: o,
                      title: Text(_name(o), style: TextStyle(fontSize: 17, color: k.text)),
                      secondary: Text(o.size == null ? '' : formatBytes(o.size!), style: TextStyle(fontSize: 16, color: k.secondary)),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              caps.isEmpty ? 'This video has no captions.' : 'Captions come with it: ${captionLanguages(caps)}.',
              key: const ValueKey('video-sheet-captions'),
              style: TextStyle(fontSize: 15, color: k.text),
            ),
            const SizedBox(height: 12),
            if (short > 0) ...[
              Text('Not enough room on this device.', key: const ValueKey('video-sheet-no-room'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.emergency)),
              const SizedBox(height: 8),
              if (storage != null)
                OutlinedButton(
                  key: const ValueKey('video-sheet-storage'),
                  onPressed: () {
                    final nav = Navigator.of(context);
                    nav.pop();
                    storage(nav.context);
                  },
                  child: const Text('Open Storage'),
                ),
            ] else
              FilledButton(key: const ValueKey('video-sheet-download'), onPressed: () => Navigator.pop(context, _picked), child: Text('Download ${optionLine(_picked)}')),
          ],
        ),
      ),
    );
  }
}

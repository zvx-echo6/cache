import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme.dart';
import '../../video/format.dart';
import 'widgets.dart';

/// Plays a [VideoTarget]: a saved file (no network) or a stream, starting at the target's offset. Captions come
/// from the saved VTT files, or from [captionUrls] when streaming.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.target, this.captionUrls = const [], this.thumbnail, this.controllerFactory});

  final VideoTarget target;

  /// For a stream: the video's captions (language label and address).
  final List<VideoCaptionInfo> captionUrls;
  final String? thumbnail;

  /// Test hook: builds the controller.
  final VideoPlayerController Function(VideoTarget target)? controllerFactory;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _c;
  String? _error;
  bool _captionsOn = false;
  String? _captionLabel;
  bool _dragging = false;
  double _dragValue = 0;

  VideoTarget get t => widget.target;

  @override
  void initState() {
    super.initState();
    _start();
  }

  VideoPlayerController _make() {
    if (widget.controllerFactory != null) return widget.controllerFactory!(t);
    return t.isLocal ? VideoPlayerController.file(File(t.location)) : VideoPlayerController.networkUrl(Uri.parse(t.location));
  }

  Future<void> _start() async {
    final c = _make();
    _c = c;
    c.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      await c.initialize();
      if (t.offsetS > 0) await c.seekTo(Duration(milliseconds: (t.offsetS * 1000).round()));
      await c.play();
      await _pickCaptions(on: false);
    } catch (e) {
      if (mounted) setState(() => _error = t.isLocal ? "This file can't be played." : "Can't play this video right now. Check the connection.");
    }
    if (mounted) setState(() {});
  }

  /// The first caption track (saved file, or fetched address), as WebVTT.
  Future<ClosedCaptionFile?> _loadCaption() async {
    try {
      if (t.isLocal && t.captions.isNotEmpty) {
        _captionLabel = t.captions.first.label;
        return WebVTTCaptionFile(await File(t.captions.first.path).readAsString());
      }
      if (!t.isLocal && widget.captionUrls.isNotEmpty) {
        _captionLabel = widget.captionUrls.first.label;
        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(widget.captionUrls.first.url));
          final res = await req.close();
          final body = await res.transform(const SystemEncoding().decoder).join();
          return WebVTTCaptionFile(body);
        } finally {
          client.close();
        }
      }
    } catch (_) {}
    return null;
  }

  bool get _hasCaptions => t.isLocal ? t.captions.isNotEmpty : widget.captionUrls.isNotEmpty;

  Future<void> _pickCaptions({required bool on}) async {
    if (!_hasCaptions || _c == null) return;
    if (on) {
      final f = await _loadCaption();
      if (f == null) return;
      await _c!.setClosedCaptionFile(Future.value(f));
    }
    if (mounted) setState(() => _captionsOn = on);
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _skip(int seconds) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final to = c.value.position + Duration(seconds: seconds);
    final max = c.value.duration;
    await c.seekTo(to < Duration.zero ? Duration.zero : (to > max ? max : to));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    final error = _error ?? (c != null && c.value.hasError ? "This video can't be played." : null);
    return Scaffold(
      appBar: AppBar(title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: error != null
          ? Notice(error, error: true)
          : Column(
              children: [
                Container(
                  color: Colors.black,
                  width: double.infinity,
                  // tall (vertical) video must leave room for the controls below
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
                  alignment: Alignment.center,
                  child: AspectRatio(
                    aspectRatio: ready && !t.isAudio ? c.value.aspectRatio : 16 / 9,
                    child: !ready
                        ? const Center(child: CircularProgressIndicator())
                        : t.isAudio
                            ? Stack(fit: StackFit.expand, children: [
                                if (widget.thumbnail != null) Opacity(opacity: 0.4, child: VideoThumb(path: widget.thumbnail, width: 400)),
                                const Center(child: Icon(Icons.music_note, size: 72, color: Colors.white70)),
                                Offstage(child: VideoPlayer(c)),
                              ])
                            : VideoPlayer(c),
                  ),
                ),
                if (ready && _captionsOn && c.value.caption.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Text(c.value.caption.text, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: k.text)),
                  ),
                if (ready) _controls(context, c),
                if (!t.isLocal)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text('Streaming', style: TextStyle(fontSize: 14, color: k.secondary)),
                  ),
              ],
            ),
    );
  }

  Widget _controls(BuildContext context, VideoPlayerController c) {
    final k = context.t;
    final dur = c.value.duration.inMilliseconds.toDouble();
    final pos = _dragging ? _dragValue : c.value.position.inMilliseconds.clamp(0, dur.toInt()).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              Text(formatDuration(pos / 1000), style: TextStyle(fontSize: 14, color: k.secondary)),
              Expanded(
                child: Slider(
                  value: dur <= 0 ? 0 : pos,
                  max: dur <= 0 ? 1 : dur,
                  onChangeStart: (_) => _dragging = true,
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) async {
                    await c.seekTo(Duration(milliseconds: v.round()));
                    if (mounted) setState(() => _dragging = false);
                  },
                ),
              ),
              Text(formatDuration(dur / 1000), style: TextStyle(fontSize: 14, color: k.secondary)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(iconSize: 32, tooltip: 'Back 10 seconds', icon: const Icon(Icons.replay_10), onPressed: () => _skip(-10)),
              const SizedBox(width: 8),
              IconButton.filled(
                iconSize: 40,
                tooltip: c.value.isPlaying ? 'Pause' : 'Play',
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
              ),
              const SizedBox(width: 8),
              IconButton(iconSize: 32, tooltip: 'Forward 10 seconds', icon: const Icon(Icons.forward_10), onPressed: () => _skip(10)),
              if (_hasCaptions) ...[
                const SizedBox(width: 8),
                IconButton(
                  iconSize: 30,
                  tooltip: _captionsOn ? 'Hide captions' : 'Show captions${_captionLabel == null ? '' : ' ($_captionLabel)'}',
                  icon: Icon(_captionsOn ? Icons.closed_caption : Icons.closed_caption_outlined, color: _captionsOn ? k.accent : k.text),
                  onPressed: () => _pickCaptions(on: !_captionsOn),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

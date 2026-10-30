import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../theme.dart';
import '../../video/format.dart';
import 'widgets.dart';
import '../../net/fetch.dart';

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

  /// True full screen: the video alone, landscape for a wide video, the system bars hidden (immersive); a tap shows the controls.
  bool _full = false;
  bool _overlay = true;
  Timer? _hide;

  /// The playback speeds offered.
  static const List<double> speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];

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
      if (!mounted) return;
      if (t.offsetS > 0) await c.seekTo(Duration(milliseconds: (t.offsetS * 1000).round()));
      if (!mounted) return;
      await c.play();
      if (!mounted) return;
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
        return WebVTTCaptionFile(await fetchText(Uri.parse(widget.captionUrls.first.url), httpsOnly: false));
      }
    } catch (_) {}
    return null;
  }

  bool get _hasCaptions => t.isLocal ? t.captions.isNotEmpty : widget.captionUrls.isNotEmpty;

  Future<void> _pickCaptions({required bool on}) async {
    if (!_hasCaptions || _c == null) return;
    if (on) {
      final f = await _loadCaption();
      if (f == null || !mounted) return;
      await _c!.setClosedCaptionFile(Future.value(f));
    }
    if (mounted) setState(() => _captionsOn = on);
  }

  @override
  void dispose() {
    _hide?.cancel();
    if (_full) _restoreSystem();
    _c?.dispose();
    super.dispose();
  }

  void _setFull(bool on) {
    final c = _c;
    setState(() => _full = on);
    _showOverlay();
    if (on) {
      final wide = c == null || !c.value.isInitialized || c.value.aspectRatio >= 1;
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
      unawaited(SystemChrome.setPreferredOrientations(
        wide ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp],
      ));
    } else {
      unawaited(_restoreSystem());
    }
  }

  static Future<void> _restoreSystem() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
  }

  /// Shows the full-screen controls for a few seconds.
  void _showOverlay() {
    _hide?.cancel();
    if (mounted) setState(() => _overlay = true);
    if (_full) {
      _hide = Timer(const Duration(seconds: 3), () {
        if (mounted && (_c?.value.isPlaying ?? false)) setState(() => _overlay = false);
      });
    }
  }

  Future<void> _pickSpeed() async {
    final c = _c;
    if (c == null) return;
    final v = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final sp in speeds)
              ListTile(
                key: ValueKey('speed-$sp'),
                minTileHeight: 48,
                title: Text(sp == 1 ? 'Normal' : '${sp}x'),
                trailing: c.value.playbackSpeed == sp ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, sp),
              ),
          ],
        ),
      ),
    );
    if (v != null) await c.setPlaybackSpeed(v);
    if (mounted) setState(() {});
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
    if (_full && ready && error == null) return _fullScreen(context, c);
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

  /// The video alone on black; a tap shows or hides the controls; Back leaves full screen.
  Widget _fullScreen(BuildContext context, VideoPlayerController c) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _setFull(false);
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        key: const ValueKey('player-full'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _overlay ? setState(() => _overlay = false) : _showOverlay(),
        child: Stack(
          children: [
            Center(child: AspectRatio(aspectRatio: t.isAudio ? 16 / 9 : c.value.aspectRatio, child: VideoPlayer(c))),
            if (_captionsOn && c.value.caption.text.isNotEmpty)
              Positioned(
                left: 24,
                right: 24,
                bottom: _overlay ? 140 : 32,
                child: Text(
                  c.value.caption.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                ),
              ),
            if (_overlay)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  child: SafeArea(top: false, child: Theme(data: ThemeData.dark(), child: _controls(context, c))),
                ),
              ),
          ],
        ),
      ),
    ),
  );

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
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('player-speed'),
                onPressed: _pickSpeed,
                child: Text(c.value.playbackSpeed == 1 ? '1x' : '${c.value.playbackSpeed}x', style: const TextStyle(fontSize: 15)),
              ),
              if (!t.isAudio)
                IconButton(
                  key: const ValueKey('player-fullscreen'),
                  iconSize: 30,
                  tooltip: _full ? 'Leave full screen' : 'Full screen',
                  icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen),
                  onPressed: () => _setFull(!_full),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

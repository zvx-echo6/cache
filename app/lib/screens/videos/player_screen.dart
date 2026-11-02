import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../layout/adaptive.dart';
import '../../theme.dart';
import '../../video/captions.dart';
import '../../video/format.dart';
import '../../video/video_prefs.dart';
import 'widgets.dart';

/// From this window width (and [kTranscriptMinHeight] tall) the transcript sits beside the video (UX-video-30 2.6).
const double kTranscriptMinWidth = 900;

/// The transcript pane at least.
const double kTranscriptPaneWidth = 320;

/// A window shorter than this has no room for the transcript beside the video: it opens from the Captions sheet instead.
const double kTranscriptMinHeight = 600;

/// How long "Resumed at 3:42. Start over" stays.
const Duration kResumedNotice = Duration(seconds: 5);

/// Plays a [VideoTarget]: a saved file (no network), a ZIM's video entry, or a stream. Captions come from the saved files or
/// from [captionUrls] when streaming: on a phone they show across the bottom of the picture (on or off; a choice of language
/// when there is more than one), on a wide window the transcript sits beside the video, follows playback and seeks on a tap.
/// It starts where the video was left ([prefs]) unless [cited]: then it opens at the cited cue, marked "Match".
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.target,
    this.captionUrls = const [],
    this.thumbnail,
    this.controllerFactory,
    this.prefs,
    this.channel,
    this.where,
    this.cited = false,
    this.onPlaySaved,
    this.onRedownload,
    this.mobileOverride,
    this.frame,
  });

  final VideoTarget target;

  /// For a stream: the video's captions (language label and address).
  final List<VideoCaptionInfo> captionUrls;
  final String? thumbnail;

  /// Test hook: builds the controller.
  final VideoPlayerController Function(VideoTarget target)? controllerFactory;

  /// Where videos were left and the captions choice; null: nothing is remembered.
  final VideoPrefs? prefs;

  /// The channel (or "In Wikipedia" for a ZIM's video) for the line under the title.
  final String? channel;

  /// "On this device" or "Streaming" in place of the default for the target.
  final String? where;

  /// Opened from a citation: [VideoTarget.offsetS] is the cited moment, and its cue is marked.
  final bool cited;

  /// A stream that cannot play while a saved copy exists: "Saved copy" opens it.
  final VoidCallback? onPlaySaved;

  /// A saved file that cannot play: "Delete it and download again".
  final VoidCallback? onRedownload;

  /// Test hook: behave as a phone or tablet (turning sideways enters full screen) or not. Null: by the platform.
  final bool? mobileOverride;

  /// Test hook for pictures: drawn in place of the video's frames.
  final Widget? frame;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _c;
  String? _error;
  bool _dragging = false;
  double _dragValue = 0;

  /// True full screen: the video alone, landscape for a wide video, the system bars hidden (immersive); a tap shows the controls.
  bool _full = false;
  bool _overlay = true;
  Timer? _hide;

  /// The caption tracks this video has, and the cues of the ones read so far.
  late final List<CaptionTrack> _tracks = _tracksOf();
  final Map<int, List<Cue>> _cues = {};

  /// The track shown on the picture; null: captions off.
  int? _on;

  /// The cue of a cited moment, marked "Match" until another line is tapped or the video moves past it.
  int? _match;

  /// "Resumed at 3:42. Start over" while set.
  Duration? _resumedAt;
  Timer? _resumedTimer;
  Timer? _keep;

  /// Playback began (from here on the place is kept).
  bool _started = false;
  int _lastCue = -1;
  final Map<int, GlobalKey> _cueKeys = {};
  final FocusNode _focus = FocusNode(debugLabel: 'player');

  /// The playback speeds offered.
  static const List<double> speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];

  VideoTarget get t => widget.target;
  String get _key => VideoPrefs.keyOf(instance: t.instance, uuid: t.uuid);

  List<CaptionTrack> _tracksOf() => t.isLocal
      ? [for (final c in t.captions) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic, path: c.path)]
      : [for (final c in widget.captionUrls) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic, url: c.url)];

  bool get _hasCaptions => _tracks.isNotEmpty;

  /// The track the transcript shows: the captions choice, else the first.
  int get _shown => _on ?? 0;

  bool get _mobile => widget.mobileOverride ?? (Platform.isAndroid || Platform.isIOS);

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
    c.addListener(_tick);
    try {
      await c.initialize();
      if (!mounted) return;
      await _chooseInitialCaptions();
      if (!mounted) return;
      final dur = c.value.duration;
      Duration? at;
      if (widget.cited && t.offsetS > 0) {
        at = Duration(milliseconds: (t.offsetS * 1000).round());
        final cues = _hasCaptions ? await _cuesOf(_shown) : const <Cue>[];
        final i = citedCue(cues, at);
        if (i >= 0 && (cues[i].start - at).abs() < const Duration(seconds: 5)) {
          _match = i;
          at = cues[i].start;
        }
      } else if (t.offsetS > 0) {
        at = Duration(milliseconds: (t.offsetS * 1000).round());
      } else {
        final p = widget.prefs?.positionOf(_key);
        if (p != null && (dur <= Duration.zero || p < dur - VideoPrefs.endMargin)) {
          at = p;
          _resumedAt = p;
          _resumedTimer = Timer(kResumedNotice, () {
            if (mounted) setState(() => _resumedAt = null);
          });
        }
      }
      if (!mounted) return;
      if (at != null && at > Duration.zero) await c.seekTo(at);
      if (!mounted) return;
      await c.play();
      _started = true;
      _keep = Timer.periodic(const Duration(seconds: 5), (_) => _remember());
    } catch (e) {
      if (mounted) setState(() => _error = t.isLocal ? "This file can't be played." : "This video can't be played.");
    }
    if (mounted) {
      setState(() {});
      if (_match != null) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_match!, animate: false));
    }
  }

  /// Captions start as last chosen on this device (off the first time). A citation shows them, on a phone, so the cited line is
  /// on the picture; that does not change the choice kept.
  Future<void> _chooseInitialCaptions() async {
    if (!_hasCaptions) return;
    final kept = widget.prefs?.captions;
    int? on;
    if (kept != null && kept != 'off') {
      final i = _tracks.indexWhere((x) => x.language == kept);
      on = i >= 0 ? i : 0;
    }
    if (widget.cited && on == null && !_transcriptBeside(context)) on = 0;
    if (on != null) await _cuesOf(on);
    _on = on;
  }

  Future<List<Cue>> _cuesOf(int track) async {
    final have = _cues[track];
    if (have != null) return have;
    List<Cue> cues;
    try {
      cues = await _tracks[track].load();
    } catch (_) {
      cues = const [];
    }
    _cues[track] = cues;
    return cues;
  }

  void _tick() {
    if (!mounted) return;
    final c = _c!;
    final cues = _cues[_shown];
    if (cues != null) {
      final i = cueAt(cues, c.value.position);
      if (_match != null && c.value.position >= cues[_match!].end) _match = null;
      if (i != _lastCue) {
        _lastCue = i;
        if (i >= 0 && _transcriptBeside(context)) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(i));
      }
    }
    if (!c.value.isPlaying && c.value.isInitialized) _remember();
    setState(() {});
  }

  void _remember() {
    final c = _c;
    final p = widget.prefs;
    if (c == null || p == null || !_started || !c.value.isInitialized || _error != null) return;
    p.setPosition(_key, c.value.position, c.value.duration);
  }

  void _scrollTo(int cue, {bool animate = true}) {
    final ctx = _cueKeys[cue]?.currentContext;
    if (ctx == null || !mounted) return;
    unawaited(Scrollable.ensureVisible(ctx, alignment: 0.5, duration: animate ? const Duration(milliseconds: 250) : Duration.zero));
  }

  @override
  void dispose() {
    _remember();
    _hide?.cancel();
    _keep?.cancel();
    _resumedTimer?.cancel();
    _focus.dispose();
    if (_full) _restoreSystem();
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    final old = _c;
    old?.removeListener(_tick);
    _keep?.cancel();
    setState(() {
      _error = null;
      _c = null;
      _started = false;
    });
    await old?.dispose();
    await _start();
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
                title: Text(sp == 1 ? 'Normal' : '${_speedText(sp)}x'),
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

  static String _speedText(double sp) => sp == sp.roundToDouble() ? sp.toInt().toString() : '$sp';

  /// Turns captions to [track] (null: off) and keeps the choice on this device.
  Future<void> _setCaptions(int? track) async {
    if (track != null) await _cuesOf(track);
    if (!mounted) return;
    setState(() {
      _on = track;
      _lastCue = -1;
    });
    widget.prefs?.captions = track == null ? 'off' : _tracks[track].language;
  }

  /// The Captions control: one language turns on and off; more than one (or a transcript with no room beside the video) opens
  /// the sheet: Off, each language, and Transcript.
  Future<void> _captions() async {
    final hiddenTranscript = !_transcriptBeside(context) && _wide(context);
    if (_tracks.length == 1 && !hiddenTranscript) {
      await _setCaptions(_on == null ? 0 : null);
      return;
    }
    final k = context.t;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('captions-off'),
              minTileHeight: 48,
              title: const Text('Off'),
              trailing: _on == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, -1),
            ),
            for (var i = 0; i < _tracks.length; i++)
              ListTile(
                key: ValueKey('captions-${_tracks[i].language}'),
                minTileHeight: 48,
                title: Text(_tracks[i].name),
                trailing: _on == i ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, i),
              ),
            if (hiddenTranscript) ...[
              Divider(height: 1, color: k.secondary.withValues(alpha: 0.3)),
              ListTile(
                key: const ValueKey('captions-transcript'),
                minTileHeight: 48,
                leading: const Icon(Icons.subject),
                title: const Text('Transcript'),
                onTap: () => Navigator.pop(ctx, -2),
              ),
            ],
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == -2) {
      await _openTranscriptSheet();
    } else {
      await _setCaptions(picked < 0 ? null : picked);
    }
  }

  Future<void> _openTranscriptSheet() async {
    await _cuesOf(_shown);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.8,
        child: ListenableBuilder(listenable: _c!, builder: (context, _) => _transcript(context)),
      ),
    );
  }

  Future<void> _skip(int seconds) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final to = c.value.position + Duration(seconds: seconds);
    final max = c.value.duration;
    await c.seekTo(to < Duration.zero ? Duration.zero : (to > max ? max : to));
  }

  Future<void> _seekToCue(int i) async {
    final cues = _cues[_shown];
    final c = _c;
    if (cues == null || c == null) return;
    setState(() => _match = null);
    await c.seekTo(cues[i].start);
  }

  Future<void> _startOver() async {
    _resumedTimer?.cancel();
    setState(() => _resumedAt = null);
    widget.prefs?.clearPosition(_key);
    await _c?.seekTo(Duration.zero);
  }

  void _playPause() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  static bool _wide(BuildContext context) => MediaQuery.sizeOf(context).width >= kTranscriptMinWidth;

  /// The transcript has its own pane beside the video: a wide, tall enough window and a video with captions.
  bool _transcriptBeside(BuildContext context) =>
      _hasCaptions && _wide(context) && MediaQuery.sizeOf(context).height >= kTranscriptMinHeight;

  /// "Play (Space)" on a desktop window, where the keys work; "Play" elsewhere.
  String _tip(BuildContext context, String words, String key) => isDesktop(context) ? '$words ($key)' : words;

  /// [child] with a tooltip naming its key, on a desktop window only (a labelled button needs none on a phone).
  Widget _keyTip(BuildContext context, String message, Widget child) => isDesktop(context) ? Tooltip(message: message, child: child) : child;

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    final error = _error ?? (c != null && c.value.hasError ? (t.isLocal ? "This file can't be played." : "This video can't be played.") : null);
    // Turning a phone sideways on a wide video goes full screen (the system's rotation; a tablet's wide window has its panes).
    if (!_full && ready && error == null && _mobile && !t.isAudio && c.value.aspectRatio >= 1 && !_wide(context) &&
        MediaQuery.orientationOf(context) == Orientation.landscape) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_full) _setFull(true);
      });
    }
    final Widget page;
    if (_full && ready && error == null) {
      page = _fullScreen(context, c);
    } else {
      page = Scaffold(
        // The title is under the controls with its channel, length and where it plays; the bar has only Back.
        appBar: AppBar(),
        body: error != null ? _errorView(context, error) : _body(context, c, ready),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _playPause,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-5),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(5),
        const SingleActivator(LogicalKeyboardKey.keyF): () {
          if (ready && !t.isAudio) _setFull(!_full);
        },
        const SingleActivator(LogicalKeyboardKey.keyC): () {
          if (_hasCaptions) _captions();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_full) _setFull(false);
        },
      },
      child: Focus(focusNode: _focus, autofocus: true, child: page),
    );
  }

  Widget _errorView(BuildContext context, String error) {
    final k = context.t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: k.emergency)),
            const SizedBox(height: 16),
            if (t.isLocal && widget.onRedownload != null)
              OutlinedButton(key: const ValueKey('player-redownload'), onPressed: widget.onRedownload, child: const Text('Delete it and download again'))
            else
              OutlinedButton(key: const ValueKey('player-retry'), onPressed: _retry, child: const Text('Try again')),
            if (!t.isLocal && widget.onPlaySaved != null) ...[
              const SizedBox(height: 8),
              TextButton(key: const ValueKey('player-saved-copy'), onPressed: widget.onPlaySaved, child: const Text('Saved copy')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, VideoPlayerController? c, bool ready) {
    final beside = _transcriptBeside(context);
    final left = LayoutBuilder(
      builder: (context, box) => ListView(
        padding: EdgeInsets.zero,
        children: [
          ColoredBox(
            color: Colors.black,
            // as tall as the video, and a tall (vertical) video leaves room for the controls below
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * (beside ? 0.62 : 0.55)),
                child: AspectRatio(
              aspectRatio: ready && !t.isAudio ? c!.value.aspectRatio : 16 / 9,
                  child: !ready ? const Center(child: CircularProgressIndicator()) : _picture(context, c!, overlayCaptions: true),
                ),
              ),
            ),
          ),
          if (_resumedAt != null) _resumedBar(context),
          if (ready) _controls(context, c!),
          _info(context),
        ],
      ),
    );
    if (!beside) return left;
    final k = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: left),
        VerticalDivider(width: 1, color: k.secondary.withValues(alpha: 0.25)),
        SizedBox(width: (MediaQuery.sizeOf(context).width * 0.34).clamp(kTranscriptPaneWidth, 480.0), child: _transcript(context)),
      ],
    );
  }

  /// The video (or the sound's picture), with the caption on it at the bottom in a dark band so nothing moves when a cue comes.
  Widget _picture(BuildContext context, VideoPlayerController c, {required bool overlayCaptions, double bottom = 0}) {
    final Widget video = widget.frame ?? VideoPlayer(c);
    final cue = _currentCue(c);
    final k = context.t;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (t.isAudio) ...[
          if (widget.thumbnail != null) Opacity(opacity: 0.4, child: VideoThumb(path: widget.thumbnail, width: 400)),
          const Center(child: Icon(Icons.music_note, size: 72, color: Colors.white70)),
          Offstage(child: video),
        ] else
          video,
        if (overlayCaptions && cue != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 10 + bottom,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cue.$2)
                    Container(
                      key: const ValueKey('caption-match'),
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: k.accent, borderRadius: BorderRadius.circular(6)),
                      child: Text('Match', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.onPrimary)),
                    ),
                  DecoratedBox(
                    key: const ValueKey('caption-band'),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(6),
                      border: cue.$2 ? Border.all(color: k.accent, width: 2) : null,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: Text(cue.$1.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, height: 1.3, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// The cue on the picture now and whether it is the cited one; null when captions are off or nothing is said.
  (Cue, bool)? _currentCue(VideoPlayerController c) {
    final on = _on;
    if (on == null) return null;
    final cues = _cues[on];
    if (cues == null) return null;
    final i = cueAt(cues, c.value.position);
    if (i < 0) return null;
    return (cues[i], _match == i && on == _shown);
  }

  Widget _resumedBar(BuildContext context) {
    final k = context.t;
    return Container(
      key: const ValueKey('player-resumed'),
      color: k.surface,
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(child: Text('Resumed at ${formatDuration(_resumedAt!.inMilliseconds / 1000)}', style: TextStyle(fontSize: 15, color: k.text))),
          TextButton(key: const ValueKey('player-start-over'), onPressed: _startOver, child: const Text('Start over')),
        ],
      ),
    );
  }

  Widget _info(BuildContext context) {
    final k = context.t;
    final dur = _c != null && _c!.value.isInitialized ? _c!.value.duration.inSeconds : t.durationS;
    final where = widget.where ?? (t.isLocal ? 'On this device' : 'Streaming');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
          const SizedBox(height: 4),
          Text(
            [if ((widget.channel ?? '').isNotEmpty) widget.channel!, if (dur > 0) formatDuration(dur), where].join(' · '),
            style: TextStyle(fontSize: 15, color: k.secondary),
          ),
        ],
      ),
    );
  }

  /// One line per cue with its time; the current one highlighted and kept in view; a tap seeks there. "Match" marks the cited one.
  Widget _transcript(BuildContext context) {
    final k = context.t;
    final cues = _cues[_shown];
    if (cues == null) {
      unawaited(_cuesOf(_shown).then((_) {
        if (mounted) setState(() {});
      }));
      return const Center(child: CircularProgressIndicator());
    }
    final now = _c == null ? -1 : cueAt(cues, _c!.value.position);
    return Column(
      key: const ValueKey('player-transcript'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text(
            'TRANSCRIPT${_tracks.length > 1 ? ' · ${_tracks[_shown].name}' : ''}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: k.secondary),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cues.length; i++) _cueRow(context, cues[i], i, current: i == now, match: i == _match),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _cueRow(BuildContext context, Cue cue, int i, {required bool current, required bool match}) {
    final k = context.t;
    final key = _cueKeys.putIfAbsent(i, GlobalKey.new);
    return Material(
      key: key,
      color: current || match ? k.accent.withValues(alpha: 0.16) : Colors.transparent,
      child: InkWell(
        key: ValueKey('cue-$i'),
        onTap: () => _seekToCue(i),
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: current || match ? k.accent : Colors.transparent, width: 3))),
          padding: const EdgeInsets.fromLTRB(13, 8, 16, 8),
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                child: Text(formatDuration(cue.start.inMilliseconds / 1000), style: TextStyle(fontSize: 14, color: k.secondary)),
              ),
              Expanded(
                child: Text(cue.text, style: TextStyle(fontSize: 16, height: 1.35, color: k.text, fontWeight: current ? FontWeight.w600 : FontWeight.w400)),
              ),
              if (match)
                Container(
                  key: const ValueKey('transcript-match'),
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: k.accent, borderRadius: BorderRadius.circular(6)),
                  child: Text('Match', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.onPrimary)),
                ),
            ],
          ),
        ),
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
            Center(
              child: AspectRatio(
                aspectRatio: t.isAudio ? 16 / 9 : c.value.aspectRatio,
                child: _picture(context, c, overlayCaptions: false),
              ),
            ),
            if (_currentCue(c) case final cue?)
              Positioned(
                left: 24,
                right: 24,
                bottom: _overlay ? 170 : 32,
                child: Center(
                  child: DecoratedBox(
                    key: const ValueKey('caption-band'),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: Text(cue.$1.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, height: 1.3, color: Colors.white)),
                    ),
                  ),
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
    final label = TextStyle(fontSize: 15, color: _full ? Colors.white : k.text);
    final time = TextStyle(fontSize: 14, color: _full ? Colors.white70 : k.secondary);
    final captionWord = _on == null ? 'Off' : _tracks[_on!].name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              Text(formatDuration(pos / 1000), style: time),
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
              Text(formatDuration(dur / 1000), style: time),
              const SizedBox(width: 8),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(iconSize: 32, tooltip: 'Back 10 seconds', icon: const Icon(Icons.replay_10), onPressed: () => _skip(-10)),
              const SizedBox(width: 16),
              IconButton.filled(
                iconSize: 40,
                tooltip: _tip(context, c.value.isPlaying ? 'Pause' : 'Play', 'Space'),
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: _playPause,
              ),
              const SizedBox(width: 16),
              IconButton(iconSize: 32, tooltip: 'Forward 10 seconds', icon: const Icon(Icons.forward_10), onPressed: () => _skip(10)),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            children: [
              if (_hasCaptions)
                _keyTip(
                  context,
                  'Captions (C)',
                  TextButton.icon(
                    key: const ValueKey('player-captions'),
                    onPressed: _captions,
                    icon: Icon(_on == null ? Icons.closed_caption_outlined : Icons.closed_caption, size: 22, color: _on == null ? label.color : k.accent),
                    label: Text('Captions: $captionWord', style: label),
                  ),
                ),
              TextButton(
                key: const ValueKey('player-speed'),
                onPressed: _pickSpeed,
                child: Text('Speed ${_speedText(c.value.playbackSpeed)}x', style: label),
              ),
              if (!t.isAudio)
                _keyTip(
                  context,
                  _full ? 'Leave full screen (Esc)' : 'Full screen (F)',
                  TextButton.icon(
                    key: const ValueKey('player-fullscreen'),
                    onPressed: () => _setFull(!_full),
                    icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen, size: 22, color: label.color),
                    label: Text(_full ? 'Leave full screen' : 'Full screen', style: label),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/system_ui.dart';
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

/// The soft shadow behind every icon and word on the picture, so white stays readable over a bright frame.
const List<Shadow> kOverlayShadows = [Shadow(color: Color(0xA6000000), blurRadius: 6, offset: Offset(0, 1))];

/// The controls on the picture hide after this much playback with no touch.
const Duration kControlsHide = Duration(seconds: 3);

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
    this.citedLang,
    this.onPlaySaved,
    this.onRedownload,
    this.mobileOverride,
    this.frame,
    this.qualities = const [],
    this.qualitiesExpire,
    this.loadQualities,
    this.reloadTarget,
    this.savedQuality,
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

  /// The cited passage's caption language (a code), when the citation gives one: that track is shown and its cue marked.
  final String? citedLang;

  /// A stream that cannot play while a saved copy exists: "Saved copy" opens it.
  final VoidCallback? onPlaySaved;

  /// A saved file that cannot play: "Delete it and download again".
  final VoidCallback? onRedownload;

  /// Test hook: behave as a phone or tablet (turning sideways enters full screen) or not. Null: by the platform.
  final bool? mobileOverride;

  /// Test hook for pictures: drawn in place of the video's frames.
  final Widget? frame;

  /// For a stream: the qualities it can be switched to (Auto is the stream [target] resolves to), and when a private video's
  /// file token in their addresses expires.
  final List<VideoQuality> qualities;
  final DateTime? qualitiesExpire;

  /// For a stream: reads the video page again for its qualities (when none were given, in the background while it plays;
  /// and for fresh addresses when a private video's file token has expired).
  final Future<(List<VideoQuality>, DateTime?)?> Function()? loadQualities;

  /// For a stream: resolves the video again (a fresh Auto address, with a new file token for a private video).
  final Future<VideoTarget> Function()? reloadTarget;

  /// For a saved copy: its quality ("480p"), shown in the settings as which copy this is.
  final String? savedQuality;

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

  /// "-10 s" or "+10 s" briefly after a double tap.
  int? _flash;
  Timer? _flashTimer;
  Offset? _lastDoubleTap;

  /// Playback began (from here on the place is kept).
  bool _started = false;
  int _lastCue = -1;
  final Map<int, GlobalKey> _cueKeys = {};
  final FocusNode _focus = FocusNode(debugLabel: 'player');

  /// The playback speeds offered.
  static const List<double> speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];

  VideoTarget get t => widget.target;

  /// What is playing: [t], or the quality chosen for a stream.
  late VideoTarget _src = t;

  /// The stream quality chosen (a key of [_qualities]); null: Auto.
  String? _quality;

  /// The qualities known now (given, or loaded since), and when their file token expires.
  late List<VideoQuality> _qualities = widget.qualities;
  late DateTime? _qExpire = widget.qualitiesExpire;
  String get _key => VideoPrefs.keyOf(instance: t.instance, uuid: t.uuid);

  List<CaptionTrack> _tracksOf() => t.isLocal
      ? [for (final c in t.captions) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic, path: c.path)]
      : [for (final c in widget.captionUrls) CaptionTrack(language: c.language, label: c.label, automatic: c.automatic, url: c.url)];

  bool get _hasCaptions => _tracks.isNotEmpty;

  /// A cited language's track, shown in the transcript while captions are off.
  int? _citedTrack;

  /// The track the transcript shows: the captions choice, else the cited language's, else the first.
  int get _shown => _on ?? _citedTrack ?? 0;

  bool get _mobile => widget.mobileOverride ?? (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    // A stream starts at the quality last chosen on this device, when this video has it (else Auto).
    final kept = widget.prefs?.quality;
    if (!t.isLocal && kept != null && kept != 'auto') {
      for (final q in _qualities) {
        if (q.key == kept) {
          _quality = q.key;
          _src = _sourceOf(q);
        }
      }
    }
    _start();
    _scheduleRefresh();
    // Opened with no qualities (a citation): Auto plays now, the list fills in when the video page arrives.
    if (!t.isLocal && _qualities.isEmpty && widget.loadQualities != null) unawaited(_reloadQualities());
  }

  Future<void> _reloadQualities() async {
    try {
      final got = await widget.loadQualities!();
      if (got == null || !mounted) return;
      setState(() {
        _qualities = got.$1;
        _qExpire = got.$2;
      });
      _scheduleRefresh();
    } catch (_) {
      // no list: Auto stays the only choice
    }
  }

  /// A private video's file token runs out: this long before it does, the address is renewed in place.
  static const Duration _refreshAhead = Duration(minutes: 2);
  Timer? _expiryTimer;

  /// One renewal after a playback failure that looks like the file token (401 or 403 on the file).
  bool _authRetried = false;

  /// A signed-in private video playing a plain file: renew its file token before it expires.
  void _scheduleRefresh() {
    _expiryTimer?.cancel();
    final exp = _qExpire;
    if (exp == null || t.isLocal || !t.needsAuth || widget.loadQualities == null) return;
    final wait = exp.difference(DateTime.now()) - _refreshAhead;
    _expiryTimer = Timer(wait.isNegative ? Duration.zero : wait, () => unawaited(_refreshSource()));
  }

  /// Fresh addresses (a new file token) for what plays now, swapped in at the same moment, playing as it was. A playlist
  /// passes its token on to each segment by itself (reinjectVideoFileToken), so only a plain file is swapped.
  Future<void> _refreshSource() async {
    if (!mounted || _c == null || widget.loadQualities == null) return;
    await _reloadQualities();
    if (!mounted || _c == null || _src.isHls) return;
    VideoTarget? src;
    final key = _quality;
    if (key != null) {
      for (final q in _qualities) {
        if (q.key == key) src = _sourceOf(q);
      }
    } else if (widget.reloadTarget != null) {
      try {
        src = await widget.reloadTarget!();
      } catch (_) {
        src = null;
      }
    }
    if (src != null && mounted) await _switchTo(src, quality: key);
  }

  /// A file refused for its token (HTTP 401 or 403), as the platform player words it.
  static bool _authFailure(String? error) {
    final e = (error ?? '').toLowerCase();
    return e.contains('401') || e.contains('403') || e.contains('forbidden') || e.contains('unauthorized');
  }

  VideoPlayerController _make() {
    if (widget.controllerFactory != null) return widget.controllerFactory!(_src);
    return _src.isLocal ? VideoPlayerController.file(File(_src.location)) : VideoPlayerController.networkUrl(Uri.parse(_src.location));
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
      _showOverlay();
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
    final citedTrack = widget.citedLang == null ? -1 : _tracks.indexWhere((x) => x.language == widget.citedLang);
    if (widget.cited && citedTrack >= 0) {
      // the cited language: on the picture on a phone, in the transcript on a wide window
      if (on != null || !_transcriptBeside(context)) on = citedTrack;
      _citedTrack = citedTrack;
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
    // a private video's file refused mid-playback (its token ran out): renew once and carry on
    if (c.value.hasError && !_authRetried && !t.isLocal && t.needsAuth && _authFailure(c.value.errorDescription)) {
      _authRetried = true;
      unawaited(_refreshSource());
      return;
    }
    final cues = _cues[_shown];
    if (cues != null) {
      final i = cueAt(cues, c.value.position);
      if (_match != null && c.value.position >= cues[_match!].end) _match = null;
      if (i != _lastCue) {
        _lastCue = i;
        if (i >= 0 && _transcriptBeside(context)) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(i));
      }
    }
    if ((!c.value.isPlaying || _ended(c)) && c.value.isInitialized) {
      _remember();
      // paused or at the end: the controls stay (at the end, Replay)
      if (!_overlay) _overlay = true;
    }
    setState(() {});
  }

  /// The video played to its end. Some players then report the position back at 0:00 and still "playing" (Android): their
  /// completed flag says it; else the position at the length.
  static bool _ended(VideoPlayerController c) =>
      c.value.isInitialized &&
      (c.value.isCompleted || (c.value.duration > Duration.zero && c.value.position >= c.value.duration - const Duration(milliseconds: 250)));

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
    _flashTimer?.cancel();
    _expiryTimer?.cancel();
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
      unawaited(setSystemBars(hideStatusBar: true));
      unawaited(SystemChrome.setPreferredOrientations(
        wide ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp],
      ));
    } else {
      unawaited(_restoreSystem());
    }
  }

  static Future<void> _restoreSystem() async {
    await setSystemBars();
    await SystemChrome.setPreferredOrientations(const []);
  }

  /// Shows the controls on the picture; while it plays they hide after [kControlsHide] (never while paused or scrubbing).
  void _showOverlay() {
    _hide?.cancel();
    if (mounted) setState(() => _overlay = true);
    _hide = Timer(kControlsHide, () {
      final c = _c;
      if (mounted && c != null && c.value.isPlaying && !_ended(c) && !_dragging) setState(() => _overlay = false);
    });
  }

  /// A tap on the picture shows or hides the controls.
  void _tapPicture() => _overlay ? setState(() => _overlay = false) : _showOverlay();

  /// A double tap on the left or right half skips 10 seconds back or forward, with a brief "-10 s" or "+10 s".
  void _doubleTap(Offset at, double width) {
    final back = at.dx < width / 2;
    _skip(back ? -10 : 10);
    _flashTimer?.cancel();
    setState(() => _flash = back ? -10 : 10);
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _flash = null);
    });
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

  String get _qualityLabel {
    for (final q in _qualities) {
      if (q.key == _quality) return q.label;
    }
    return 'Auto';
  }

  /// The stream of one quality, as a target the player opens.
  VideoTarget _sourceOf(VideoQuality q) => VideoTarget(
        isLocal: false,
        uuid: t.uuid,
        title: t.title,
        offsetS: t.offsetS,
        durationS: t.durationS,
        location: q.url,
        isHls: q.isHls,
        needsAuth: t.needsAuth,
        instance: t.instance,
      );

  /// The quality sheet (a stream): Auto and each quality; the choice is kept on this device.
  Future<void> _pickQuality() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Quality', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: context.t.text)),
              ),
              ListTile(
                key: const ValueKey('quality-auto'),
                minTileHeight: 48,
                title: const Text('Auto'),
                trailing: _quality == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, 'auto'),
              ),
              for (final q in _qualities)
                ListTile(
                  key: ValueKey('quality-${q.key}'),
                  minTileHeight: 48,
                  title: Text(q.label),
                  trailing: _quality == q.key ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(ctx, q.key),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    final key = picked == 'auto' ? null : picked;
    widget.prefs?.quality = picked;
    if (key == _quality) return;
    // a private video's file token runs out: fresh addresses first
    final exp = _qExpire;
    if (key != null && exp != null && DateTime.now().isAfter(exp.subtract(const Duration(minutes: 1))) && widget.loadQualities != null) {
      await _reloadQualities();
      if (!mounted) return;
    }
    VideoQuality? q;
    for (final x in _qualities) {
      if (x.key == key) q = x;
    }
    await _switchTo(q == null ? t : _sourceOf(q), quality: key);
  }

  /// Plays [src] in place of what plays now, at the same moment, playing or paused as it was.
  Future<void> _switchTo(VideoTarget src, {String? quality}) async {
    final old = _c;
    if (old == null) return;
    final at = old.value.position;
    final playing = old.value.isPlaying;
    final speed = old.value.playbackSpeed;
    old.removeListener(_tick);
    _keep?.cancel();
    setState(() {
      _quality = quality;
      _src = src;
      _c = null;
      _started = false;
    });
    await old.dispose();
    final c = _make();
    _c = c;
    c.addListener(_tick);
    try {
      await c.initialize();
      if (!mounted) return;
      if (at > Duration.zero) await c.seekTo(at);
      if (speed != 1) await c.setPlaybackSpeed(speed);
      if (playing) await c.play();
      _started = true;
      _keep = Timer.periodic(const Duration(seconds: 5), (_) => _remember());
    } catch (e) {
      if (mounted) setState(() => _error = "This video can't be played.");
    }
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

  /// The CC button: captions on (the language last chosen, else the first) or off.
  Future<void> _toggleCaptions() async {
    _showOverlay();
    if (_on != null) return _setCaptions(null);
    final kept = widget.prefs?.captions;
    final i = kept == null ? -1 : _tracks.indexWhere((x) => x.language == kept);
    await _setCaptions(i >= 0 ? i : 0);
  }

  /// The gear: Speed, Captions (the language sheet, when there are captions) and Transcript (a wide window with no room for it
  /// beside the video).
  Future<void> _settings() async {
    final c = _c;
    if (c == null) return;
    _hide?.cancel();
    final hiddenTranscript = _hasCaptions && !_transcriptBeside(context) && _wide(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('settings-speed'),
              minTileHeight: 48,
              leading: const Icon(Icons.speed),
              title: const Text('Speed'),
              trailing: Text(c.value.playbackSpeed == 1 ? 'Normal' : '${_speedText(c.value.playbackSpeed)}x'),
              onTap: () => Navigator.pop(ctx, 'speed'),
            ),
            if (!t.isLocal && _qualities.isNotEmpty)
              ListTile(
                key: const ValueKey('settings-quality'),
                minTileHeight: 48,
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('Quality'),
                trailing: Text(_qualityLabel),
                onTap: () => Navigator.pop(ctx, 'quality'),
              )
            else if (t.isLocal && widget.savedQuality != null)
              ListTile(
                key: const ValueKey('settings-quality-saved'),
                minTileHeight: 48,
                leading: const Icon(Icons.high_quality_outlined),
                title: Text('Quality: ${widget.savedQuality} (saved)'),
              ),
            if (_hasCaptions)
              ListTile(
                key: const ValueKey('settings-captions'),
                minTileHeight: 48,
                leading: const Icon(Icons.closed_caption_outlined),
                title: const Text('Captions'),
                trailing: Text(_on == null ? 'Off' : _tracks[_on!].name),
                onTap: () => Navigator.pop(ctx, 'captions'),
              ),
            if (hiddenTranscript)
              ListTile(
                key: const ValueKey('captions-transcript'),
                minTileHeight: 48,
                leading: const Icon(Icons.subject),
                title: const Text('Transcript'),
                onTap: () => Navigator.pop(ctx, 'transcript'),
              ),
          ],
        ),
      ),
    );
    switch (picked) {
      case 'speed':
        await _pickSpeed();
      case 'quality':
        await _pickQuality();
      case 'captions':
        await _captionSheet();
      case 'transcript':
        await _openTranscriptSheet();
    }
    _showOverlay();
  }

  /// The captions sheet: Off and each language (from the gear, or a long press on CC when there are two or more languages).
  Future<void> _captionSheet() async {
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
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _setCaptions(picked < 0 ? null : picked);
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
    if (_ended(c)) {
      // Replay: from the start
      unawaited(c.seekTo(Duration.zero).then((_) => c.play()));
    } else {
      c.value.isPlaying ? c.pause() : c.play();
    }
    _showOverlay();
  }

  static bool _wide(BuildContext context) => MediaQuery.sizeOf(context).width >= kTranscriptMinWidth;

  /// The transcript has its own pane beside the video: a wide, tall enough window and a video with captions.
  bool _transcriptBeside(BuildContext context) =>
      _hasCaptions && _wide(context) && MediaQuery.sizeOf(context).height >= kTranscriptMinHeight;

  /// "Play (Space)" on a desktop window, where the keys work; "Play" elsewhere.
  String _tip(BuildContext context, String words, String key) => isDesktop(context) ? '$words ($key)' : words;

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    final retrying = c != null && c.value.hasError && _authRetried && !t.isLocal && t.needsAuth && _authFailure(c.value.errorDescription);
    final error = _error ?? (c != null && c.value.hasError && !retrying ? (t.isLocal ? "This file can't be played." : "This video can't be played.") : null);
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
          if (_hasCaptions) _toggleCaptions();
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
                  child: !ready ? const Center(child: CircularProgressIndicator()) : _videoStack(context, c!, full: false),
                ),
              ),
            ),
          ),
          if (_resumedAt != null) _resumedBar(context),
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

  /// The video, or the sound's picture.
  Widget _picture(BuildContext context, VideoPlayerController c) {
    final Widget video = widget.frame ?? VideoPlayer(c);
    if (!t.isAudio) return video;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.thumbnail != null) Opacity(opacity: 0.4, child: VideoThumb(path: widget.thumbnail, width: 400)),
        const Center(child: Icon(Icons.music_note, size: 72, color: Colors.white70)),
        Offstage(child: video),
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

  /// Full screen: the video alone on black with the same controls on it; Back (or the arrow, or Esc) leaves full screen.
  Widget _fullScreen(BuildContext context, VideoPlayerController c) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _setFull(false);
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: _videoStack(context, c, full: true),
    ),
  );

  /// The video with its controls on it, the familiar way: a dark scrim top and bottom while they show; top, the title and Back
  /// (full screen) and the CC and settings buttons; centre, back 10 / play or pause / forward 10; bottom, the scrubber over the
  /// whole width, the time and the full-screen button. A tap shows or hides them (they hide by themselves after 3 s of
  /// playback); a double tap on the left or right half skips 10 s. The caption sits low, and above the bottom bar while the
  /// controls show.
  Widget _videoStack(BuildContext context, VideoPlayerController c, {required bool full}) {
    final cue = _currentCue(c);
    final show = _overlay || _dragging;
    final big = full || MediaQuery.sizeOf(context).width >= kTranscriptMinWidth;
    final pad = MediaQuery.paddingOf(context);
    final bottomBar = big ? 80.0 : 72.0;
    return LayoutBuilder(
      builder: (context, box) => Stack(
        key: ValueKey(full ? 'player-full' : 'player-inline'),
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: t.isAudio ? 16 / 9 : c.value.aspectRatio,
              child: _picture(context, c),
            ),
          ),
          // taps anywhere on the picture (the controls above take their own)
          GestureDetector(
            key: const ValueKey('player-surface'),
            behavior: HitTestBehavior.opaque,
            onTap: _tapPicture,
            onDoubleTapDown: (d) => _lastDoubleTap = d.localPosition,
            onDoubleTap: () => _doubleTap(_lastDoubleTap ?? Offset(box.maxWidth / 2, 0), box.maxWidth),
          ),
          if (_flash != null)
            Positioned(
              left: _flash! < 0 ? 0 : box.maxWidth / 2,
              width: box.maxWidth / 2,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    key: const ValueKey('player-skip-flash'),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(28)),
                    child: Text(_flash! < 0 ? '−10 s' : '+10 s', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ),
              ),
            ),
          if (show) ...[
            const Positioned(left: 0, right: 0, top: 0, height: 96, child: IgnorePointer(child: _Scrim(top: true))),
            Positioned(left: 0, right: 0, bottom: 0, height: bottomBar + 40 + (full ? pad.bottom : 0), child: const IgnorePointer(child: _Scrim(top: false))),
          ],
          if (cue != null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              left: 16,
              right: 16,
              bottom: (show ? bottomBar + 4 : 12) + (full ? pad.bottom : 0),
              child: IgnorePointer(child: _captionBand(context, cue, big: big)),
            ),
          if (show) ...[
            Positioned(
              left: full ? pad.left : 0,
              right: full ? pad.right : 0,
              top: full ? pad.top : 0,
              child: _topBar(context, full: full, big: big),
            ),
            // centred on the video; in a phone's small picture, above the caption's place so the two never meet
            Positioned(left: 0, right: 0, top: 0, bottom: big ? 0 : bottomBar + 30, child: Center(child: _centre(context, c, big: big))),
            Positioned(
              left: full ? pad.left : 0,
              right: full ? pad.right : 0,
              bottom: full ? pad.bottom : 0,
              height: bottomBar,
              child: _bottomBar(context, c, full: full),
            ),
            if (_dragging)
              Positioned(
                bottom: bottomBar + (full ? pad.bottom : 0),
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      key: const ValueKey('player-scrub-time'),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(8)),
                      child: Text(formatDuration(_dragValue / 1000), style: TextStyle(fontSize: big ? 20 : 16, fontWeight: FontWeight.w600, color: Colors.white)),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _captionBand(BuildContext context, (Cue, bool) cue, {required bool big}) {
    final k = context.t;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cue.$2)
            Container(
              key: const ValueKey('caption-match'),
              margin: const EdgeInsets.only(bottom: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              decoration: BoxDecoration(color: k.accent, borderRadius: BorderRadius.circular(6)),
              child: Text('Match', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.onPrimary)),
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
              child: Text(cue.$1.text, textAlign: TextAlign.center, style: TextStyle(fontSize: big ? 20 : 15, height: 1.3, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  /// An icon button for the dark scrim: a white icon with a soft shadow (readable over a bright picture), the tooltip as its
  /// screen-reader label; [bar] draws a short accent bar under it (captions on).
  Widget _iconButton({required Key key, required IconData icon, required String tooltip, required VoidCallback onPressed, VoidCallback? onLongPress, double size = 26, bool bar = false}) {
    final k = context.t;
    final Widget glyph = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: size, color: Colors.white, shadows: kOverlayShadows),
        if (bar) Container(key: const ValueKey('player-captions-on'), width: size * 0.75, height: 3, margin: const EdgeInsets.only(top: 1), decoration: BoxDecoration(color: k.accent, borderRadius: BorderRadius.circular(2))),
      ],
    );
    if (onLongPress == null) {
      return IconButton(key: key, tooltip: tooltip, iconSize: size, onPressed: onPressed, icon: glyph);
    }
    // A long press has its own job here, so the tooltip does not take it (it still names the button to a screen reader).
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: IconButton(key: key, iconSize: size, onPressed: onPressed, icon: glyph),
      ),
    );
  }

  Widget _topBar(BuildContext context, {required bool full, required bool big}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          if (full) ...[
            _iconButton(key: const ValueKey('player-full-back'), icon: Icons.arrow_back, tooltip: 'Leave full screen', onPressed: () => _setFull(false)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white, shadows: kOverlayShadows),
              ),
            ),
          ] else
            const Spacer(),
          if (_hasCaptions)
            _iconButton(
              key: const ValueKey('player-captions'),
              icon: _on == null ? Icons.closed_caption_off : Icons.closed_caption,
              bar: _on != null,
              tooltip: _tip(context, _on == null ? 'Captions: Off' : 'Captions: ${_tracks[_on!].name}', 'C'),
              onPressed: _toggleCaptions,
              onLongPress: _tracks.length > 1 ? _captionSheet : null,
            ),
          _iconButton(key: const ValueKey('player-settings'), icon: Icons.settings_outlined, tooltip: 'Settings', onPressed: _settings),
        ],
      ),
    );
  }

  Widget _centre(BuildContext context, VideoPlayerController c, {required bool big}) {
    final k = context.t;
    final icon = big ? 40.0 : 28.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconButton(key: const ValueKey('player-back-10'), icon: Icons.replay_10, tooltip: 'Back 10 seconds', size: icon, onPressed: () {
          _skip(-10);
          _showOverlay();
        }),
        SizedBox(width: big ? 40 : 28),
        Material(
          color: k.accent.withValues(alpha: 0.92),
          shape: const CircleBorder(),
          child: IconButton(
            key: const ValueKey('player-play'),
            iconSize: big ? 52 : 34,
            color: k.onPrimary,
            tooltip: _tip(context, _ended(c) ? 'Replay' : (c.value.isPlaying ? 'Pause' : 'Play'), 'Space'),
            onPressed: _playPause,
            icon: Icon(_ended(c) ? Icons.replay : (c.value.isPlaying ? Icons.pause : Icons.play_arrow)),
          ),
        ),
        SizedBox(width: big ? 40 : 28),
        _iconButton(key: const ValueKey('player-forward-10'), icon: Icons.forward_10, tooltip: 'Forward 10 seconds', size: icon, onPressed: () {
          _skip(10);
          _showOverlay();
        }),
      ],
    );
  }

  /// The scrubber over the whole width (thin; thicker while dragging), the time, and the full-screen button.
  Widget _bottomBar(BuildContext context, VideoPlayerController c, {required bool full}) {
    final k = context.t;
    final dur = c.value.duration.inMilliseconds.toDouble();
    final pos = _dragging ? _dragValue : c.value.position.inMilliseconds.clamp(0, dur.toInt()).toDouble();
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: _dragging ? 6 : 3,
              activeTrackColor: k.accent,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
              thumbColor: k.accent,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: _dragging ? 9 : 6),
              trackShape: const RectangularSliderTrackShape(),
            ),
            child: Slider(
              key: const ValueKey('player-scrubber'),
              value: dur <= 0 ? 0 : pos,
              max: dur <= 0 ? 1 : dur,
              semanticFormatterCallback: (v) => formatDuration(v / 1000),
              onChangeStart: (v) {
                _hide?.cancel();
                setState(() {
                  _dragging = true;
                  _dragValue = v;
                });
              },
              onChanged: (v) => setState(() => _dragValue = v),
              onChangeEnd: (v) async {
                await c.seekTo(Duration(milliseconds: v.round()));
                if (mounted) setState(() => _dragging = false);
                _showOverlay();
              },
            ),
          ),
        ),
        Row(
          children: [
            const SizedBox(width: 16),
            Text(
              '${formatDuration(pos / 1000)} / ${formatDuration(dur / 1000)}',
              key: const ValueKey('player-time'),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white, shadows: kOverlayShadows),
            ),
            const Spacer(),
            if (!t.isAudio)
              _iconButton(
                key: const ValueKey('player-fullscreen'),
                icon: _full ? Icons.fullscreen_exit : Icons.fullscreen,
                tooltip: _tip(context, _full ? 'Leave full screen' : 'Full screen', _full ? 'Esc' : 'F'),
                size: 28,
                onPressed: () => _setFull(!_full),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ],
    );
  }
}

/// The dark gradient behind the controls at the top or the bottom of the picture.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.top});

  final bool top;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: top ? Alignment.topCenter : Alignment.bottomCenter,
        end: top ? Alignment.bottomCenter : Alignment.topCenter,
        colors: [Colors.black.withValues(alpha: 0.7), Colors.black.withValues(alpha: 0)],
      ),
    ),
  );
}

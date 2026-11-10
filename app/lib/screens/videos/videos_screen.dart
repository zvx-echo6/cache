import 'dart:async';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../desktop/desktop.dart';
import '../../downloads/download_row.dart';
import '../../theme.dart';
import '../../video/caption_search.dart';
import '../../video/format.dart';
import '../../video/video_state.dart';
import '../../video/zim_video.dart' show isZimMediaAddress;
import 'instance_screen.dart';
import 'video_dl.dart';
import 'video_nav.dart';
import 'video_screen.dart';
import 'widgets.dart';

/// Asks for a PeerTube address and adds it; the new site opens.
Future<void> addVideoInstance(BuildContext context, VideoState video) async {
  final added = await showDialog<bool>(context: context, builder: (ctx) => AddInstanceDialog(video: video));
  if (added == true && context.mounted) {
    // The newest site is the one just added; open it.
    final i = video.instances.isEmpty ? null : video.instances.last;
    if (i != null) Navigator.push(context, MaterialPageRoute<void>(builder: (_) => InstanceScreen(video: video, instance: i)));
  }
}

/// From this many saved videos the list has a search field.
const int kVideoSearchFrom = 8;

/// The list keeps to this width on a wider window (centred).
const double kVideoListMaxWidth = 720;

/// From this window width the saved videos sit two across.
const double kVideoTwoAcrossWidth = 1400;

/// Browse > Videos: the saved videos are the home of the feature (UX-video-30 2.1). What is downloading (the download rows,
/// Pause and Resume), the videos on this device grouped by channel when there are two or more, and the video sites where more
/// are found. From [kVideoSearchFrom] saved videos a search matches titles, channels and the words said in them (the captions
/// index); a caption match opens the player at that moment.
class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key, required this.video, this.zims, this.showSites = true, this.title = 'Videos'});

  final VideoState video;

  /// Reads a ZIM's video for a caption match inside a ZIM; null: such matches are not offered.
  final ZimVideoReader? zims;

  /// The video sites part (left out where only the saved videos are wanted: Settings > Storage).
  final bool showSites;
  final String title;

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  String _searched = '';
  List<CaptionVideo> _captionHits = const [];
  bool _searching = false;

  VideoState get video => widget.video;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
    setState(() {});
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    setState(() {
      _searched = query;
      _captionHits = const [];
      _searching = query.isNotEmpty && video.captionSearch.available;
    });
    if (query.isEmpty || !video.captionSearch.available) return;
    List<CaptionVideo> hits;
    try {
      hits = await video.captionSearch.search(query, k: 20);
    } catch (_) {
      hits = const [];
    }
    if (!mounted || query != _searched) return;
    setState(() {
      _captionHits = hits;
      _searching = false;
    });
  }

  void _clear() {
    _query.clear();
    _debounce?.cancel();
    _search('');
  }

  void _open(DownloadedVideo d) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => VideoScreen(video: video, instanceId: d.instance, uuid: d.uuid, title: d.title)),
      );

  /// A caption match: the player at that moment, the line marked.
  Future<void> _openMoment(CaptionVideo v, CaptionHit h) =>
      openVideoCitation(context, video, video: v.link, offsetS: h.startS, lang: h.lang.isEmpty ? null : h.lang, zims: widget.zims);

  Future<void> _add() => addVideoInstance(context, video);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListenableBuilder(
        listenable: video,
        builder: (context, _) {
          if (video.unavailable != null) return Notice(video.unavailable!);
          final width = MediaQuery.sizeOf(context).width;
          final twoAcross = width >= kVideoTwoAcrossWidth;
          // The Linux desktop lines the list up with the page bar's title, on the page gutter, instead of centring it.
          final desktop = DesktopMetrics.of(context);
          return Align(
            alignment: desktop == null ? Alignment.center : Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: twoAcross ? kVideoListMaxWidth * 2 : kVideoListMaxWidth),
              child: ListView(
                padding: EdgeInsets.fromLTRB(desktop?.gutter ?? 16, 8, desktop?.gutter ?? 16, 24 + MediaQuery.paddingOf(context).bottom),
                children: _searched.isNotEmpty ? [_searchField(context), ..._results(context)] : _list(context, twoAcross),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextField(
        key: const ValueKey('videos-search'),
        controller: _query,
        textInputAction: TextInputAction.search,
        onChanged: _changed,
        onSubmitted: _search,
        decoration: InputDecoration(
          hintText: 'Search saved videos',
          prefixIcon: Icon(Icons.search, color: k.secondary),
          suffixIcon: _query.text.isEmpty ? null : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _clear),
        ),
      ),
    );
  }

  List<Widget> _list(BuildContext context, bool twoAcross) {
    final k = context.t;
    final tasks = video.tasks.where((t) => t.phase != DownloadPhase.done).toList();
    final groups = video.savedGroups();
    return [
      if (video.saved.length >= kVideoSearchFrom) _searchField(context),
      if (tasks.isNotEmpty) ...[
        const SectionHeading('Downloading', top: 8),
        for (final t in tasks) _task(context, t),
      ],
      SectionHeading(
        'On this device',
        top: tasks.isEmpty ? 8 : 20,
        detail: video.saved.isEmpty ? null : '${video.saved.length} video${video.saved.length == 1 ? '' : 's'} · ${formatBytes(video.savedBytes)}',
      ),
      if (video.saved.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text(
            'Nothing on this device yet. Find a video on a site and choose Download.',
            key: const ValueKey('videos-empty'),
            style: TextStyle(fontSize: 16, color: k.secondary),
          ),
        ),
      for (final g in groups) ...[
        if (g.heading != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
            child: Semantics(header: true, child: Text(g.heading!, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text))),
          ),
        if (twoAcross) ..._pairs([for (final d in g.videos) _savedRow(context, d)]) else for (final d in g.videos) _savedRow(context, d),
      ],
      if (widget.showSites) ...[
        // With a site already listed, adding another is a quiet Add at the heading's right; with none, the empty state's button.
        SectionHeading(
          'Video sites',
          top: 24,
          trailing: video.instances.isEmpty
              ? null
              : Semantics(
                  label: 'Add a video site',
                  excludeSemantics: true,
                  button: true,
                  child: TextButton(key: const ValueKey('videos-add-site'), onPressed: _add, child: const Text('Add')),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Text('Find videos on a site', style: TextStyle(fontSize: 15, color: k.secondary)),
        ),
        for (final i in video.instances)
          VideoTile(
            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => InstanceScreen(video: video, instance: i))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(i.name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                        const SizedBox(height: 2),
                        Text(video.userOf(i.id) == null ? i.host : '${i.host} · ${video.userOf(i.id)}', style: TextStyle(fontSize: 15, color: k.secondary)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: k.secondary),
                ],
              ),
            ),
          ),
        if (video.instances.isEmpty)
          Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('videos-add-site'),
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add a video site'),
            ),
          ),
        ),
      ],
    ];
  }

  /// Rows two across (a desktop window).
  List<Widget> _pairs(List<Widget> rows) => [
        for (var i = 0; i < rows.length; i += 2)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: rows[i]),
              const SizedBox(width: 12),
              Expanded(child: i + 1 < rows.length ? rows[i + 1] : const SizedBox.shrink()),
            ],
          ),
      ];

  Widget _task(BuildContext context, DownloadTask t) => DownloadRow(
        key: ValueKey('video-task-${t.key}'),
        keyBase: 'video-${t.uuid}',
        title: t.title,
        subtitle: t.label,
        state: videoDl(t),
        actions: videoActions(video, t),
      );

  /// A saved video: picture with its length, title, and "480p · 230 MB · Captions". It opens the video page (play, Delete).
  Widget _savedRow(BuildContext context, DownloadedVideo d, {CaptionHit? hit, CaptionVideo? match}) {
    final k = context.t;
    final meta = [
      d.isAudio ? 'Audio only' : d.resolutionLabel,
      formatBytes(d.size),
      if (d.captions.isNotEmpty) 'Captions',
    ].join(' · ');
    return VideoTile(
      key: ValueKey('saved-${d.instance}/${d.uuid}'),
      onTap: () => hit != null && match != null ? _openMoment(match, hit) : _open(d),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VideoThumb(path: d.thumbnailPath, durationS: d.durationS, width: 110, audio: d.isAudio),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                  const SizedBox(height: 4),
                  Text(meta, style: TextStyle(fontSize: 14, color: k.secondary)),
                  if (hit != null) _hitLine(context, hit),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "1:04  It makes a loop that..." under a caption match.
  Widget _hitLine(BuildContext context, CaptionHit h) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '${formatDuration(h.startS)}  ', style: TextStyle(fontWeight: FontWeight.w600, color: k.accent)),
          TextSpan(text: h.text),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, height: 1.35, color: k.text),
      ),
    );
  }

  List<Widget> _results(BuildContext context) {
    final k = context.t;
    final q = _searched.toLowerCase();
    // Caption matches first (best first, as the index ranks them), then titles and channels the index did not match.
    final rows = <Widget>[];
    final shown = <String>{};
    for (final v in _captionHits) {
      if (v.hits.isEmpty) continue;
      DownloadedVideo? d;
      final uuid = v.uuid;
      if (uuid != null) {
        for (final s in video.saved) {
          if (s.uuid == uuid) d = s;
        }
      }
      if (d != null) {
        shown.add('${d.instance}/${d.uuid}');
        rows.add(_savedRow(context, d, hit: v.hits.first, match: v));
      } else if (v.isZim && widget.zims != null && isZimMediaAddress(v.link)) {
        rows.add(_zimRow(context, v));
      }
    }
    for (final d in video.saved) {
      if (shown.contains('${d.instance}/${d.uuid}')) continue;
      if (d.title.toLowerCase().contains(q) || d.channelName.toLowerCase().contains(q)) rows.add(_savedRow(context, d));
    }
    if (_searching && rows.isEmpty) return [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))];
    if (rows.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
          child: Text('No saved video matches "$_searched".', style: TextStyle(fontSize: 16, color: k.secondary)),
        ),
      ];
    }
    return rows;
  }

  /// A caption match in a ZIM's video: its title and the matching line; it opens the player at that moment.
  Widget _zimRow(BuildContext context, CaptionVideo v) {
    final k = context.t;
    final h = v.hits.first;
    return VideoTile(
      key: ValueKey('zim-${v.link}'),
      onTap: () => _openMoment(v, h),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 2),
            Text('In ${widget.zims!.titleOf(v.sourceId)} (on this device)', style: TextStyle(fontSize: 14, color: k.secondary)),
            _hitLine(context, h),
          ],
        ),
      ),
    );
  }
}

class AddInstanceDialog extends StatefulWidget {
  const AddInstanceDialog({super.key, required this.video});

  final VideoState video;

  @override
  State<AddInstanceDialog> createState() => AddInstanceDialogState();
}

class AddInstanceDialogState extends State<AddInstanceDialog> {
  final _url = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.video.addInstance(_url.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = videoErrorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return AlertDialog(
      title: const Text('Add a video site'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(hintText: 'tube.example.org'),
            onSubmitted: (_) => _busy ? null : _add(),
          ),
          const SizedBox(height: 8),
          Text('The address of a PeerTube site.', style: TextStyle(fontSize: 14, color: k.secondary)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(fontSize: 15, color: k.emergency))),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: _busy ? null : _add, child: Text(_busy ? 'Adding…' : 'Add')),
      ],
    );
  }
}

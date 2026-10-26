import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/video_state.dart';
import 'channel_screen.dart';
import 'instance_sheet.dart';
import 'video_list.dart';
import 'widgets.dart';

enum _Tab { latest, channels }

/// One instance: its latest videos and channels, and a search. The login and the instance's own details are
/// behind the account button, not on this screen.
class InstanceScreen extends StatefulWidget {
  const InstanceScreen({super.key, required this.video, required this.instance});

  final VideoState video;
  final VideoInstance instance;

  @override
  State<InstanceScreen> createState() => _InstanceScreenState();
}

class _InstanceScreenState extends State<InstanceScreen> {
  final _query = TextEditingController();
  _Tab _tab = _Tab.latest;
  String _searched = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _submit(String q) => setState(() => _searched = q.trim());

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final v = widget.video;
    final i = widget.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(i.name),
        actions: [
          ListenableBuilder(
            listenable: v,
            builder: (context, _) => IconButton(
              tooltip: v.userOf(i.id) ?? 'Account and details',
              icon: Icon(v.userOf(i.id) == null ? Icons.account_circle_outlined : Icons.account_circle, color: v.userOf(i.id) == null ? k.text : k.accent),
              onPressed: () async {
                final removed = await showInstanceSheet(context, video: v, instance: i);
                if (removed == true && context.mounted) Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: _submit,
              decoration: InputDecoration(
                hintText: 'Search ${i.name}',
                prefixIcon: Icon(Icons.search, color: k.secondary),
                suffixIcon: _searched.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _query.clear();
                          _submit('');
                        },
                      ),
              ),
            ),
          ),
          if (_searched.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<_Tab>(
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: _Tab.latest, label: Text('Latest')), ButtonSegment(value: _Tab.channels, label: Text('Channels'))],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    final v = widget.video;
    final i = widget.instance;
    if (_searched.isNotEmpty) {
      return VideoList(
        key: ValueKey('search/$_searched'),
        video: v,
        instance: i,
        loadKey: _searched,
        load: (start) => v.search(i.id, _searched, start: start),
        empty: 'Nothing found for "$_searched"',
      );
    }
    if (_tab == _Tab.latest) {
      return VideoList(key: const ValueKey('latest'), video: v, instance: i, load: (start) => v.list(i.id, start: start), empty: 'This instance has no videos');
    }
    return _Channels(video: v, instance: i);
  }
}

class _Channels extends StatefulWidget {
  const _Channels({required this.video, required this.instance});

  final VideoState video;
  final VideoInstance instance;

  @override
  State<_Channels> createState() => _ChannelsState();
}

class _ChannelsState extends State<_Channels> {
  final List<VideoChannel> _items = [];
  int _total = 0;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.video.channels(widget.instance.id, start: _items.length);
      if (!mounted) return;
      setState(() {
        _items.addAll(p.channels);
        _total = p.total;
      });
    } catch (e) {
      if (mounted) setState(() => _error = videoErrorText(e));
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
      return const Notice('No channels');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _items.length + 1,
      itemBuilder: (context, n) {
        if (n == _items.length) {
          if (_items.length >= _total) return const SizedBox(height: 24);
          if (!_loading) WidgetsBinding.instance.addPostFrameCallback((_) => _more());
          return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
        }
        final c = _items[n];
        return VideoTile(
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ChannelScreen(video: widget.video, instance: widget.instance, channel: c))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: k.background,
                  backgroundImage: c.avatar == null ? null : NetworkImage(c.avatar!),
                  child: c.avatar == null ? Icon(Icons.tv, color: k.secondary) : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                      if ((c.description ?? '').isNotEmpty)
                        Text(c.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
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

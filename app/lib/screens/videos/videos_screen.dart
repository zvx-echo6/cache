import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/format.dart';
import '../../video/video_state.dart';
import 'instance_screen.dart';
import 'library_screen.dart';
import 'widgets.dart';

/// Browse > Videos: the instances the user connected, what is downloading, and the videos saved on the phone.
class VideosScreen extends StatelessWidget {
  const VideosScreen({super.key, required this.video});

  final VideoState video;

  Future<void> _add(BuildContext context) async {
    final added = await showDialog<bool>(context: context, builder: (ctx) => _AddInstanceDialog(video: video));
    if (added == true && context.mounted) {
      // The newest instance is the one just added; open it.
      final i = video.instances.isEmpty ? null : video.instances.last;
      if (i != null) Navigator.push(context, MaterialPageRoute<void>(builder: (_) => InstanceScreen(video: video, instance: i)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Videos')),
      body: ListenableBuilder(
        listenable: video,
        builder: (context, _) {
          if (video.unavailable != null) return Notice(video.unavailable!);
          final active = video.tasks.where((t) => t.isActive).length;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              VideoTile(
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LibraryScreen(video: video))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    children: [
                      Icon(Icons.download_done, color: k.accent),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Saved on this phone', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                            const SizedBox(height: 2),
                            Text(
                              video.saved.isEmpty && active == 0
                                  ? 'Nothing yet'
                                  : '${video.saved.length} video${video.saved.length == 1 ? '' : 's'} · ${formatBytes(video.savedBytes)}${active > 0 ? ' · $active downloading' : ''}',
                              style: TextStyle(fontSize: 15, color: k.secondary),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: k.secondary),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                child: Text('Instances', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.secondary)),
              ),
              if (video.instances.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No instances yet. Add the address of a PeerTube site to browse and watch its videos.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 17, color: k.secondary),
                  ),
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
                              Text(i.name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
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
            ],
          );
        },
      ),
      floatingActionButton: ListenableBuilder(
        listenable: video,
        builder: (context, _) => video.unavailable != null
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: () => _add(context),
                icon: const Icon(Icons.add),
                label: const Text('Add an instance'),
              ),
      ),
    );
  }
}

class _AddInstanceDialog extends StatefulWidget {
  const _AddInstanceDialog({required this.video});

  final VideoState video;

  @override
  State<_AddInstanceDialog> createState() => _AddInstanceDialogState();
}

class _AddInstanceDialogState extends State<_AddInstanceDialog> {
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
      title: const Text('Add an instance'),
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
          Text('The address of any PeerTube site.', style: TextStyle(fontSize: 14, color: k.secondary)),
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

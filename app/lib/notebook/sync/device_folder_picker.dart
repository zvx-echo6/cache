import 'package:flutter/material.dart';

import '../../theme.dart';

/// What a folder on this computer holds, as far as notes go (the Cache side looks for `.obsidian` and `logseq/config.edn`).
enum NotesKind { none, obsidian, logseq }

/// One subfolder in a listing.
class DeviceFolderEntry {
  const DeviceFolderEntry(this.name, [this.kind = NotesKind.none]);
  final String name;
  final NotesKind kind;
}

/// A folder's listing from the Cache side: its full path, the kind of notes it is itself, and its subfolders (no hidden ones).
/// [parent] is null at the top of the computer's folders.
class DeviceListing {
  const DeviceListing({required this.path, required this.folders, this.parent, this.kind = NotesKind.none});
  final String path;
  final String? parent;
  final NotesKind kind;
  final List<DeviceFolderEntry> folders;
}

/// Lists a folder on this computer; null starts at the home folder. Throws when Cache cannot read it.
typedef ListDeviceFolder = Future<DeviceListing> Function(String? path);

/// The folder picker for a browser: Cache's own, because a browser cannot hand over a folder path. It lists the folders on the
/// computer running Cache, starts at the home folder, and pops `(path, display)` like the phone's picker does.
class DeviceFolderPicker extends StatefulWidget {
  const DeviceFolderPicker({super.key, required this.list, this.start});

  final ListDeviceFolder list;

  /// Where to open; null is the home folder.
  final String? start;

  @override
  State<DeviceFolderPicker> createState() => _DeviceFolderPickerState();
}

class _DeviceFolderPickerState extends State<DeviceFolderPicker> {
  DeviceListing? _at;
  String? _wanted;
  bool _loading = true;
  bool _failed = false;
  bool _using = false;

  @override
  void initState() {
    super.initState();
    _open(widget.start);
  }

  Future<void> _open(String? path) async {
    setState(() {
      _loading = true;
      _failed = false;
      _wanted = path;
    });
    try {
      final l = await widget.list(path);
      if (!mounted || _wanted != path) return;
      setState(() {
        _at = l;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || _wanted != path) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  static String _join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  void _use(String path) {
    setState(() => _using = true);
    Navigator.pop(context, (path: path, display: path));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final at = _at;
    final shown = at?.path ?? _wanted ?? '~';
    final up = at?.parent;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a folder')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Folders on this computer', style: TextStyle(fontSize: 14, color: k.secondary)),
          ),
          _crumbs(context, shown, up),
          if (at != null && at.kind != NotesKind.none && !_failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(at.kind == NotesKind.obsidian ? 'This folder is an Obsidian vault.' : 'This folder is a Logseq graph.',
                  key: const ValueKey('picker-this-kind'), style: TextStyle(fontSize: 14, color: k.accent)),
            ),
          Expanded(child: _body(context, at)),
          _bottom(context, shown, at),
        ],
      ),
    );
  }

  Widget _crumbs(BuildContext context, String path, String? up) {
    final k = context.t;
    final parts = [for (final p in path.split('/')) if (p.isNotEmpty) p];
    final home = path.startsWith('~');
    return Row(
      children: [
        IconButton(
          key: const ValueKey('picker-up'),
          tooltip: 'Up one folder',
          icon: const Icon(Icons.arrow_upward),
          onPressed: up == null || _loading ? null : () => _open(up),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('picker-path'),
            scrollDirection: Axis.horizontal,
            reverse: true,
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                for (var i = 0; i < parts.length; i++) ...[
                  if (i > 0) Icon(Icons.chevron_right, size: 18, color: k.secondary),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: i == parts.length - 1 || _loading ? null : () => _open('${home ? '' : '/'}${parts.take(i + 1).join('/')}'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                      child: Text(
                        i == 0 && home ? 'Home' : parts[i],
                        style: TextStyle(fontSize: 15, fontWeight: i == parts.length - 1 ? FontWeight.w600 : FontWeight.w400, color: i == parts.length - 1 ? k.text : k.accent),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, DeviceListing? at) {
    final k = context.t;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed || at == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 32, color: k.warning),
              const SizedBox(height: 8),
              Text("Can't open this folder.", key: const ValueKey('picker-unreadable'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 4),
              Text('This computer does not let Cache read it. Choose another folder, or go up.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: k.secondary)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(key: const ValueKey('picker-retry'), onPressed: () => _open(_wanted), child: const Text('Try again')),
                  if (_upFromFailed != null) OutlinedButton(key: const ValueKey('picker-up-failed'), onPressed: () => _open(_upFromFailed), child: const Text('Go up')),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (at.folders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined, size: 32, color: k.secondary),
              const SizedBox(height: 8),
              Text('No folders in here.', key: const ValueKey('picker-empty'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 4),
              Text('Use this folder to keep your notes in it, or go up.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: k.secondary)),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final f in at.folders)
          ListTile(
            key: ValueKey('folder-${f.name}'),
            minTileHeight: 56,
            leading: Icon(f.kind == NotesKind.none ? Icons.folder_outlined : Icons.folder_special_outlined, color: f.kind == NotesKind.none ? k.secondary : k.accent),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: k.text)),
            subtitle: f.kind == NotesKind.none ? null : Text(f.kind == NotesKind.obsidian ? 'Obsidian vault' : 'Logseq graph', style: TextStyle(fontSize: 14, color: k.accent)),
            trailing: f.kind == NotesKind.none
                ? Icon(Icons.chevron_right, color: k.secondary)
                : TextButton(key: ValueKey('use-${f.name}'), onPressed: _using ? null : () => _use(_join(at.path, f.name)), child: const Text('Use')),
            onTap: () => _open(_join(at.path, f.name)),
          ),
      ],
    );
  }

  /// The parent of a folder that could not be read: from its path, since there is no listing to say.
  String? get _upFromFailed {
    final p = _wanted;
    if (p == null || p == '/' || p == '~') return null;
    final i = p.lastIndexOf('/');
    return i <= 0 ? (p.startsWith('~') ? '~' : '/') : p.substring(0, i);
  }

  Widget _bottom(BuildContext context, String path, DeviceListing? at) {
    final k = context.t;
    final ok = at != null && !_failed && !_loading;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(color: k.surface, border: Border(top: BorderSide(color: k.secondary.withValues(alpha: 0.25)))),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(path, key: const ValueKey('picker-chosen'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('picker-use'),
              onPressed: ok && !_using ? () => _use(path) : null,
              child: const Text('Use this folder'),
            ),
          ],
        ),
      ),
    );
  }
}

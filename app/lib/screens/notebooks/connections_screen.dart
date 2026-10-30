import 'package:flutter/material.dart';

import '../../notebook/sync/connections.dart';
import '../../notebook/sync/folder_access.dart';
import '../../notebook/sync/sync_engine.dart';
import '../../theme.dart';

/// Chooses a folder: its stored form and name, or null when none was chosen (tests give their own).
typedef PickFolder = Future<({String path, String display})?> Function();

/// Notebooks > Connections: Obsidian and Logseq folders, and notebook sync between your devices. Each says once what it does,
/// its status line, and the changes that need a decision.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key, required this.connections, this.pickFolder = pickSyncFolder, this.shareAvailable = false, this.folders = true});

  final NotebookConnections connections;
  final PickFolder pickFolder;

  /// Sharing and sync is set up on this phone (notebook sync is ticked there, as Notebooks).
  final bool shareAvailable;

  /// Obsidian and Logseq folders can be connected (Cache keeps access to a folder the person chooses: SAF on Android, a
  /// security-scoped bookmark on iOS).
  final bool folders;

  Future<void> _connect(BuildContext context, SyncKind kind) async {
    final messenger = ScaffoldMessenger.of(context);
    var k = kind;
    if (kind == SyncKind.logseq) {
      final pick = await showModalBottomSheet<SyncKind>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('logseq-files'),
                minTileHeight: 56,
                title: const Text('Logseq with a folder of Markdown files'),
                subtitle: const Text('Logseq 0.10 and earlier. Changes in either place update the other.'),
                onTap: () => Navigator.pop(ctx, SyncKind.logseq),
              ),
              ListTile(
                key: const ValueKey('logseq-export'),
                minTileHeight: 56,
                title: const Text('Logseq 2'),
                subtitle: const Text('Cache writes your entries as Markdown for Logseq to import. Changes made in Logseq stay there.'),
                onTap: () => Navigator.pop(ctx, SyncKind.logseqExport),
              ),
            ],
          ),
        ),
      );
      if (pick == null) return;
      k = pick;
    }
    final picked = await pickFolder();
    if (picked == null) return;
    final err = await connections.connect(k, picked.path, display: picked.display);
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Connections')),
      body: ListenableBuilder(
        listenable: connections,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (folders) ...[
            _section(
              context,
              key: 'obsidian',
              title: 'Obsidian',
              what: 'Cache keeps your entries as Markdown files in a folder you choose. Open that folder as a vault in Obsidian. '
                  'Changes in either place update the other.',
              target: connections.target(SyncKind.obsidian),
              onConnect: () => _connect(context, SyncKind.obsidian),
            ),
            const SizedBox(height: 12),
            _section(
              context,
              key: 'logseq',
              title: 'Logseq',
              what: 'Cache keeps your entries as blocks on the journal pages of a Logseq graph. Open that folder as a graph in Logseq.',
              target: connections.target(SyncKind.logseq),
              onConnect: () => _connect(context, SyncKind.logseq),
            ),
            const SizedBox(height: 12),
            ],
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your other devices', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                  const SizedBox(height: 4),
                  Text(
                    shareAvailable
                        ? 'Notebooks, with their photos, stay the same on the devices you linked in Sharing and sync when Notebooks is ticked there. '
                            'Private notebooks stay on this device unless their "Include in sync and sharing" is on.'
                        : 'Link your devices in Settings > Sharing and sync and tick Notebooks to keep your notebooks the same on all of them.',
                    style: TextStyle(fontSize: 14, color: k.secondary),
                  ),
                  if (connections.status('share') case final s?) Padding(padding: const EdgeInsets.only(top: 6), child: Text(s, style: TextStyle(fontSize: 14, color: k.text))),
                  for (final c in connections.conflicts('share')) _conflict(context, 'share', c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, {required String key, required String title, required String what, required SyncTargetConfig? target, required VoidCallback onConnect}) {
    final k = context.t;
    final merged = target == null ? const <String>[] : connections.merged(target.id);
    return Container(
      key: ValueKey('connection-$key'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text))),
              if (target == null)
                FilledButton(key: ValueKey('connect-$key'), onPressed: onConnect, child: const Text('Connect'))
              else
                PopupMenuButton<String>(
                  key: ValueKey('menu-$key'),
                  onSelected: (c) {
                    switch (c) {
                      case 'sync':
                        connections.syncAll();
                      case 'pause':
                        connections.setPaused(target.id, !target.paused);
                      case 'disconnect':
                        connections.disconnect(target.id);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'sync', child: Text('Sync now')),
                    PopupMenuItem(value: 'pause', child: Text(target.paused ? 'Resume' : 'Pause')),
                    const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(what, style: TextStyle(fontSize: 14, color: k.secondary)),
          if (target != null) ...[
            const SizedBox(height: 6),
            Text(
              [target.name, if (target.kind == SyncKind.logseqExport) 'export only'].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: k.text),
            ),
            if (connections.status(target.id) case final s?) Text(s, key: ValueKey('status-$key'), style: TextStyle(fontSize: 14, color: s.startsWith("Can't") ? k.warning : k.text)),
            if (merged.isNotEmpty)
              Text(
                'Changed in both places and merged: ${merged.take(3).join(', ')}${merged.length > 3 ? ' and ${merged.length - 3} more' : ''}',
                key: ValueKey('merged-$key'),
                style: TextStyle(fontSize: 14, color: k.text),
              ),
            for (final c in connections.conflicts(target.id)) _conflict(context, target.id, c),
          ],
        ],
      ),
    );
  }

  Widget _conflict(BuildContext context, String id, SyncConflict c) {
    final k = context.t;
    final (title, keepLabel, otherLabel, note) = switch (c.kind) {
      ConflictKind.bothChanged => ('Changed in two places: ${c.title}', "Keep Cache's version", "Keep the file's version", 'The other version is kept as a copy.'),
      ConflictKind.removedOutside => ('Removed in the folder: ${c.title}', 'Keep in Cache', 'Delete here too', null),
      ConflictKind.unreadable => ("Couldn't read ${c.title}. Cache left it alone.", 'Ignore', null, null),
    };
    return Card(
      key: ValueKey('conflict-${c.entryId}-${c.kind.name}'),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
            if (c.kind == ConflictKind.bothChanged) ...[
              const SizedBox(height: 6),
              Text('In Cache', style: TextStyle(fontSize: 12, color: k.secondary)),
              Text(c.cacheText ?? '', maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 4),
              Text('In the folder', style: TextStyle(fontSize: 12, color: k.secondary)),
              Text(c.fileText ?? '', maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
            if (note != null) Text(note, style: TextStyle(fontSize: 13, color: k.secondary)),
            Wrap(
              spacing: 8,
              children: [
                TextButton(key: const ValueKey('conflict-keep-cache'), onPressed: () => connections.resolve(id, c, keepCache: true), child: Text(keepLabel)),
                if (otherLabel != null)
                  TextButton(key: const ValueKey('conflict-keep-file'), onPressed: () => connections.resolve(id, c, keepCache: false), child: Text(otherLabel)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../sources/sources_state.dart';
import '../theme.dart';

String _size(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
}

/// The reading sources: the ZIM files Cache searches. Adding one copies it in and indexes it in the background.
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key, required this.sources});

  final SourcesState sources;

  Future<void> _confirmRemove(BuildContext context, ZimFile z) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${sources.titleOf(z)}?'),
        content: const Text(
          'The file and its index are deleted from this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes == true) sources.remove(z);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Sources')),
      body: ListenableBuilder(
        listenable: sources,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: sources.zims.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            sources.unavailable ??
                                'No sources yet. Choose a .zim file to add one.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 18, color: k.secondary),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        children: [
                          for (final z in sources.zims) _tile(context, z),
                        ],
                      ),
              ),
              if (sources.unavailable != null && sources.zims.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    sources.unavailable!,
                    style: TextStyle(fontSize: 15, color: k.warning),
                  ),
                ),
              if (sources.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    sources.error!,
                    style: TextStyle(fontSize: 15, color: k.emergency),
                  ),
                ),
              if (sources.copyProgress != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Copying ${sources.copyName} — ${(sources.copyProgress! * 100).toStringAsFixed(0)}%',
                        style: TextStyle(fontSize: 15, color: k.secondary),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: sources.copyProgress),
                    ],
                  ),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: sources.copyProgress != null
                            ? null
                            : () => sources.pickAndAddZim(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add a ZIM…'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Files are copied to the app\'s own folder. Each new ZIM is indexed in the background, which can take a while.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: k.secondary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, ZimFile z) {
    final k = context.t;
    final phase = sources.phaseOf(z);
    final String status;
    final Color statusColor;
    switch (phase) {
      case ZimPhase.ready:
        status = 'Ready · ${sources.docsOf(z)} articles';
        statusColor = k.ok;
      case ZimPhase.indexing:
        final f = sources.indexFraction(z);
        status = f == null
            ? 'Indexing…'
            : 'Indexing ${(f * 100).toStringAsFixed(0)}%';
        statusColor = k.secondary;
      case ZimPhase.failed:
        status = sources.failureOf(z) ?? 'Could not be read';
        statusColor = k.emergency;
      case ZimPhase.waiting:
        status = sources.coreReady ? 'Waiting to index' : 'Not available';
        statusColor = k.secondary;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sources.titleOf(z),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: k.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_size(z.size)} · $status',
                        style: TextStyle(fontSize: 15, color: statusColor),
                      ),
                      if (phase == ZimPhase.indexing) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: sources.indexFraction(z),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.delete_outline, color: k.secondary),
                  onPressed: () => _confirmRemove(context, z),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

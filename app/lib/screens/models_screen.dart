import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

String _size(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
}

/// The model chooser: lists the .gguf files in the app's models folder.
class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: app.models.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No models yet. Choose a .gguf file to add one.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 18, color: k.secondary),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        children: [for (final m in app.models) _tile(context, m)],
                      ),
              ),
              if (app.loadError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(app.loadError!, style: TextStyle(fontSize: 15, color: k.emergency)),
                ),
              if (app.copyProgress != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Copying ${app.copyName} — ${(app.copyProgress! * 100).toStringAsFixed(0)}%',
                          style: TextStyle(fontSize: 15, color: k.secondary)),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: app.copyProgress),
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
                        onPressed: app.copyProgress != null ? null : () => app.pickAndCopy(),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Choose a file…'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Cache needs a model that can use tools. Files are copied to the app\'s own models folder.',
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

  Widget _tile(BuildContext context, ModelEntry m) {
    final k = context.t;
    final isActive = app.active?.path == m.path;
    final isLoading = app.loading?.path == m.path;
    final unsupported = app.isUnsupported(m);
    String status;
    Color statusColor;
    if (isLoading) {
      status = 'Loading…';
      statusColor = k.secondary;
    } else if (isActive) {
      status = 'Active';
      statusColor = k.ok;
    } else if (unsupported) {
      status = 'Not supported: Cache needs a model that can use tools';
      statusColor = k.warning;
    } else {
      status = 'Tap to use';
      statusColor = k.secondary;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: (unsupported || isActive || app.loading != null) ? null : () => app.activate(m),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.displayName(m), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: unsupported ? k.secondary : k.text)),
                        const SizedBox(height: 2),
                        Text(m.fileName, style: TextStyle(fontSize: 14, color: k.secondary)),
                        const SizedBox(height: 2),
                        Text('${_size(m.size)} · $status', style: TextStyle(fontSize: 15, color: statusColor)),
                      ],
                    ),
                  ),
                  if (isLoading)
                    const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  else if (isActive)
                    Icon(Icons.check_circle, color: k.ok),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

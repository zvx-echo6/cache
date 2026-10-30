import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/model_downloads.dart';
import '../models/recommendations.dart';
import '../theme.dart';
import 'model_search_screen.dart';
import '../browse/zim_download.dart' show freeBytesOnDisk;
import 'download_confirm.dart';
import 'hold.dart';
import 'settings/widgets.dart' show GroupLabel;

String _size(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
}

/// Opens the model chooser (from the Ask top bar and the Home model card).
void openModels(BuildContext context, AppState app) {
  app.refreshModels();
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ModelsScreen(app: app)));
}

/// The model chooser. It leads with the recommended models (each with its size and whether it fits this phone; a tap
/// downloads it), then "Search Hugging Face" and "Choose a file…", then the models already on this phone. No model is ever
/// chosen for the user.
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key, required this.app, this.recommended, this.memory});

  final AppState app;

  /// The recommended list; the app's when null.
  final RecommendedModels? recommended;

  /// The phone's memory for the fit check; read from the phone when null.
  final int? memory;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  late final RecommendedModels _recommended = widget.recommended ?? RecommendedModels.shared;
  int? _memory;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    if (_memory == null) totalMemoryBytes().then((m) => mounted ? setState(() => _memory = m) : null);
    if (ModelDownloads.shared != null) _recommended.load();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final downloads = ModelDownloads.shared;
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListenableBuilder(
        listenable: Listenable.merge([app, _recommended, ?downloads]),
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    if (downloads != null && _recommended.models.isNotEmpty) ...[
                      const GroupLabel('Recommended'),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                        child: Text(
                          'The model is the AI that answers your questions. It runs on this phone, so it works with no signal.',
                          style: TextStyle(fontSize: 13, color: k.secondary),
                        ),
                      ),
                      for (final r in _recommended.models) _recommendedTile(context, downloads, r),
                      const SizedBox(height: 8),
                    ],
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (downloads != null)
                          OutlinedButton(
                            key: const ValueKey('find-model'),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => ModelSearchScreen(downloads: downloads)),
                            ),
                            child: const Text('Search Hugging Face'),
                          ),
                        OutlinedButton(
                          key: const ValueKey('choose-file'),
                          onPressed: app.copyProgress != null ? null : () => app.pickAndCopy(),
                          child: const Text('Choose a file'),
                        ),
                      ],
                    ),
                    if (app.modelsError != null)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(app.modelsError!, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: k.secondary)),
                      )
                    else if (app.models.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const GroupLabel('On this phone'),
                      for (final m in app.models) _tile(context, m),
                    ],
                  ],
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
              if (downloads != null) SafeArea(top: false, child: ModelDownloadBar(downloads: downloads)),
            ],
          );
        },
      ),
    );
  }

  Widget _recommendedTile(BuildContext context, ModelDownloads d, ModelRecommendation r) {
    final k = context.t;
    final f = r.hfFile;
    final installed = d.isInstalled(f);
    final fit = ModelFit.of(r.size, _memory);
    final colour = switch (fit) {
      ModelFit.fits => k.ok,
      ModelFit.tight => k.warning,
      ModelFit.tooBig => k.emergency,
      ModelFit.unknown => k.secondary,
    };
    final canDownload = !installed && !d.busy;
    return Padding(
      key: ValueKey('recommended-${r.file}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: canDownload ? () => downloadModel(context, d, f) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                      if (r.note.isNotEmpty) Text(r.note, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: _size(r.size), style: TextStyle(color: k.secondary)),
                        if (fit != ModelFit.unknown) TextSpan(text: ' · ${fit.label}', style: TextStyle(color: colour)),
                      ]), style: const TextStyle(fontSize: 13)),
                      Text(r.kind.label, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                if (installed)
                  RowBadge('On this phone', color: k.ok)
                else
                  IconButton(
                    key: ValueKey('download-recommended-${r.file}'),
                    tooltip: 'Download',
                    icon: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: canDownload ? k.accent : k.secondary, width: 1.5)),
                      child: Icon(Icons.download, size: 17, color: canDownload ? k.accent : k.secondary),
                    ),
                    onPressed: canDownload ? () => downloadModel(context, d, f) : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ModelEntry m) async {
    final dir = app.modelsDir;
    if (await confirmDelete(context, name: app.displayName(m), bytes: m.size, free: dir == null ? null : freeBytesOnDisk(dir.path))) {
      await app.deleteModel(m);
    }
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
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.displayName(m), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: unsupported ? k.secondary : k.text)),
                        const SizedBox(height: 2),
                        Text(m.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                        const SizedBox(height: 2),
                        Text('${_size(m.size)} · $status', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: statusColor)),
                      ],
                    ),
                  ),
                  if (isLoading)
                    const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  else if (isActive)
                    TextButton(
                      key: const ValueKey('unload-model'),
                      onPressed: app.unload,
                      child: const Text('Unload'),
                    )
                  else if (app.loading == null)
                    IconButton(
                      key: ValueKey('delete-model-${m.fileName}'),
                      tooltip: 'Delete',
                      icon: Icon(Icons.delete_outline, color: k.secondary),
                      onPressed: () => _confirmDelete(context, m),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

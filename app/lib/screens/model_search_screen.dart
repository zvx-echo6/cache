import 'package:flutter/material.dart';

import '../models/hf_hub.dart';
import '../models/model_downloads.dart';
import '../theme.dart';

String _size(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
}

String _count(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
  return '$n';
}

/// The bar at the bottom of the model screens while a model downloads, or after it stopped or finished.
class ModelDownloadBar extends StatelessWidget {
  const ModelDownloadBar({super.key, required this.downloads});

  final ModelDownloads downloads;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final d = downloads;
        if (d.current != null) {
          final f = d.current!;
          final p = d.total == 0 ? null : d.done / d.total;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        d.verifying
                            ? 'Checking ${f.fileName}…'
                            : 'Downloading ${f.fileName}: ${_size(d.done)} of ${_size(d.total)}',
                        style: TextStyle(fontSize: 15, color: k.secondary),
                      ),
                    ),
                    if (!d.verifying)
                      TextButton(key: const ValueKey('model-download-stop'), onPressed: d.cancel, child: const Text('Stop')),
                  ],
                ),
                LinearProgressIndicator(value: d.verifying ? null : p),
              ],
            ),
          );
        }
        if (d.error != null) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(d.error!, style: TextStyle(fontSize: 15, color: k.emergency)),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

/// Find a model on Hugging Face: search, pick a repository, pick a file. Shows each file's size and whether it fits
/// this phone; downloads resume where they stopped and are checked against Hugging Face's checksum.
class ModelSearchScreen extends StatefulWidget {
  const ModelSearchScreen({super.key, required this.downloads, this.initialQuery = 'gemma 4'});

  final ModelDownloads downloads;
  final String initialQuery;

  @override
  State<ModelSearchScreen> createState() => _ModelSearchScreenState();
}

class _ModelSearchScreenState extends State<ModelSearchScreen> {
  late final _query = TextEditingController(text: widget.initialQuery);
  List<HfModel>? _results;
  String? _error;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_query.text.trim().isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await widget.downloads.hub.search(_query.text);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not search Hugging Face. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final results = _results;
    return Scaffold(
      appBar: AppBar(title: const Text('Find a model')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                key: const ValueKey('model-search'),
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Search Hugging Face (for example gemma 4, qwen3)',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                      : null,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Models from Hugging Face in GGUF format. Cache only uses models that can use tools; that is checked when the model is first loaded.',
                style: TextStyle(fontSize: 13, color: k.secondary),
              ),
            ),
            Expanded(
              child: _error != null
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: k.secondary))))
                  : results == null
                  ? const SizedBox.shrink()
                  : results.isEmpty
                  ? Center(child: Text('No GGUF models match.', style: TextStyle(fontSize: 16, color: k.secondary)))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final m = results[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            minTileHeight: 64,
                            title: Text(m.name, style: const TextStyle(fontSize: 17)),
                            subtitle: Text(
                              [m.owner, '${_count(m.downloads)} downloads', if (m.gated) 'needs a Hugging Face account'].join(' · '),
                              style: TextStyle(fontSize: 14, color: k.secondary),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => ModelFilesScreen(downloads: widget.downloads, model: m)),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            ModelDownloadBar(downloads: widget.downloads),
          ],
        ),
      ),
    );
  }
}

/// Downloads [f] from a model screen: asks first when the mobile-data switch stops it, and offers "Use it" when it is ready.
Future<void> downloadModel(BuildContext context, ModelDownloads d, HfFile f, {bool anyway = false}) async {
  await d.start(f, anyway: anyway);
  if (!context.mounted) return;
  if (d.blocked != null) {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(d.blocked!.message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Wait for Wi-Fi')),
          TextButton(key: const ValueKey('download-anyway'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Download anyway')),
        ],
      ),
    );
    if (go == true && context.mounted) await downloadModel(context, d, f, anyway: true);
    return;
  }
  if (d.finished != null) {
    final finished = d.finished!;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text('${finished.fileName} is ready.'),
      action: SnackBarAction(label: 'Use it', onPressed: () => d.app.activate(finished)),
    ));
  }
}

/// The files of one repository, with size, fit and a download button each.
class ModelFilesScreen extends StatefulWidget {
  const ModelFilesScreen({super.key, required this.downloads, required this.model, this.memory});

  final ModelDownloads downloads;
  final HfModel model;

  /// The phone's memory for the fit check; read from the phone when null.
  final int? memory;

  @override
  State<ModelFilesScreen> createState() => _ModelFilesScreenState();
}

class _ModelFilesScreenState extends State<ModelFilesScreen> {
  List<HfFile>? _files;
  String? _error;
  int? _memory;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    if (_memory == null) totalMemoryBytes().then((m) => mounted ? setState(() => _memory = m) : null);
    widget.downloads.hub.ggufFiles(widget.model.id).then(
      (f) => mounted ? setState(() => _files = f) : null,
      onError: (_) => mounted ? setState(() => _error = 'Could not list the files. Check the connection and try again.') : null,
    );
  }

  Future<void> _download(HfFile f) => downloadModel(context, widget.downloads, f);

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final files = _files;
    return Scaffold(
      appBar: AppBar(title: Text(widget.model.name)),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([widget.downloads, widget.downloads.app]),
                builder: (context, _) {
                  if (_error != null) return Center(child: Text(_error!, style: TextStyle(fontSize: 16, color: k.secondary)));
                  if (files == null) return const Center(child: CircularProgressIndicator());
                  if (files.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('This repository has no single-file GGUF models.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: k.secondary)),
                      ),
                    );
                  }
                  final d = widget.downloads;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    children: [
                      if (widget.model.gated)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'This repository asks people to sign in to Hugging Face and accept its terms first. If the download is refused, get the file in a browser and use "Choose a file".',
                            style: TextStyle(fontSize: 14, color: k.warning),
                          ),
                        ),
                      for (final f in files)
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(f.fileName, style: const TextStyle(fontSize: 16)),
                                      const SizedBox(height: 2),
                                      Builder(builder: (context) {
                                        final fit = ModelFit.of(f.size, _memory);
                                        final colour = switch (fit) {
                                          ModelFit.fits => k.ok,
                                          ModelFit.tight => k.warning,
                                          ModelFit.tooBig => k.emergency,
                                          ModelFit.unknown => k.secondary,
                                        };
                                        final part = d.partBytes(f);
                                        return Text.rich(TextSpan(children: [
                                          TextSpan(text: _size(f.size), style: TextStyle(color: k.secondary)),
                                          if (fit != ModelFit.unknown) TextSpan(text: ' · ${fit.label}', style: TextStyle(color: colour)),
                                          if (part > 0 && d.current?.path != f.path)
                                            TextSpan(text: ' · ${_size(part)} downloaded, continues', style: TextStyle(color: k.secondary)),
                                        ]), style: const TextStyle(fontSize: 14));
                                      }),
                                    ],
                                  ),
                                ),
                                if (d.isInstalled(f))
                                  Padding(padding: const EdgeInsets.all(12), child: Icon(Icons.check_circle, color: k.ok))
                                else
                                  IconButton(
                                    key: ValueKey('download-${f.fileName}'),
                                    tooltip: 'Download',
                                    icon: const Icon(Icons.download),
                                    onPressed: d.busy ? null : () => _download(f),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            ModelDownloadBar(downloads: widget.downloads),
          ],
        ),
      ),
    );
  }
}

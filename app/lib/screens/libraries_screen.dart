import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../browse/catalogue_screen.dart' show formatBytes;
import '../sources/libraries_state.dart';
import '../theme.dart';

/// Picks the settings file (cache-library.json) of a library that came without one; a test hook replaces it.
typedef PickSettingsFile = Future<String?> Function();

Future<String?> _pickSettingsWithPicker() async => (await FilePicker.pickFile())?.path;

/// The libraries on this device: what each holds and whether it is ready, adding one from a file or a download link, an
/// update offered when the same library is added again, removing one, and the blank template to make your own.
class LibrariesScreen extends StatefulWidget {
  const LibrariesScreen({super.key, required this.libraries, this.pickSettingsFile = _pickSettingsWithPicker});

  final LibrariesState libraries;
  final PickSettingsFile pickSettingsFile;

  @override
  State<LibrariesScreen> createState() => _LibrariesScreenState();
}

class _LibrariesScreenState extends State<LibrariesScreen> {
  LibrariesState get s => widget.libraries;

  Future<bool> _confirmUpdate(String name, String? from, String? to) async {
    if (!mounted) return false;
    final versions = from != null && to != null
        ? ' (version $from → version $to)'
        : to != null
            ? ' (to version $to)'
            : '';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update $name$versions?'),
        content: Text('This is a copy of $name, which is already on this device. The new copy replaces it once it opens.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('update-library'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Update')),
        ],
      ),
    );
    return yes == true;
  }

  Future<String?> _askSettings(String reason) async {
    if (!mounted) return null;
    final choose = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose its settings file'),
        content: Text(
          'This library came without its settings file (cache-library.json), and Cache could not work them out from the '
          'library itself.\n\n$reason',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('choose-settings'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Choose file')),
        ],
      ),
    );
    if (choose != true) return null;
    return widget.pickSettingsFile();
  }

  Future<void> _add() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('add-from-file'),
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('From a file on this device'),
              subtitle: const Text('A .cache-library file, or a library snapshot'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              key: const ValueKey('add-from-link'),
              leading: const Icon(Icons.link),
              title: const Text('From a download link'),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (how == 'file') {
      await s.pickAndAdd(confirmUpdate: _confirmUpdate, askSettings: _askSettings);
    } else if (how == 'link') {
      final link = await _askLink();
      if (link != null && link.trim().isNotEmpty) await s.addLink(link, confirmUpdate: _confirmUpdate, askSettings: _askSettings);
    }
  }

  Future<String?> _askLink() => showDialog<String>(context: context, builder: (_) => const _LinkDialog());

  Future<void> _confirmRemove(LibraryItem l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${s.titleOf(l)}?'),
        content: const Text('The library and its search index are deleted from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('remove-library'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (yes == true) await s.remove(l);
  }

  Future<void> _template() async {
    final saved = await s.saveTemplate();
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Template saved. Its README says how to fill it.')));
  }

  void _info(LibraryItem l) {
    final k = context.t;
    final whole = s.wholeLibraryOnly(l);
    final rows = <(String, String)>[
      ('Entries', '${s.docsOf(l)}'),
      if (s.versionOf(l) != null) ('Version', s.versionOf(l)!),
      ('Size', formatBytes(l.size)),
      if (s.modelOf(l) != null) ('Search model', s.modelOf(l)!),
      if (whole == true) ('Updates', 'Whole library only'),
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.titleOf(l), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 12),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 120, child: Text(r.$1, style: TextStyle(fontSize: 15, color: k.secondary))),
                      Expanded(child: Text(r.$2, style: TextStyle(fontSize: 15, color: k.text))),
                    ],
                  ),
                ),
              if (whole == true) ...[
                const SizedBox(height: 8),
                Text(
                  'Its entries do not say which document they came from, so a newer copy replaces the whole library.',
                  style: TextStyle(fontSize: 14, color: k.secondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Libraries')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final t = s.task;
          final busy = t != null && t.running;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  children: [
                    if (t != null) _taskCard(k, t),
                    if (s.libraries.isEmpty && t == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          s.sources.unavailable ??
                              'No libraries yet. A library is a collection of passages Cache searches and cites. Add one from a file or a download link.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, color: k.secondary),
                        ),
                      ),
                    for (final l in s.libraries) _tile(k, l),
                    if (s.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(s.error!, style: TextStyle(fontSize: 15, color: k.emergency)),
                      ),
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
                        key: const ValueKey('add-library'),
                        onPressed: busy || !s.sources.coreReady ? null : _add,
                        icon: const Icon(Icons.add),
                        label: const Text('Add a library'),
                      ),
                      const SizedBox(height: 4),
                      TextButton.icon(
                        key: const ValueKey('library-template'),
                        onPressed: s.makingTemplate || !s.sources.coreReady ? null : _template,
                        icon: const Icon(Icons.description_outlined),
                        label: Text(s.makingTemplate ? 'Making the template…' : 'Get a blank library template'),
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

  String _stepText(AddTask t) {
    final f = t.fraction;
    final pct = f == null ? '' : ' ${(f * 100).clamp(0, 100).toStringAsFixed(0)}%';
    return switch (t.step) {
      AddStep.downloading => 'Downloading$pct',
      AddStep.unpacking => 'Unpacking$pct',
      AddStep.checking => 'Checking…',
      AddStep.indexing => 'Building the search index$pct',
      AddStep.swapping => 'Putting it in place…',
    };
  }

  Widget _taskCard(CacheTokens k, AddTask t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: k.surface,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Adding ${t.name}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                const SizedBox(height: 4),
                if (t.running) ...[
                  Text(_stepText(t), style: TextStyle(fontSize: 14, color: k.secondary)),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: t.fraction),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(key: const ValueKey('cancel-add'), onPressed: s.cancelAdd, child: const Text('Cancel')),
                  ),
                ] else ...[
                  Text(t.error!, style: TextStyle(fontSize: 14, color: t.blockedByMobileData ? k.warning : k.emergency)),
                  Row(
                    children: [
                      if (t.blockedByMobileData && t.link != null)
                        TextButton(
                          key: const ValueKey('download-anyway'),
                          onPressed: () => s.addLink(t.link!, confirmUpdate: _confirmUpdate, askSettings: _askSettings, anyway: true),
                          child: const Text('Download anyway'),
                        ),
                      TextButton(onPressed: s.dismissTask, child: const Text('OK')),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _tile(CacheTokens k, LibraryItem l) {
    final phase = s.phaseOf(l);
    final String status;
    final Color color;
    switch (phase) {
      case LibraryPhase.ready:
        final n = s.docsOf(l);
        status = 'Ready · $n ${n == 1 ? 'entry' : 'entries'}';
        color = k.ok;
      case LibraryPhase.opening:
        status = 'Opening…';
        color = k.secondary;
      case LibraryPhase.indexing:
        final f = s.indexFraction(l);
        status = f == null ? 'Building the search index…' : 'Building the search index ${(f * 100).toStringAsFixed(0)}%';
        color = k.secondary;
      case LibraryPhase.failed:
        status = s.failureOf(l) ?? 'Could not be opened';
        color = k.emergency;
      case LibraryPhase.waiting:
        status = s.sources.coreReady ? 'Waiting' : 'Not available';
        color = k.secondary;
    }
    final version = s.versionOf(l);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _info(l),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.titleOf(l), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                      const SizedBox(height: 2),
                      Text(
                        [formatBytes(l.size), if (version != null) 'Version $version', status].join(' · '),
                        style: TextStyle(fontSize: 15, color: color),
                      ),
                      if (phase == LibraryPhase.indexing) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: s.indexFraction(l)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.delete_outline, color: k.secondary),
                  onPressed: () => _confirmRemove(l),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for a library's download link.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog();

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Download link'),
        content: TextField(
          key: const ValueKey('library-link'),
          controller: _c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(key: const ValueKey('download-library'), onPressed: () => Navigator.pop(context, _c.text), child: const Text('Download')),
        ],
      );
}

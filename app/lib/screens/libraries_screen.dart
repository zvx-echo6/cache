import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../sources/libraries_state.dart';
import '../theme.dart';

/// Picks the settings file (cache-library.json) of a library that came without one; a test hook replaces it.
typedef PickSettingsFile = Future<String?> Function();

Future<String?> _pickSettingsWithPicker() async => (await FilePicker.pickFile())?.path;

/// "Your own library", inside Add to Library: add a library from a file on the phone (a .cache-library file, a library snapshot, or a
/// .zim) or from a download link, with an update offered when the same library is added again, and the blank template to make your
/// own. What is added shows in the Library list.
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

  Future<void> _fromFile() => s.pickAndAdd(confirmUpdate: _confirmUpdate, askSettings: _askSettings);

  Future<void> _fromLink() async {
    final link = await showDialog<String>(context: context, builder: (_) => const _LinkDialog());
    if (link != null && link.trim().isNotEmpty) await s.addLink(link, confirmUpdate: _confirmUpdate, askSettings: _askSettings);
  }

  Future<void> _template() async {
    final saved = await s.saveTemplate();
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Template saved. Its README says how to fill it.')));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Your own library')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s, s.sources]),
        builder: (context, _) {
          final t = s.task;
          final busy = (t != null && t.running) || s.sources.copyProgress != null;
          final ready = s.sources.coreReady;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Text(
                  s.sources.unavailable ?? 'A library is a collection of passages Cache searches and cites. Add one you have, or make your own.',
                  style: TextStyle(fontSize: 13, color: k.secondary),
                ),
              ),
              if (t != null) _taskCard(k, t),
              if (s.sources.copyProgress != null) _copyCard(k),
              _row(k, key: 'add-from-file', icon: Icons.folder_open_outlined, title: 'From a file on this phone', detail: 'A .cache-library file, a library snapshot or a .zim', onTap: busy || !ready ? null : _fromFile),
              _row(k, key: 'add-from-link', icon: Icons.link, title: 'From a download link', detail: 'A link to a library file', onTap: busy || !ready ? null : _fromLink),
              if (s.error != null || s.sources.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(s.error ?? s.sources.error!, style: TextStyle(fontSize: 13, color: k.warning)),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('library-template'),
                  onPressed: s.makingTemplate || !ready ? null : _template,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: Text(s.makingTemplate ? 'Making the template…' : 'Get a blank library template'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(CacheTokens k, {required String key, required IconData icon, required String title, required String detail, VoidCallback? onTap}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey(key),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 22, color: onTap == null ? k.secondary : k.text),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: onTap == null ? k.secondary : k.text)),
                      Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: k.secondary),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _copyCard(CacheTokens k) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Copying ${s.sources.copyName ?? 'the file'}', style: TextStyle(fontSize: 14, color: k.text)),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: s.sources.copyProgress, minHeight: 3),
      ],
    ),
  );

  Widget _taskCard(CacheTokens k, AddTask t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: k.surface,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Adding ${t.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                const SizedBox(height: 4),
                if (t.running) ...[
                  Text(addStepText(t), style: TextStyle(fontSize: 13, color: k.secondary)),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: t.fraction, minHeight: 3),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(key: const ValueKey('cancel-add'), onPressed: s.cancelAdd, child: const Text('Cancel')),
                  ),
                ] else ...[
                  Text(t.error!, style: TextStyle(fontSize: 13, color: k.warning)),
                  Row(
                    children: [
                      if (t.blockedByMobileData && t.link != null)
                        TextButton(
                          key: const ValueKey('download-now'),
                          onPressed: () => s.addLink(t.link!, confirmUpdate: _confirmUpdate, askSettings: _askSettings, anyway: true),
                          child: const Text('Download now'),
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
}

/// What an add is doing, in words: "Downloading 40%", "Building the search index 70%".
String addStepText(AddTask t) {
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

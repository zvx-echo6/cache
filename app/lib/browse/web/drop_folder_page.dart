import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/settings/widgets.dart' show GroupLabel;
import '../../theme.dart';
import '../../layout/adaptive.dart' show ReadingWidth;
import 'two_column.dart';
import 'build_api.dart';
import 'build_common.dart';
import 'build_state.dart';
import 'compression_default_link.dart';
import 'build_text.dart';
import 'device_api.dart' show DeviceException;

/// The drop folder: one folder on the device whose three subfolders are a queue. Files copied into ingest/ are taken in order and moved
/// to complete/ or failed/. Settings on the left (folder, on or off, which library the PDFs go into), the key to the three subfolders and
/// the table of files on the right.
class DropFolderPage extends StatefulWidget {
  const DropFolderPage({super.key, required this.build});

  final BuildController build;

  @override
  State<DropFolderPage> createState() => _DropFolderPageState();
}

enum _Show { all, queue, complete, failed }

class _DropFolderPageState extends State<DropFolderPage> {
  final TextEditingController _folder = TextEditingController();
  bool _changing = false;
  bool _seeded = false;
  String? _pickedLibrary;
  _Show _show = _Show.all;
  String? _error;
  bool _busy = false;

  BuildController get c => widget.build;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    c.watchDropFolder(true);
    unawaited(c.loadDrop().catchError((_) {}));
  }

  @override
  void dispose() {
    c.watchDropFolder(false);
    c.removeListener(_onChange);
    _folder.dispose();
    super.dispose();
  }

  void _onChange() {
    final d = c.drop;
    if (d != null && !_seeded) {
      _seeded = true;
      _folder.text = d.settings.folder;
    }
    if (mounted) setState(() {});
  }

  Future<void> _do(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on DeviceException catch (e) {
      if (mounted) setState(() => _error = callWords(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  String? get _libraryId => _pickedLibrary ?? c.drop?.settings.libraryId;

  @override
  Widget build(BuildContext context) {
    final d = c.drop;
    return Scaffold(
      appBar: pageBar(context, 'Drop folder'),
      body: d == null
          ? Center(child: Text(c.problem ?? 'One moment…', style: TextStyle(color: context.t.secondary)))
          : (d.settings.enabled && !_changing) ? ScrollingTwoColumn(left: _active(context, d), right: _table(context, d)) : ScrollingTwoColumn(left: _setup(context, d), right: _explain(context)),
    );
  }

  // ---- on: the status, the folder, where PDFs go

  Widget _active(BuildContext context, DropState d) {
    final k = context.t;
    final err = d.status.error;
    final missing = err != null && err.code != 'no_library';
    final status = d.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompressionDefaultLink(build: c),
        if (err != null) _banner(context, err),
        PanelCard(
          key: const ValueKey('drop-status'),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(missing ? 'Waiting for the folder' : 'On', style: TextStyle(fontSize: 15, color: k.text)),
                Small(status.lastCheck == null ? 'Not checked yet' : 'Last checked ${addedWords(status.lastCheck)}'),
              ]),
            ),
            OutlinedButton(key: const ValueKey('check-now'), onPressed: _busy ? null : () => _do(c.checkDrop), child: const Text('Check now')),
            const SizedBox(width: 10),
            Switch(key: const ValueKey('drop-switch'), value: true, onChanged: _busy ? null : (_) => _do(() => c.setDrop(enabled: false))),
          ]),
        ),
        const GroupLabel('Folder on this device'),
        PanelCard(
          child: Row(children: [
            Expanded(child: Text(d.settings.folder, key: const ValueKey('drop-folder-path'), style: TextStyle(fontSize: 14, color: k.text))),
            TextButton(key: const ValueKey('change-folder'), onPressed: () => setState(() => _changing = true), child: const Text('Change')),
          ]),
        ),
        const SizedBox(height: 8),
        _keyCard(context),
        const GroupLabel('PDFs go into'),
        _libraryCard(context, d),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(fontSize: 13, color: k.warning))),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(key: const ValueKey('turn-off'), onPressed: _busy ? null : () => _do(() => c.setDrop(enabled: false)), child: const Text('Turn off drop folder')),
        ),
      ],
    );
  }

  Widget _banner(BuildContext context, DropError e) {
    final k = context.t;
    final missing = e.code == 'missing';
    final noLibrary = e.code == 'no_library';
    final title = noLibrary ? e.message : (missing ? 'The drop folder is missing' : (e.code == 'denied' ? 'Cache can not read the drop folder' : e.message));
    final body = noLibrary
        ? 'PDFs are waiting in ingest/. Choose the library they go into, and Cache starts building them.'
        : (missing
            ? 'It may be on a USB disk that is not connected. Nothing is lost: files stay where they are and Cache looks again at the next check, or check now.'
            : (e.code == 'denied' ? 'Cache is not allowed to open this folder. Change who can read it on this device, or choose another folder.' : 'Nothing is lost: files stay where they are and Cache looks again at the next check.'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PanelCard(
        key: const ValueKey('drop-banner'),
        warnEdge: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
          const SizedBox(height: 4),
          Text(body, style: TextStyle(fontSize: 12, height: 1.4, color: k.text)),
          Row(children: [
            if (!noLibrary && missing) TextButton(key: const ValueKey('banner-check'), onPressed: _busy ? null : () => _do(c.checkDrop), child: const Text('Check now')),
            if (noLibrary) TextButton(key: const ValueKey('banner-library'), onPressed: () => _chooseLibrary(context), child: const Text('Choose a library')),
            if (!noLibrary) TextButton(key: const ValueKey('banner-folder'), onPressed: () => setState(() => _changing = true), child: const Text('Choose another folder')),
          ]),
        ]),
      ),
    );
  }

  Widget _keyCard(BuildContext context) {
    final k = context.t;
    Widget line(String name, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 90, child: Text(name, style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: k.accent))),
            Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.35, color: k.text))),
          ]),
        );
    return PanelCard(
      key: const ValueKey('drop-key'),
      child: Column(children: [
        line('ingest/', 'Drop files here. This is the queue.'),
        line('complete/', 'Added or built. Duplicates too, they are already in the library.'),
        line('failed/', 'Could not be used, with a note saying why.'),
      ]),
    );
  }

  Widget _libraryCard(BuildContext context, DropState d) {
    final k = context.t;
    final id = _libraryId;
    final lib = id == null ? null : c.library(id);
    return PanelCard(
      key: const ValueKey('drop-library'),
      onTap: () => _chooseLibrary(context),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lib?.title ?? d.settings.libraryTitle ?? 'Choose a library', style: TextStyle(fontSize: 15, color: lib == null && d.settings.libraryTitle == null ? k.warning : k.text)),
            if (lib != null) Small(bookCount(lib.books)),
          ]),
        ),
        Icon(Icons.chevron_right, color: k.secondary),
      ]),
    );
  }

  Future<void> _chooseLibrary(BuildContext context) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final libs = c.libraries;
        return SimpleDialog(
          key: const ValueKey('library-picker'),
          title: const Text('PDFs go into'),
          children: [
            if (libs.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(24, 0, 24, 16), child: Small('No library built from PDFs yet. Choose Build from your PDFs in Add to Library to make one.', size: 13)),
            for (final l in libs)
              SimpleDialogOption(
                key: ValueKey('pick-${l.id}'),
                onPressed: () => Navigator.pop(ctx, l.id),
                child: Row(children: [
                  Icon(l.id == _libraryId ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18, color: ctx.t.accent),
                  const SizedBox(width: 10),
                  Expanded(child: Text('${l.title} · ${bookCount(l.books)}')),
                ]),
              ),
          ],
        );
      },
    );
    if (picked == null || !mounted) return;
    final d = c.drop;
    if (d != null && d.settings.enabled && !_changing) {
      await _do(() => c.setDrop(libraryId: picked));
    } else {
      setState(() => _pickedLibrary = picked);
    }
  }

  // ---- off, or the folder being changed

  Widget _setup(BuildContext context, DropState d) {
    final k = context.t;
    final id = _libraryId;
    final ready = _folder.text.trim().isNotEmpty && id != null;
    final changing = d.settings.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompressionDefaultLink(build: c),
        const GroupLabel('Folder on this device'),
        TextField(
          key: const ValueKey('drop-folder-field'),
          controller: _folder,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: k.surface,
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.secondary.withValues(alpha: 0.5))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.accent, width: 2)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(6, 6, 6, 8),
          child: Small("The full path of the folder on this device. Cache makes it, and the three folders in it, if they do not exist."),
        ),
        _keyCard(context),
        const GroupLabel('PDFs go into'),
        _libraryCard(context, d),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('drop-error'), style: TextStyle(fontSize: 13, color: k.warning))),
        const SizedBox(height: 14),
        Row(children: [
          FilledButton(
            key: const ValueKey('turn-on'),
            onPressed: ready && !_busy
                ? () => _do(() async {
                      await c.setDrop(folder: _folder.text.trim(), libraryId: id, enabled: true);
                      if (mounted) {
                        setState(() {
                          _changing = false;
                          _pickedLibrary = null;
                        });
                      }
                    })
                : null,
            child: Text(changing ? 'Save' : 'Turn on drop folder'),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('setup-cancel'),
            onPressed: () {
              if (changing) {
                setState(() {
                  _changing = false;
                  _folder.text = d.settings.folder;
                });
              } else if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Cancel'),
          ),
        ]),
      ],
    );
  }

  Widget _explain(BuildContext context) {
    final k = context.t;
    Widget row(String a, String b, String cc, {bool last = false}) => Container(
          decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.2)))),
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(a, style: TextStyle(fontSize: 13, color: k.text))),
            Expanded(flex: 2, child: Text(b, style: TextStyle(fontSize: 12, color: k.secondary))),
            Expanded(flex: 5, child: Text(cc, style: TextStyle(fontSize: 13, height: 1.35, color: k.text))),
          ]),
        );
    final text = TextStyle(fontSize: 14, height: 1.5, color: k.text);
    return ReadingWidth(
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const GroupLabel('What the drop folder does with each file'),
          row('name.pdf', 'PDF', 'Built into a library, with the page and heading of each passage'),
          row('name.zim', 'Library file', 'Added to the Library, like a download'),
          row('name.cache-library, name.gz', 'Library file', 'Added or updated, like an upload'),
          row('Anything else', '', 'Moved to failed/ with a note: not a file Cache can use', last: true),
          const SizedBox(height: 18),
          const GroupLabel('Filling it'),
          Text('Copy files into ingest/ over the network with scp, or plug in a USB disk and copy them across. A file that is still being copied waits for a later check, once it stops changing. Hidden files and folders inside ingest/ are left alone.', style: text),
          const SizedBox(height: 10),
          Text('A PDF is handled the way an upload is: duplicates are skipped by content, every book shows its own progress, and one bad file never stops the rest.', style: text),
        ],
      ),
    );
  }

  // ---- the table of files

  Widget _table(BuildContext context, DropState d) {
    final k = context.t;
    final st = d.status;
    final ingest = [for (final f in d.files) if (f.folder == 'ingest') f];
    final failed = [for (final f in d.files) if (f.folder == 'failed') f];
    final complete = [for (final f in d.files) if (f.folder == 'complete') f];
    ingest.sort((a, b) => _order(a).compareTo(_order(b)));
    Widget chip(String label, _Show s) => Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: ChoiceChip(key: ValueKey('chip-${s.name}'), label: Text(label), selected: _show == s, onSelected: (_) => setState(() => _show = s), visualDensity: VisualDensity.compact),
        );
    final found = st.found;
    final line = st.stale
        ? 'Last known state. Nothing has been checked since the folder went missing.'
        : (st.lastCheck == null ? 'Not checked yet.' : 'Last check ${addedWords(st.lastCheck)}: ${found == 0 ? 'nothing new' : (found == 1 ? '1 new file found' : '$found new files found')}.');
    return LayoutBuilder(builder: (context, cts) {
      final wide = cts.maxWidth >= 600;
      return Opacity(
        opacity: st.stale ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(children: [
              chip('All · ${thousands(st.all)}', _Show.all),
              chip('Queue in ingest/ · ${thousands(st.queue)}', _Show.queue),
              chip('complete/ · ${thousands(st.complete)}', _Show.complete),
              chip('failed/ · ${thousands(st.failed)}', _Show.failed),
            ]),
            Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 6), child: Small(line, key: const ValueKey('drop-last-check'), size: 13)),
            if (d.files.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Small('No files yet. Copy PDFs into ingest/ and they appear here.', size: 13)),
            if (wide && d.files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Row(children: [
                  SizedBox(width: 36, child: _h(k, '#', end: true)),
                  const SizedBox(width: 12),
                  Expanded(flex: 4, child: _h(k, 'File')),
                  Expanded(flex: 2, child: _h(k, 'Type')),
                  Expanded(flex: 5, child: _h(k, 'State')),
                  const SizedBox(width: 70),
                ]),
              ),
            if (_show == _Show.all || _show == _Show.queue) _group(context, 'Queue · in the order Cache takes them', ingest, wide, numbered: true),
            if (_show == _Show.all || _show == _Show.failed) _group(context, 'Failed · in failed/', failed, wide),
            if (_show == _Show.all || _show == _Show.complete) _group(context, 'Complete · in complete/, newest first', complete, wide),
            if (failed.isNotEmpty && _show != _Show.complete && _show != _Show.queue)
              const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 0), child: Small('Retry moves a file back into ingest/, at the end of the queue.', size: 13)),
          ],
        ),
      );
    });
  }

  int _order(DropFile f) {
    if (f.state == 'working') return -1;
    return f.position ?? (1 << 20);
  }

  Widget _h(CacheTokens k, String t, {bool end = false}) => Text(t, textAlign: end ? TextAlign.end : TextAlign.start, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.secondary));

  Widget _group(BuildContext context, String title, List<DropFile> files, bool wide, {bool numbered = false}) {
    if (files.isEmpty) return const SizedBox.shrink();
    final k = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(0, 10, 0, 2), child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: k.text))),
        Divider(height: 1, color: k.secondary.withValues(alpha: 0.3)),
        for (var i = 0; i < files.length; i++) _fileRow(context, files[i], wide, numbered ? (files[i].position ?? i + 1) : null),
      ],
    );
  }

  String _state(DropFile f) {
    switch (f.state) {
      case 'new':
        return 'New. Cache takes it once it has stopped changing.';
      case 'queued':
        return 'Queued';
      case 'working':
        final p = f.progress;
        if (p == null) return 'Working';
        final t = p.piecesTotal;
        return t == null ? 'Working · reading the PDF' : 'Working · building passages ${thousands(p.pieces)} of ${thousands(t)}';
      case 'duplicate':
        return f.reason ?? 'Duplicate: the same content is already in the library';
      case 'unsupported':
        return '${f.reason ?? 'Not a file Cache can use'}. Note: ${f.name}.why.txt';
      case 'failed':
        final r = f.reason ?? 'Could not be used';
        // Each file in failed/ has a note beside it, `<name>.why.txt`.
        return f.folder == 'failed' ? '$r. Note: ${f.name}.why.txt' : r;
      default:
        final n = f.name.toLowerCase();
        final base = n.endsWith('.pdf') ? 'Built into the library' : 'Added to the Library';
        return f.note != null ? '$base · ${f.note}' : base;
    }
  }

  Widget _fileRow(BuildContext context, DropFile f, bool wide, int? n) {
    final k = context.t;
    final bad = f.state == 'failed';
    final quiet = f.state == 'unsupported';
    final color = bad ? k.warning : (quiet ? k.secondary : k.text);
    final retry = f.canRetry
        ? TextButton(key: ValueKey('drop-retry-${f.name}'), onPressed: _busy ? null : () => _do(() => c.retryDrop(f.name)), child: const Text('Retry'))
        : const SizedBox(width: 0);
    final frac = f.progress == null ? null : queueFraction(QueueItem(id: '', libraryId: '', fileName: '', state: 'building', progress: f.progress!));
    return Container(
      key: ValueKey('drop-file-${f.name}'),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.18)))),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 36, child: Text(n == null ? '' : '$n', textAlign: TextAlign.end, style: TextStyle(fontSize: 13, color: k.secondary))),
              const SizedBox(width: 12),
              Expanded(flex: 4, child: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.text))),
              Expanded(flex: 2, child: Text(dropKindWords(f), style: TextStyle(fontSize: 12, color: k.secondary))),
              Expanded(
                flex: 5,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_state(f), style: TextStyle(fontSize: 12, height: 1.35, color: color)),
                  if (f.state == 'working') Padding(padding: const EdgeInsets.only(top: 4), child: SlimBar(value: frac, height: 3)),
                ]),
              ),
              SizedBox(width: 70, child: Align(alignment: Alignment.centerRight, child: retry)),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${n == null ? '' : '$n. '}${f.name}', style: TextStyle(fontSize: 14, color: k.text)),
              Text('${dropKindWords(f)} · ${_state(f)}', style: TextStyle(fontSize: 12, height: 1.35, color: color)),
              if (f.state == 'working') Padding(padding: const EdgeInsets.only(top: 4), child: SlimBar(value: frac, height: 3)),
              if (f.canRetry) Align(alignment: Alignment.centerLeft, child: retry),
            ]),
    );
  }
}

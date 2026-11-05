import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/settings/widgets.dart' show GroupLabel;
import '../../theme.dart';
import '../../video/format.dart' show formatBytes;
import 'two_column.dart';
import 'build_api.dart';
import 'build_common.dart';
import 'build_state.dart';
import 'build_text.dart';
import 'build_shelves.dart';
import 'device_api.dart' show DeviceException;
import 'device_widgets.dart' show HoverReveal;
import 'local_files.dart';

/// One library built from PDFs, opened: its books as a table, the queue of what is still being built, Add PDFs, and the library's own
/// menu (rename). In two columns on a wide window: counts, Add PDFs and the queue on the left, the books on the right.
class BuiltLibraryPage extends StatefulWidget {
  const BuiltLibraryPage({super.key, required this.build, required this.libraryId});

  final BuildController build;
  final String libraryId;

  @override
  State<BuiltLibraryPage> createState() => _BuiltLibraryPageState();
}

class _BuiltLibraryPageState extends State<BuiltLibraryPage> {
  String? _editing;
  final TextEditingController _title = TextEditingController();
  bool _showWaiting = false;
  List<BuildClass>? _classes;
  String? _classesError;
  String? _division;
  String? _bookNumber;
  final TextEditingController _number = TextEditingController();

  Future<void> _loadClasses() async {
    final api = c.api;
    if (api is! BuildFilingApi) return;
    try {
      final classes = await api.classes(id);
      if (mounted) setState(() { _classes = classes; _classesError = null; });
    } on DeviceException catch (e) {
      if (mounted) setState(() => _classesError = callWords(e));
    }
  }


  BuildController get c => widget.build;
  String get id => widget.libraryId;

  @override
  void initState() {
    super.initState();
    c.watchBooks(id);
    c.sink = _drop;
    c.addListener(_onChange);
    unawaited(_loadClasses());
  }

  @override
  void dispose() {
    c.unwatchBooks(id);
    if (c.sink == _drop) c.sink = null;
    c.removeListener(_onChange);
    _title.dispose();
    _number.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// PDFs dropped while this page is open join this library.
  void _drop(List<LocalFile> files) => unawaited(_add(files));

  Future<void> _add(List<LocalFile> files) async {
    try {
      final u = await c.addFiles(files, libraryId: id);
      if (u != null && mounted) say(context, 'Uploading ${u.count} ${u.count == 1 ? 'PDF' : 'PDFs'}. Keep this tab open.');
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }

  Future<void> _addPdfs() async {
    final files = await c.pickPdfs();
    if (files.isEmpty || !mounted) return;
    await _add(files);
  }

  @override
  Widget build(BuildContext context) {
    final lib = c.library(id);
    if (lib == null) {
      return Scaffold(
        appBar: pageBar(context, 'Library'),
        body: Center(child: Text(c.loaded ? 'This library is not on this device any more.' : 'One moment…', style: TextStyle(color: context.t.secondary))),
      );
    }
    return Scaffold(
      appBar: pageBar(context, lib.title, actions: [
        PopupMenuButton<String>(
          key: const ValueKey('library-menu'),
          tooltip: 'More',
          icon: const Icon(Icons.more_horiz),
          onSelected: (v) {
            if (v == 'rename') unawaited(_renameLibrary(lib));
          },
          itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename library'))],
        ),
      ]),
      body: ScrollingTwoColumn(left: _left(context, lib), right: _right(context, lib)),
    );
  }

  // ---- left: counts, Add PDFs, the queue or the facts

  Widget _left(BuildContext context, BuildLibrary lib) {
    final books = c.books[id];
    final building = c.isBuilding(id);
    final n = books?.length ?? lib.books;
    final passages = books == null ? lib.passages : books.fold<int>(0, (s, b) => s + b.passages);
    final counts = n == 0 && !building ? 'No books yet' : '${bookCount(n)} · ${thousands(passages)} passages · built from your PDFs';
    final up = c.upload;
    final mine = up != null && up.libraryId == id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 4, 4, 8), child: Text(counts, key: const ValueKey('library-counts'), style: TextStyle(fontSize: 13, color: context.t.secondary))),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(key: const ValueKey('add-pdfs'), onPressed: mine && up.running ? null : _addPdfs, icon: const Icon(Icons.add, size: 18), label: const Text('Add PDFs')),
        ),
        const SizedBox(height: 10),
        if (c.notice != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(c.notice!, style: TextStyle(fontSize: 13, color: context.t.warning))),
        if (mine && up.running) _uploadCard(context, up),
        if (building || c.itemsOf(id).any((i) => i.needsAttention || i.skipped)) _queue(context, lib) else if (n > 0) _facts(context, lib),
        if (_classes != null) ...[
          const SizedBox(height: 16),
          BuildShelves(
            classes: _classes!,
            books: books ?? const [],
            selected: _division,
            onSelect: (division) => setState(() { _division = division; _bookNumber = null; }),
            number: _number,
            onGo: _goToNumber,
          ),
        ],
        if (_classesError != null) ...[
          Small(_classesError!, warn: true),
          TextButton(onPressed: _loadClasses, child: const Text('Try again')),
        ],
        if (lib.publishError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(lib.publishError!, style: TextStyle(fontSize: 12, color: context.t.warning))),
      ],
    );
  }

  Widget _uploadCard(BuildContext context, BuildUpload u) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PanelCard(
        key: const ValueKey('library-upload'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(u.replaceDocId != null ? 'Uploading the new copy of ${u.replaceTitle}' : 'Uploading ${thousands(u.count)} ${u.count == 1 ? 'PDF' : 'PDFs'}', style: TextStyle(fontSize: 15, color: k.text)),
                Small('${thousands(u.doneCount)} of ${thousands(u.count)} sent · ${formatBytes(u.sentBytes)} of ${formatBytes(u.totalBytes)}'),
              ]),
            ),
            TextButton(onPressed: c.cancelUpload, child: const Text('Cancel')),
          ]),
          const SizedBox(height: 6),
          SlimBar(value: u.finishing ? null : u.fraction, height: 6),
          const SizedBox(height: 6),
          const Small('Keep this tab open until the upload ends.'),
        ]),
      ),
    );
  }

  Widget _facts(BuildContext context, BuildLibrary lib) {
    final k = context.t;
    final bytes = c.sizeOf?.call(lib.id);
    final rows = <(String, String)>[
      ('Books', thousands(lib.books)),
      ('Passages', thousands(lib.passages)),
      if (lib.pages > 0) ('Pages', thousands(lib.pages)),
      if (bytes != null && bytes > 0) ('Size on this device', formatBytes(bytes)),
      if (lib.createdAt != null) ('Started', dateWords(lib.createdAt)),
    ];
    return PanelCard(
      key: const ValueKey('library-facts'),
      child: Column(children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 120, child: Text(r.$1, style: TextStyle(fontSize: 13, color: k.secondary))),
              Expanded(child: Text(r.$2, style: TextStyle(fontSize: 13, color: k.text))),
            ]),
          ),
      ]),
    );
  }

  // ---- the queue panel: only work that is not finished

  Widget _queue(BuildContext context, BuildLibrary lib) {
    final k = context.t;
    final q = c.queue;
    final items = c.itemsOf(id);
    final p = c.progressOf(id);
    final active = items.where((i) => i.active).toList();
    final waiting = items.where((i) => i.waiting).toList();
    final attention = items.where((i) => i.needsAttention || i.skipped).toList();
    final building = c.isBuilding(id);
    final paused = q.paused && building;
    final needs = p.attention;
    final skipped = items.where((i) => i.skipped).length;
    final head = paused ? 'Building is paused' : (building ? 'Building ${lib.title}' : 'Needs a look');
    final doneLine = [
      '${thousands(p.finished)} of ${thousands(p.total)} books done',
      if (needs > 0) '$needs need attention',
      if (skipped > 0) '$skipped skipped',
    ].join(' · ');
    final sub = paused ? '$doneLine. Finished books are kept.' : doneLine;
    final eta = q.etaLow != null && q.etaHigh != null && building && !paused ? 'Roughly ${etaRange(q.etaLow!, q.etaHigh!)} left. This is an estimate and gets better as books finish; scanned books take longer.' : null;
    return PanelCard(
      key: const ValueKey('queue-panel'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(head, key: const ValueKey('queue-head'), style: TextStyle(fontSize: 15, color: k.text)),
                Small(sub),
                if (q.blocked != null && building) Padding(padding: const EdgeInsets.only(top: 2), child: Small(_cap(q.blocked!), warn: true)),
              ]),
            ),
            if (building) ...[
              const SizedBox(width: 8),
              if (paused)
                FilledButton.icon(key: const ValueKey('resume-queue'), onPressed: () => _call(c.resume), icon: const Icon(Icons.play_arrow, size: 18), label: const Text('Resume'))
              else
                OutlinedButton.icon(key: const ValueKey('pause-queue'), onPressed: _pause, icon: const Icon(Icons.pause, size: 16), label: const Text('Pause')),
              const SizedBox(width: 6),
              OutlinedButton(key: const ValueKey('stop-queue'), onPressed: () => _stop(lib), child: const Text('Stop')),
            ],
          ]),
          if (p.total > 0) ...[
            const SizedBox(height: 8),
            SlimBar(value: p.total == 0 ? 0 : p.finished / p.total, paused: paused, height: 6),
          ],
          if (paused) const Padding(padding: EdgeInsets.only(top: 4), child: Small('Time left is not counted while paused.')),
          if (eta != null) Padding(padding: const EdgeInsets.only(top: 4), child: Small(eta, key: const ValueKey('queue-eta'))),
          const SizedBox(height: 4),
          for (final i in active) _queueRow(k, i, paused: paused),
          for (final i in attention) _queueRow(k, i, paused: false),
          if (waiting.isNotEmpty) _waiting(k, waiting),
        ],
      ),
    );
  }

  Future<void> _pause() async {
    await _call(c.pause);
    if (mounted) say(context, 'Building paused. Resume it any time; finished books are kept.');
  }

  String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  Future<void> _call(Future<void> Function() f) async {
    try {
      await f();
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }

  Widget _waiting(CacheTokens k, List<QueueItem> waiting) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 4, 0, 0),
          child: Row(children: [
            Expanded(child: Text('${thousands(waiting.length)} more waiting', key: const ValueKey('more-waiting'), style: TextStyle(fontSize: 12, color: k.secondary))),
            TextButton(key: const ValueKey('show-waiting'), onPressed: () => setState(() => _showWaiting = !_showWaiting), child: Text(_showWaiting ? 'Hide' : 'Show')),
          ]),
        ),
        if (_showWaiting)
          for (final i in waiting.take(50))
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Row(children: [
                Expanded(child: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.text))),
                IconButton(key: ValueKey('cancel-${i.id}'), tooltip: 'Take off the list', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16), onPressed: () => _call(() => c.dismiss(i.id))),
              ]),
            ),
        if (_showWaiting && waiting.length > 50) Padding(padding: const EdgeInsets.only(left: 40, bottom: 6), child: Small('and ${thousands(waiting.length - 50)} more')),
      ],
    );
  }

  Widget _queueRow(CacheTokens k, QueueItem i, {required bool paused}) {
    final frac = queueFraction(i);
    final warn = i.needsAttention;
    final line = paused && i.active ? 'Paused · ${queueStateWords(i).toLowerCase()}' : queueStateWords(i);
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: k.secondary.withValues(alpha: 0.18)))),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BookLetter(i.name),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.text)),
            Small(line, warn: warn),
            if (i.active) Padding(padding: const EdgeInsets.only(top: 4), child: SlimBar(value: frac, paused: paused, height: 3)),
          ]),
        ),
        if (warn) TextButton(key: ValueKey('retry-${i.id}'), onPressed: () => _call(() => c.retry(i.id)), child: const Text('Retry')),
        if (warn || i.skipped) TextButton(key: ValueKey('dismiss-${i.id}'), onPressed: () => _call(() => c.dismiss(i.id)), child: Text('Dismiss', style: TextStyle(color: k.secondary))),
      ]),
    );
  }

  // ---- right: the books

  Widget _right(BuildContext context, BuildLibrary lib) {
    final k = context.t;
    final all = c.books[id];
    final books = all == null ? null : ([
      for (final b in all)
        if ((_division == null || (_division == 'unsorted' ? b.unsorted : b.division == _division)) && (_bookNumber == null || b.callNumber == _bookNumber)) b,
    ]..sort(compareShelfBooks));
    final building = c.isBuilding(id);
    if (books == null) return Padding(padding: const EdgeInsets.all(24), child: Small('One moment…', size: 13));
    if (books.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(children: [
          Icon(Icons.library_books, size: 40, color: k.secondary),
          const SizedBox(height: 12),
          Text(_division == null ? 'No books in this library yet.' : 'No books in this division.', style: TextStyle(fontSize: 13, color: k.secondary)),
          const SizedBox(height: 2),
          Text(_division == null ? 'Add PDFs and Cache builds them one at a time.' : 'Choose another division or add books to this one.', style: TextStyle(fontSize: 13, color: k.secondary)),
          Text('It keeps going if you close this tab.', style: TextStyle(fontSize: 13, color: k.secondary)),
        ]),
      );
    }
    return LayoutBuilder(builder: (context, cts) {
      final table = cts.maxWidth >= 560;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('${lib.title} / ${_division == null ? 'All books' : shelfLabel(_division!, _classes ?? const [])}', style: TextStyle(color: k.secondary, fontSize: 12)),
          ),
          GroupLabel('${building ? 'Finished books' : 'Books'} · ${thousands(books.length)}'),
          if (table)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: Row(children: [
                const SizedBox(width: 38),
                Expanded(child: _head(k, 'Title')),
                SizedBox(width: 70, child: _head(k, 'Pages', end: true)),
                SizedBox(width: 90, child: _head(k, 'Passages', end: true)),
                SizedBox(width: 100, child: Padding(padding: const EdgeInsets.only(left: 12), child: _head(k, 'Added'))),
                const SizedBox(width: 80),
              ]),
            ),
          Divider(height: 1, color: k.secondary.withValues(alpha: 0.25)),
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.65,
            child: ListView.builder(
              key: ValueKey('shelf-${_division ?? 'all'}'),
              primary: false,
              itemCount: books.length,
              itemBuilder: (context, index) => _bookRow(context, lib, books[index], table),
            ),
          ),
        ],
      );
    });
  }

  Widget _head(CacheTokens k, String t, {bool end = false}) => Text(t, textAlign: end ? TextAlign.end : TextAlign.start, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.secondary));

  Widget _bookRow(BuildContext context, BuildLibrary lib, BuildBook b, bool table) {
    final k = context.t;
    if (_editing == b.id) return _editRow(context, lib, b);
    final menu = PopupMenuButton<String>(
      key: ValueKey('book-menu-${b.id}'),
      tooltip: 'More',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (v) {
        if (v == 'replace') unawaited(_replace(lib, b));
        if (v == 'place') unawaited(_placeBook(b));
        if (v == 'remove') unawaited(_remove(lib, b));
      },
      itemBuilder: (_) => [
        if (_classes != null) const PopupMenuItem(value: 'place', child: Text('Place it')),
        const PopupMenuItem(value: 'replace', child: Text('Replace with a newer edition')),
        const PopupMenuItem(value: 'remove', child: Text('Remove')),
      ],
    );
    // The buttons stay mounted while the pointer is away (only hidden): the menu that was opened from "..." is still waiting for its
    // choice when the pointer leaves the row for it.
    Widget actions(bool hover) => SizedBox(
          width: 80,
          child: Visibility(
            visible: hover || !table,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              IconButton(key: ValueKey('edit-${b.id}'), tooltip: 'Edit title', visualDensity: VisualDensity.compact, icon: const Icon(Icons.edit, size: 16), onPressed: () => _startEdit(b)),
              SizedBox(width: 34, height: 34, child: menu),
            ]),
          ),
        );
    Widget row(bool hover) => Container(
          key: ValueKey('book-${b.id}'),
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: hover ? k.surface : null, borderRadius: BorderRadius.circular(12)),
          child: table
              ? Row(children: [
                  BookLetter(b.title),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _bookTitle(context, b, lines: 1),
                      if (b.unsorted && _classes != null) TextButton(onPressed: () => _placeBook(b), child: const Text('Place it')),
                      if (b.unsorted && b.unsureReason != null) Small(b.unsureReason!, size: 11),
                      if (b.replacing) Small('Replacing with a new copy', size: 11) else if (b.partial != null) Small(b.partial!, size: 11, warn: true),
                    ]),
                  ),
                  SizedBox(width: 70, child: Text('${b.pages}', textAlign: TextAlign.end, style: TextStyle(fontSize: 13, color: k.secondary))),
                  SizedBox(width: 90, child: Text(thousands(b.passages), textAlign: TextAlign.end, style: TextStyle(fontSize: 13, color: k.secondary))),
                  SizedBox(width: 100, child: Padding(padding: const EdgeInsets.only(left: 12), child: Text(addedWords(b.addedAt), style: TextStyle(fontSize: 13, color: k.secondary)))),
                  actions(hover),
                ])
              : Row(children: [
                  BookLetter(b.title),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _bookTitle(context, b, lines: 2),
                      Small('${b.pages} pages · ${thousands(b.passages)} passages · added ${addedWords(b.addedAt)}${b.replacing ? ' · replacing' : ''}'),
                    ]),
                  ),
                  actions(true),
                ]),
        );
    return table ? HoverReveal(builder: row) : row(false);
  }

  Widget _bookTitle(BuildContext context, BuildBook book, {int lines = 1}) => Text.rich(
    TextSpan(children: [
      if (book.callNumber != null) TextSpan(
        text: '${book.callNumber} · ',
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: context.t.secondary),
      ),
      TextSpan(text: book.title),
    ]),
    maxLines: lines,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 14, color: context.t.text),
  );

  void _goToNumber() {
    final text = _number.text.trim().toUpperCase();
    final raw = text.startsWith('CDS ') ? text.substring(4) : text;
    final division = raw.split('-').first;
    if ((_classes ?? const <BuildClass>[]).expand((c) => c.divisions).any((d) => d.number == division)) {
      final target = raw.contains('-') ? 'CDS $raw' : null;
      if (target != null && !(c.books[id] ?? const <BuildBook>[]).any((b) => b.callNumber == target)) {
        say(context, 'That book number is not in this library.');
        return;
      }
      setState(() { _division = division; _bookNumber = target; });
    } else {
      say(context, 'There is no division with that number.');
    }
  }

  Future<void> _placeBook(BuildBook book) async {
    final api = c.api;
    if (api is! BuildFilingApi || _classes == null) return;
    final division = await showDialog<String>(
      context: context,
      builder: (_) => PlaceBookDialog(book: book, classes: _classes!),
    );
    if (division == null || !mounted) return;
    try {
      await api.placeBook(id, book.id, division);
      await c.refresh();
      if (mounted) say(context, 'Placed in ${shelfLabel(division, _classes!)}.');
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }

  // ---- edit a title in place

  void _startEdit(BuildBook b) {
    _title.text = b.title;
    setState(() => _editing = b.id);
  }

  Widget _editRow(BuildContext context, BuildLibrary lib, BuildBook b) {
    final k = context.t;
    final usesFileName = b.title == b.fileStem && b.fileName.isNotEmpty;
    return Container(
      key: ValueKey('book-edit-${b.id}'),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('title-field'),
              controller: _title,
              autofocus: true,
              onSubmitted: (_) => _saveTitle(lib, b),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: k.background,
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.secondary.withValues(alpha: 0.5))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.accent, width: 2)),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (b.fileName.isNotEmpty) TextButton(key: const ValueKey('use-file-name'), onPressed: () => setState(() => _title.text = b.fileStem), child: const Text('Use file name')),
          TextButton(key: const ValueKey('cancel-title'), onPressed: () => setState(() => _editing = null), child: Text('Cancel', style: TextStyle(color: k.secondary))),
          FilledButton(key: const ValueKey('save-title'), onPressed: () => _saveTitle(lib, b), child: const Text('Save')),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 2),
          child: Small(usesFileName
              ? 'This PDF has no title inside it, so the file name is used: ${b.fileName}. Only this title changes; the passages are not rebuilt.'
              : 'Only this title changes. The passages are not rebuilt.'),
        ),
      ]),
    );
  }

  Future<void> _saveTitle(BuildLibrary lib, BuildBook b) async {
    final t = _title.text.trim();
    if (t.isEmpty) return;
    try {
      if (t != b.title) await c.renameBook(lib.id, b.id, t);
      if (!mounted) return;
      setState(() => _editing = null);
      say(context, 'Title changed.');
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }

  // ---- remove, replace, rename, stop

  Future<void> _remove(BuildLibrary lib, BuildBook b) async {
    final free = c.freeSpace?.call();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final k = ctx.t;
        return AlertDialog(
          key: const ValueKey('remove-dialog'),
          title: Text('Remove ${b.title} from ${lib.title}?'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Frees', style: TextStyle(fontSize: 14, color: k.text)),
                  Flexible(child: Text('${b.size > 0 ? '${formatBytes(b.size)} · ' : ''}${thousands(b.passages)} passages', textAlign: TextAlign.end, style: TextStyle(fontSize: 14, color: k.text))),
                ]),
                if (free != null && b.size > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Small('Device storage'),
                      const SizedBox(width: 12),
                      Flexible(child: Text('${formatBytes(free)} free now, ${formatBytes(free + b.size)} after', textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: k.secondary))),
                    ]),
                  ),
                const SizedBox(height: 8),
                const Small('Only this book is removed. The rest of the library is not touched. Your PDF on this computer is not deleted. To get it back, add the PDF again.', size: 13),
              ],
            ),
          ),
          actions: [
            TextButton(key: const ValueKey('remove-cancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('remove-confirm'), style: dangerStyle(ctx), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    try {
      await c.removeBook(lib.id, b.id);
      if (mounted) say(context, 'Book removed.');
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }

  Future<void> _replace(BuildLibrary lib, BuildBook b) async {
    final saved = c.sink;
    final file = await showDialog<LocalFile>(
      context: context,
      builder: (ctx) => _ReplaceDialog(build: c, book: b),
    );
    c.sink = saved;
    if (file == null || !mounted) return;
    try {
      final u = await c.replaceBook(lib.id, b, file);
      if (u != null && mounted) say(context, 'Uploading the new copy of ${b.title}. Keep this tab open.');
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }

  Future<void> _renameLibrary(BuildLibrary lib) async {
    final done = await showDialog<bool>(context: context, builder: (ctx) => _RenameDialog(build: c, library: lib));
    if (done == true && mounted) say(context, 'Library renamed.');
  }

  Future<void> _stop(BuildLibrary lib) async {
    try {
      await c.loadDrop();
    } on DeviceException {
      // Not known: the question is asked all the same.
    }
    if (!mounted) return;
    final p = c.progressOf(id);
    final waiting = p.waiting;
    final active = c.itemsOf(id).where((i) => i.active).length;
    final finished = c.library(id)?.books ?? 0;
    final dropOn = c.drop?.settings.enabled;
    var alsoOff = false;
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final k = ctx.t;
        return AlertDialog(
          key: const ValueKey('stop-dialog'),
          title: Text('Stop building ${lib.title}?'),
          content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'The ${thousands(waiting)} ${waiting == 1 ? 'book' : 'books'} still waiting ${waiting == 1 ? 'is' : 'are'} taken off the list. '
              'The ${thousands(finished)} finished ${finished == 1 ? 'book' : 'books'}${active > 0 ? ' and the one being built now' : ''} stay. You can add the PDFs again later.',
              style: TextStyle(fontSize: 14, height: 1.4, color: k.text),
            ),
            if (dropOn != false) ...[
              const SizedBox(height: 12),
              InkWell(
                key: const ValueKey('also-off'),
                onTap: () => set(() => alsoOff = !alsoOff),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Also turn off the drop folder', style: TextStyle(fontSize: 14, color: k.text)),
                      const Small('Otherwise PDFs in it are picked up again at the next check.'),
                    ]),
                  ),
                  Checkbox(value: alsoOff, onChanged: (v) => set(() => alsoOff = v ?? false)),
                ]),
              ),
            ],
          ])),
          actions: [
            TextButton(key: const ValueKey('keep-building'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep building')),
            FilledButton(key: const ValueKey('stop-confirm'), style: dangerStyle(ctx), onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop building')),
          ],
        );
      }),
    );
    if (stop != true || !mounted) return;
    try {
      await c.stop(alsoDropFolderOff: alsoOff);
    } on DeviceException catch (e) {
      if (mounted) say(context, callWords(e));
    }
  }
}

/// "Replace [book] with a newer edition": one PDF, dropped here or chosen. Pops with the file.
class _ReplaceDialog extends StatefulWidget {
  const _ReplaceDialog({required this.build, required this.book});

  final BuildController build;
  final BuildBook book;

  @override
  State<_ReplaceDialog> createState() => _ReplaceDialogState();
}

class _ReplaceDialogState extends State<_ReplaceDialog> {
  String? _problem;

  @override
  void initState() {
    super.initState();
    widget.build.sink = _take;
  }

  void _take(List<LocalFile> files) {
    final pdfs = splitPdfs(files).pdfs;
    if (pdfs.isEmpty) {
      setState(() => _problem = 'That is not a PDF. Choose one PDF.');
      return;
    }
    if (pdfs.length > 1) {
      setState(() => _problem = 'Choose one PDF. Only this book is rebuilt.');
      return;
    }
    Navigator.pop(context, pdfs.first);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return AlertDialog(
      key: const ValueKey('replace-dialog'),
      title: Text('Replace ${widget.book.title} with a newer edition?'),
      content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Choose the new PDF. Only this book is rebuilt. The current one stays searchable until the new one is ready, then it is swapped in.', style: TextStyle(fontSize: 14, height: 1.4, color: k.text)),
        const SizedBox(height: 12),
        DashedBox(
          radius: 14,
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(Icons.upload, size: 28, color: k.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Drop the new PDF here', style: TextStyle(fontSize: 14, color: k.text)),
                const Small('One PDF.'),
              ]),
            ),
            OutlinedButton(
              key: const ValueKey('choose-one-pdf'),
              onPressed: () async {
                final files = await widget.build.pickPdfs();
                if (files.isNotEmpty && mounted) _take(files);
              },
              child: const Text('Choose a PDF'),
            ),
          ]),
        ),
        if (_problem != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_problem!, style: TextStyle(fontSize: 12, color: k.warning))),
      ])),
      actions: [TextButton(key: const ValueKey('replace-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

/// Rename library: one name field; a name another library has is refused with the reason.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.build, required this.library});

  final BuildController build;
  final BuildLibrary library;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.library.title);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    final other = widget.build.libraryNamed(t);
    if (other != null && other.id != widget.library.id) {
      setState(() => _error = 'You already have a library called "${other.title}". Choose another name.');
      return;
    }
    try {
      await widget.build.renameLibrary(widget.library.id, t);
      if (mounted) Navigator.pop(context, true);
    } on DeviceException catch (e) {
      if (mounted) setState(() => _error = callWords(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return AlertDialog(
      key: const ValueKey('rename-dialog'),
      title: const Text('Rename library'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(key: const ValueKey('rename-field'), controller: _text, autofocus: true, onSubmitted: (_) => _save(), decoration: const InputDecoration(labelText: 'Library name')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, key: const ValueKey('rename-error'), style: TextStyle(fontSize: 12, color: k.warning))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('rename-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../layout/layout_state.dart';
import '../../maps/user_layers.dart';
import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/places.dart';
import '../../theme.dart';
import 'entry_editor.dart';
import 'field_inputs.dart';
import 'notebook_editor.dart';
import 'notebook_search_screen.dart';
import 'places_screen.dart';
import 'quick_add_sheet.dart';

/// What the Notebooks screens need besides the store: places, Home shortcuts and the map.
class NotebookDeps {
  const NotebookDeps({
    required this.notebook,
    required this.places,
    this.layout,
    this.placesDeps,
    this.userLayers,
    this.now = DateTime.now,
  });

  final NotebookState notebook;
  final PlaceChoices places;

  /// Home's shortcuts ("Add to Home"); null leaves it out.
  final LayoutState? layout;

  /// The Places notebooks' weather and alert switches, map and directions; null leaves them out.
  final PlaceNotebookDeps? placesDeps;

  /// The user's repeater lists and the lines and areas kept with Places notebooks (the same store as the places); null leaves
  /// them out.
  final UserLayersState? userLayers;

  final DateTime Function() now;
}

/// Opens one entry where it is edited: a log's in its quick add sheet, a place on its place screen, any other in the entry
/// editor.
void openNotebookEntry(BuildContext context, NotebookDeps deps, Notebook book, NbEntry e) {
  if (book.isLog && !e.draft) {
    showQuickAdd(context, notebook: deps.notebook, log: book, places: deps.places, entry: e, now: deps.now);
  } else if (book.isPlaces) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaceView(deps: deps, book: book, entryId: e.id)));
  } else {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EntryEditor(notebook: deps.notebook, book: book, places: deps.places, entry: e, now: deps.now),
    ));
  }
}

/// The map's ring menu picked [book] at [at]: that notebook's full entry form at that spot (a place on the place screen, any
/// other entry, a log's too, in the entry editor).
void newNotebookEntryAt(BuildContext context, NotebookDeps deps, Notebook book, NbPlace at) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => book.isPlaces
        ? PlaceForm(deps: deps, book: book, at: at)
        : EntryEditor(notebook: deps.notebook, book: book, places: deps.places, at: at, now: deps.now),
  ));
}

/// One notebook, whatever its template: its entries listed the way its shape says (by date, last changed, or nearest first).
/// A Log notebook (shape quick_add) shows "Last done" and, when set, "Due again" on top, and makes entries in the quick add
/// sheet; the others open the entry editor.
class NotebookScreen extends StatefulWidget {
  const NotebookScreen({super.key, required this.deps, required this.notebookId});

  final NotebookDeps deps;
  final String notebookId;

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  NotebookState get nb => widget.deps.notebook;
  List<NbEntry>? _entries;
  int _readAt = -1;
  ({double lat, double lon})? _here;

  @override
  void initState() {
    super.initState();
    nb.addListener(_onChange);
    _read();
    widget.deps.places.here().then((h) {
      if (mounted && h != null) setState(() => _here = h);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    nb.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (nb.revision != _readAt) _read();
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    _readAt = nb.revision;
    try {
      final list = await nb.entries(widget.notebookId);
      if (mounted) setState(() => _entries = list);
    } catch (_) {
      if (mounted) setState(() => _entries = const []);
    }
  }

  void _open(Notebook book, NbEntry? e) {
    if (book.isLog && (e == null || !e.draft)) {
      showQuickAdd(context, notebook: nb, log: book, places: widget.deps.places, entry: e, now: widget.deps.now);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EntryEditor(notebook: nb, book: book, places: widget.deps.places, entry: e, now: widget.deps.now),
    ));
  }

  Future<void> _menu(Notebook book, String choice) async {
    switch (choice) {
      case 'edit':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookEditor(notebook: nb, existing: book)));
      case 'map':
        await nb.setOnMap(book, !book.map);
      case 'home':
        final l = widget.deps.layout;
        if (l == null) return;
        final added = l.addShortcut(Shortcut.notebook(id: book.id, name: book.name, log: book.isLog));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added ? 'Added to Home' : 'Already on Home')));
      case 'delete':
        final n = book.entryCount;
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text('Delete ${book.name} and its ${n == 1 ? '1 entry' : '$n entries'}? This can\'t be undone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(key: const ValueKey('confirm-delete'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (yes != true) return;
        widget.deps.layout?.removeShortcut(Shortcut.notebook(id: book.id, name: book.name, log: book.isLog));
        await nb.deleteNotebook(book.id);
        if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = nb.notebook(widget.notebookId);
    if (book == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This notebook is gone')));
    if (book.isPlaces) return PlacesNotebookScreen(deps: widget.deps, notebookId: book.id);
    final k = context.t;
    final now = widget.deps.now();
    final all = [for (final e in _entries ?? const <NbEntry>[]) if (!nb.isHidden(e.id)) e];
    final draft = book.isLog ? null : all.where((e) => e.draft).firstOrNull;
    final entries = [for (final e in all) if (!e.draft) e];
    return Scaffold(
      appBar: AppBar(
        title: Text(book.name),
        actions: [
          IconButton(
            key: const ValueKey('notebook-search'),
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => NotebookSearchScreen(deps: widget.deps, notebookId: book.id),
            )),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('notebook-menu'),
            onSelected: (c) => _menu(book, c),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit notebook')),
              if (book.placeCount > 0) PopupMenuItem(value: 'map', child: Text(book.map ? 'Hide on map' : 'Show on map')),
              if (widget.deps.layout != null) const PopupMenuItem(value: 'home', child: Text('Add to Home')),
              const PopupMenuItem(value: 'delete', child: Text('Delete notebook')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('notebook-add'),
        tooltip: book.isLog ? 'Add entry' : 'New entry',
        onPressed: () => _open(book, null),
        child: const Icon(Icons.add),
      ),
      body: _entries == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                if (book.isLog) _lastDone(book, now, k),
                if (draft != null)
                  Card(
                    key: const ValueKey('draft-card'),
                    child: ListTile(
                      title: Text('Unfinished entry · ${weekdayTimeText(draft.when)}'),
                      trailing: TextButton(onPressed: () => _open(book, draft), child: const Text('Continue')),
                    ),
                  ),
                if (entries.isEmpty && draft == null) _empty(book, k),
                ..._rows(book, entries, now, k),
              ],
            ),
    );
  }

  Widget _empty(Notebook book, CacheTokens k) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Text(
              book.isLog ? 'No entries yet.' : 'Nothing here yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, color: k.text),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('empty-add'),
              onPressed: () => _open(book, null),
              child: Text(book.isLog ? 'Add the first entry' : 'Write an entry'),
            ),
          ],
        ),
      );

  /// The top block of a Log notebook: "Last done / 4 days ago / Sun 25 Oct · 20 min · Under load: Yes / Due again in 26 days
  /// (every month) / [Add entry]".
  Widget _lastDone(Notebook book, DateTime now, CacheTokens k) {
    final e = book.lastEntry;
    if (e == null) return const SizedBox.shrink();
    final due = dueAgainText(book, now);
    final cue = dueCue(book, now);
    return Container(
      key: const ValueKey('last-done'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LAST DONE', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.secondary)),
          const SizedBox(height: 4),
          Text(agoText(e.when, now).replaceFirstMapped(RegExp('^.'), (m) => m[0]!.toUpperCase()),
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: k.text)),
          Text([dayText(e.when, now: now), ...entryValues(book.def, e)].join(' · '), style: TextStyle(fontSize: 15, color: k.secondary)),
          if (due != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(due, key: const ValueKey('due-again'), style: TextStyle(fontSize: 15, color: cue?.overdue == true ? k.warning : k.text)),
            ),
          const SizedBox(height: 10),
          FilledButton(key: const ValueKey('add-entry'), onPressed: () => _open(book, null), child: const Text('Add entry')),
        ],
      ),
    );
  }

  List<Widget> _rows(Notebook book, List<NbEntry> entries, DateTime now, CacheTokens k) {
    final out = <Widget>[];
    var list = entries;
    String? Function(NbEntry) heading = (_) => null;
    if (book.isLog) {
      heading = (e) => monthLabel(e.when, now);
    } else if (book.def.sort == NotebookSort.recent) {
      list = [...entries]..sort((a, b) => b.updated.compareTo(a.updated));
    } else if (book.def.sort == NotebookSort.distance && _here != null) {
      final h = _here!;
      double d(NbEntry e) => e.place == null ? double.infinity : distanceM(h.lat, h.lon, e.place!.lat, e.place!.lon);
      list = [...entries]..sort((a, b) => d(a).compareTo(d(b)));
    } else if (book.def.sort == NotebookSort.date) {
      heading = (e) => groupLabel(e.when, now);
    }
    String? last;
    for (final e in list) {
      final h = heading(e);
      if (h != null && h != last) {
        last = h;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(h, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: k.secondary)),
        ));
      }
      out.add(Dismissible(
        key: ValueKey('entry-${e.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: k.emergency,
          child: const Text('Delete', style: TextStyle(color: Colors.white, fontSize: 16)),
        ),
        onDismissed: (_) => deleteWithUndo(ScaffoldMessenger.of(context), nb, e, 'Entry deleted'),
        child: book.isLog ? _logRow(book, e, now, k) : _entryRow(book, e, now, k),
      ));
    }
    return out;
  }

  Widget _logRow(Notebook book, NbEntry e, DateTime now, CacheTokens k) {
    final values = entryValues(book.def, e);
    final notes = (e.body ?? '').trim();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(dayTimeText(e.when, now: now), style: TextStyle(fontSize: 16, color: k.text)),
      subtitle: values.isEmpty && notes.isEmpty ? null : Text([...values, if (notes.isNotEmpty) notes].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => _open(book, e),
    );
  }

  Widget _entryRow(Notebook book, NbEntry e, DateTime now, CacheTokens k) {
    final (text, checks) = splitChecklist(e.body);
    final shown = NbEntry(id: e.id, notebookId: e.notebookId, occurredAt: e.occurredAt, title: e.title, body: text);
    final preview = entryPreview(shown);
    final h = _here;
    final meta = [
      if (book.def.sort == NotebookSort.distance && h != null && e.place != null) distanceText(distanceM(h.lat, h.lon, e.place!.lat, e.place!.lon)) else dayText(e.when, now: now),
      if (e.place != null) e.place!.display,
      if (checks.isNotEmpty) '${checks.where((c) => c.done).length} of ${checks.length} done',
      if (e.files.isNotEmpty) e.files.length == 1 ? '1 document' : '${e.files.length} documents',
      if (e.private) 'Private',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(book, e),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entryTitle(shown), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                    if (preview.isNotEmpty) Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: k.secondary)),
                    const SizedBox(height: 2),
                    Text(meta.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
                  ],
                ),
              ),
              if (e.photos.isNotEmpty) ...[const SizedBox(width: 10), NbThumb(notebook: nb, id: e.photos.first.id, size: 56)],
            ],
          ),
        ),
      ),
    );
  }
}

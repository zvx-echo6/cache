import 'package:flutter/material.dart';

import '../screens/settings/widgets.dart';
import '../theme.dart';
import 'cds.dart';
import 'library_pages.dart';
import 'library_panes.dart';
import 'shelf_source.dart';
import 'shelves_pages.dart' show bookLine;

/// Every book on the Bookshelves: the shelved ones by call number, then Unsorted.
List<ShelfBook> allBooks(ShelfSource s) => [
      for (final c in s.shelves)
        for (final d in c.children) ...s.booksOn(d.id),
      ...s.unsorted,
    ];

/// "Same book as…": a sheet on a phone; on wider windows the detail pane, never a dialog.
Future<void> openSameBook(BuildContext context, LibraryDeps d, ShelfBook b) async {
  final nav = LibraryNav.of(context);
  if (nav.compact) {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
        child: SameBookPanel(deps: d, bookId: b.id, onDone: (_) => Navigator.of(ctx).pop()),
      ),
    );
    return;
  }
  nav.replace(
    context,
    LibraryPageSpec(
      'same:${b.id}',
      (ctx) => Scaffold(
        appBar: libraryAppBar(ctx, title: 'Same book as…'),
        body: SameBookPanel(
          deps: d,
          bookId: b.id,
          onDone: (joined) {
            final now = joined ?? d.shelves.book(b.id);
            if (now != null) LibraryNav.of(ctx).goTo(ctx, bookPath(d, now));
          },
        ),
      ),
      leaf: true,
    ),
  );
}

/// Pick the book this one is the same as: a search over the person's books, then a tap joins the two into one book (one number,
/// the other file kept as a spare), with Undo.
class SameBookPanel extends StatefulWidget {
  const SameBookPanel({super.key, required this.deps, required this.bookId, required this.onDone});

  final LibraryDeps deps;
  final String bookId;

  /// Called after the join (with the joined book) or when there is nothing to pick from (null).
  final void Function(ShelfBook? joined) onDone;

  @override
  State<SameBookPanel> createState() => _SameBookPanelState();
}

class _SameBookPanelState extends State<SameBookPanel> {
  final _query = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _join(ShelfBook b, ShelfBook other) async {
    final copies = widget.deps.shelves.copies;
    if (copies == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    ShelfBook? joined;
    try {
      joined = await copies.sameAs(b, other);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('That could not be saved. Try again.')));
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('same-snack'),
          content: Text(joined?.callNumber == null ? 'Now one book.' : 'Now one book: ${joined!.callNumber}.'),
          action: SnackBarAction(key: const ValueKey('same-undo'), label: 'Undo', onPressed: () => copies.unjoin(b, other)),
        ),
      );
    if (mounted) setState(() => _saving = false);
    widget.onDone(joined);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.deps.changes,
        builder: (context, _) {
          final k = context.t;
          final s = widget.deps.shelves;
          final b = s.book(widget.bookId);
          if (b == null) {
            return Center(child: Text('This book is not on your Bookshelves any more.', style: TextStyle(color: k.secondary)));
          }
          final q = _query.text.trim().toLowerCase();
          final others = [
            for (final o in allBooks(s))
              if (o.id != b.id && (q.isEmpty || o.title.toLowerCase().contains(q) || (o.callNumber ?? '').toLowerCase().contains(q))) o,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Text('Same book as…', key: const ValueKey('same-title'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 4),
              Text(b.title, key: const ValueKey('same-book'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
              const SizedBox(height: 6),
              Text(
                'Pick the book this is another copy of. They become one book with one number, and the other file is kept as a spare.',
                style: TextStyle(fontSize: 14, color: k.secondary),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('same-search'),
                controller: _query,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search your books',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: k.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              if (others.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(q.isEmpty ? 'No other books yet.' : 'No book matches.', key: const ValueKey('same-none'), style: TextStyle(fontSize: 14, color: k.secondary)),
                )
              else
                SettingsGroup(
                  rows: [
                    for (final o in others)
                      SettingsRow(
                        key: ValueKey('same-pick-${o.id}'),
                        leading: SizedBox(
                          width: 74,
                          child: Text(
                            (o.callNumber ?? 'CDS —').replaceFirst('CDS ', ''),
                            style: TextStyle(fontFamily: kCdsMono, fontSize: 13, fontWeight: FontWeight.w700, color: k.secondary),
                          ),
                        ),
                        title: o.title,
                        titleLines: 2,
                        status: [Part(bookLine(o))],
                        chevron: false,
                        dim: _saving,
                        onTap: _saving ? null : () => _join(b, o),
                      ),
                  ],
                ),
            ],
          );
        },
      );
}

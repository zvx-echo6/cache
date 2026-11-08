import 'package:flutter/material.dart';

import '../theme.dart';
import 'library_pages.dart';
import 'library_panes.dart';
import 'shelf_source.dart';

/// Rename: a sheet on a phone; on wider windows the detail pane, never a dialog.
Future<void> openRename(BuildContext context, LibraryDeps d, ShelfBook b) async {
  final nav = LibraryNav.of(context);
  if (nav.compact) {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: context.t.background,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: RenamePanel(deps: d, bookId: b.id, onDone: () => Navigator.of(ctx).pop()),
      ),
    );
    return;
  }
  nav.replace(
    context,
    LibraryPageSpec(
      'rename:${b.id}',
      (ctx) => Scaffold(
        appBar: libraryAppBar(ctx, title: 'Rename'),
        body: RenamePanel(
          deps: d,
          bookId: b.id,
          heading: false,
          onDone: () {
            final now = d.shelves.book(b.id);
            if (now != null) LibraryNav.of(ctx).goTo(ctx, bookPath(d, now));
          },
        ),
      ),
      leaf: true,
    ),
  );
}

/// A new title for the book, kept on all of the person's devices.
class RenamePanel extends StatefulWidget {
  const RenamePanel({super.key, required this.deps, required this.bookId, required this.onDone, this.heading = true});

  final LibraryDeps deps;
  final String bookId;
  final VoidCallback onDone;

  /// The panel's own "Rename" heading (a sheet); the pane's top bar already says it.
  final bool heading;

  @override
  State<RenamePanel> createState() => _RenamePanelState();
}

class _RenamePanelState extends State<RenamePanel> {
  late final TextEditingController _title = TextEditingController(text: widget.deps.shelves.book(widget.bookId)?.title ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save(ShelfBook b) async {
    final copies = widget.deps.shelves.copies;
    final t = _title.text.trim();
    if (copies == null || t.isEmpty || _saving) return;
    if (t == b.title) {
      widget.onDone();
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await copies.retitle(b, t);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('That could not be saved. Try again.')));
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(key: ValueKey('renamed-snack'), content: Text('Renamed on all your devices.')));
    if (mounted) setState(() => _saving = false);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final b = widget.deps.shelves.book(widget.bookId);
    if (b == null) {
      return Center(child: Text('This book is not on your Bookshelves any more.', style: TextStyle(color: k.secondary)));
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (widget.heading) ...[
          Text('Rename', key: const ValueKey('rename-title'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
          const SizedBox(height: 6),
        ],
        Text('The new title shows on all your devices. The file keeps its own name.', style: TextStyle(fontSize: 14, color: k.secondary)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('rename-field'),
          controller: _title,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(b),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Title',
            filled: true,
            fillColor: k.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        if (b.originalTitle != null || b.aka.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in {?b.originalTitle, ...b.aka})
                ActionChip(key: ValueKey('rename-use-$t'), label: Text(t), onPressed: () => setState(() => _title.text = t)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('rename-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          onPressed: _saving || _title.text.trim().isEmpty ? null : () => _save(b),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Hide: the book leaves the Bookshelves on all the person's devices (no file is deleted), with Undo; the page goes back to where
/// the book stood.
Future<void> hideBook(BuildContext context, LibraryDeps d, ShelfBook b) async {
  final copies = d.shelves.copies;
  if (copies == null) return;
  final nav = LibraryNav.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final back = b.shelf == null ? [bookshelvesSpec(d), unsortedSpec(d)] : shelfPath(d, b.shelf!);
  try {
    await copies.hide(b);
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('That could not be saved. Try again.')));
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('hidden-snack'),
        content: const Text('Hidden on all your devices. No file was deleted.'),
        action: SnackBarAction(key: const ValueKey('hidden-undo'), label: 'Undo', onPressed: () => copies.hide(b, hidden: false)),
      ),
    );
  if (context.mounted) nav.goTo(context, back);
}

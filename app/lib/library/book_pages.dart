import 'dart:io';

import 'package:flutter/material.dart';

import '../desktop/desktop.dart';
import '../pdf/open_pdf.dart' show openPdfReader;
import '../pdf/pdf_source.dart' show PdfFileSource, PdfFrom;

import '../screens/settings/widgets.dart';
import '../theme.dart';
import '../video/format.dart' show formatBytes;
import 'cds.dart';
import 'library_pages.dart';
import 'add_pdf/add_pdf_pages.dart' show AddPdfBookNote;
import 'book_edit_pages.dart';
import 'library_panes.dart';
import 'same_book_pages.dart';
import 'shelf_source.dart';
import 'shelves_pages.dart' show shelfColor;

/// "CDS 350 · Beekeeping".
String _shelfWords(LibraryDeps d, String id) {
  final s = d.shelves.shelf(id);
  if (s == null) return id;
  final short = d.shelves.shortName;
  return s.number == null ? s.name : '${s.label(short)} · ${s.name}';
}

/// A book's colour: its class's when it is shelved, else the quiet secondary.
Color bookColor(BuildContext context, LibraryDeps d, ShelfBook b) {
  final s = b.shelf == null ? null : d.shelves.shelf(b.shelf!);
  return s == null ? context.t.secondary : shelfColor(context, s);
}

/// Places [moves] and says so, with Undo for the whole lot.
Future<Placement?> placeAndSay(BuildContext context, LibraryDeps d, List<(ShelfBook, String)> moves) async {
  final placer = d.shelves.placer;
  if (placer == null || moves.isEmpty) return null;
  final messenger = ScaffoldMessenger.of(context);
  Placement p;
  try {
    p = await placer.place(moves);
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('That could not be saved. Try again.')));
    return null;
  }
  final text = p.books.length == 1
      ? 'Placed in ${_shelfWords(d, p.books.single.shelf)} as ${p.books.single.callNumber}.'
      : 'Placed ${booksWord(p.books.length)}. Each has its new call number.';
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('placed-snack'),
        content: Text(text),
        action: SnackBarAction(key: const ValueKey('placed-undo'), label: 'Undo', onPressed: () => placer.undo(p)),
      ),
    );
  return p;
}

/// Place it (and Move): a sheet on a phone; on wider windows the detail pane, never a dialog.
Future<void> openPlace(BuildContext context, LibraryDeps d, ShelfBook b, {List<String> queue = const [], bool replace = false}) async {
  final nav = LibraryNav.of(context);
  if (nav.compact) {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
        child: PlacePanel(deps: d, bookId: b.id, queue: queue, onDone: (_) => Navigator.of(ctx).pop()),
      ),
    );
    return;
  }
  final back = b.shelf == null ? [bookshelvesSpec(d), unsortedSpec(d)] : bookPath(d, b);
  final spec = LibraryPageSpec(
    'place:${b.id}',
    (ctx) => Scaffold(
      appBar: libraryAppBar(ctx, title: b.shelf == null ? 'Place it' : 'Move'),
      body: PlacePanel(
        deps: d,
        bookId: b.id,
        queue: queue,
        onDone: (placed) {
          final now = d.shelves.book(b.id);
          LibraryNav.of(ctx).goTo(ctx, placed && now != null && replace ? bookPath(d, now) : back);
        },
      ),
    ),
    leaf: true,
  );
  if (replace) {
    nav.replace(context, spec);
  } else {
    nav.open(context, spec);
  }
}

/// "Where does this book go?": the three best guesses as chips (the first marked "Best guess"), then every division (the ten
/// classes, then their divisions), and Leave unsorted. A tap saves it, says its new number with Undo, and goes on to the next book
/// of [queue]. No scores are shown. Move titles itself "Move to another division".
class PlacePanel extends StatefulWidget {
  const PlacePanel({super.key, required this.deps, required this.bookId, required this.onDone, this.queue = const []});

  final LibraryDeps deps;
  final String bookId;

  /// The books to go on to after this one (Unsorted's order).
  final List<String> queue;

  /// Called when there is nothing more to place here (true when something was placed).
  final ValueChanged<bool> onDone;

  @override
  State<PlacePanel> createState() => _PlacePanelState();
}

class _PlacePanelState extends State<PlacePanel> {
  late String _id = widget.bookId;
  bool _all = false;
  bool _busy = false;
  bool _placed = false;

  LibraryDeps get d => widget.deps;

  String? _next() {
    final i = widget.queue.indexOf(_id);
    for (var j = i + 1; j < widget.queue.length; j++) {
      final b = d.shelves.book(widget.queue[j]);
      if (b != null && b.shelf == null) return b.id;
    }
    return null;
  }

  Future<void> _choose(ShelfBook b, String? shelf) async {
    if (_busy) return;
    if (shelf != null) {
      setState(() => _busy = true);
      final p = await placeAndSay(context, d, [(b, shelf)]);
      if (!mounted) return;
      _busy = false;
      if (p != null) _placed = true;
    }
    final next = b.shelf == null ? _next() : null;
    if (next == null) {
      widget.onDone(_placed);
      return;
    }
    setState(() {
      _id = next;
      _all = false;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d.changes,
    builder: (context, _) {
      final k = context.t;
      final b = d.shelves.book(_id);
      if (b == null) return const SizedBox.shrink();
      final move = b.shelf != null;
      final guesses = b.suggestions.where((s) => s != b.shelf).take(3).toList();
      final placer = d.shelves.placer;
      final example = guesses.isEmpty ? null : placer?.nextNumber(guesses.first);
      final tree = _tree(context, b);
      return LayoutBuilder(
        builder: (context, c) {
          final side = c.maxWidth >= 640;
          final head = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(move ? 'Move to another division' : 'Where does this book go?', key: const ValueKey('place-title'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 6),
              Text(b.title, key: const ValueKey('place-book'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
              if (move) Text('Now ${b.callNumber ?? _shelfWords(d, b.shelf!)}', style: TextStyle(fontSize: 13, color: k.secondary)),
              const SizedBox(height: 8),
              Text(
                example == null
                    ? 'The book gets its call number in the division you pick.'
                    : 'The book gets its call number in the division you pick, for example $example.',
                style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary),
              ),
              if (placer == null) ...[
                const SizedBox(height: 8),
                Text('Books cannot be placed on this device yet.', style: TextStyle(fontSize: 13, color: k.warning)),
              ],
              if (guesses.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < guesses.length; i++)
                      PlaceChip(
                        key: ValueKey('place-chip-${guesses[i]}'),
                        label: i == 0 ? '${cdsChipLabel(guesses[i])} · Best guess' : cdsChipLabel(guesses[i]),
                        best: i == 0,
                        onPressed: placer == null || _busy ? null : () => _choose(b, guesses[i]),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                children: [
                  if (!side)
                    TextButton(key: const ValueKey('place-all-divisions'), onPressed: () => setState(() => _all = !_all), child: Text(_all ? 'Hide divisions' : 'See all divisions')),
                  if (!move) TextButton(key: const ValueKey('place-leave'), onPressed: _busy ? null : () => _choose(b, null), child: const Text('Leave unsorted')),
                ],
              ),
            ],
          );
          if (side) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 320, child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 12, 24), child: head)),
                Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 16, 24), children: tree)),
              ],
            );
          }
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [head, if (_all) ...tree],
          );
        },
      );
    },
  );

  /// The whole scheme: each class, then its divisions (the book's own shelf marked).
  List<Widget> _tree(BuildContext context, ShelfBook b) {
    final k = context.t;
    final placer = d.shelves.placer;
    return [
      for (final c in d.shelves.shelves.where((x) => x.assigned)) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text(c.number == null ? c.name : '${c.number} ${c.name}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: shelfColor(context, c))),
        ),
        for (final dv in c.children.where((x) => x.assigned))
          ListTile(
            key: ValueKey('place-div-${dv.id}'),
            dense: true,
            minTileHeight: 44,
            enabled: placer != null && !_busy && dv.id != b.shelf,
            leading: dv.number == null ? null : Text(dv.number!, style: TextStyle(fontFamily: kCdsMono, fontWeight: FontWeight.w700, color: shelfColor(context, dv))),
            title: Text(dv.name, style: TextStyle(fontSize: 14, color: k.text)),
            trailing: dv.id == b.shelf ? Text('Here now', style: TextStyle(fontSize: 12, color: k.secondary)) : null,
            onTap: () => _choose(b, dv.id),
          ),
      ],
    ];
  }
}

/// A suggestion as a chip: the best guess filled, the others outlined.
class PlaceChip extends StatelessWidget {
  const PlaceChip({super.key, required this.label, required this.best, required this.onPressed});

  final String label;
  final bool best;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      side: best ? null : WidgetStatePropertyAll(BorderSide(color: k.secondary, width: 1.5)),
    );
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500));
    return best ? FilledButton(style: style, onPressed: onPressed, child: text) : OutlinedButton(style: style.copyWith(foregroundColor: WidgetStatePropertyAll(k.text)), onPressed: onPressed, child: text);
  }
}

/// Unsorted: the books Cache was not sure about, each with its best guesses, and Place all best guesses (with Undo for the batch).
class UnsortedPage extends StatelessWidget {
  const UnsortedPage({super.key, required this.deps});

  final LibraryDeps deps;

  @override
  Widget build(BuildContext context) {
    final d = deps;
    return Scaffold(
      appBar: libraryAppBar(context, title: 'Unsorted'),
      body: ListenableBuilder(
        listenable: d.changes,
        builder: (context, _) {
          final k = context.t;
          final nav = LibraryNav.of(context);
          final books = d.shelves.unsorted;
          final placer = d.shelves.placer;
          final guessed = [for (final b in books) if (b.suggestions.isNotEmpty) b];
          final queue = [for (final b in books) b.id];
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              LibraryCrumbs(crumbs: shelfCrumbs(context, d, null, last: 'Unsorted')),
              if (books.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('Every book is on a shelf.', key: const ValueKey('unsorted-empty'), style: TextStyle(fontSize: 14, color: k.secondary)),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
                  child: Text(
                    "${booksWord(books.length)} Cache wasn't sure about. Pick a subject; it's saved and helps Cache learn.",
                    style: TextStyle(fontSize: 14, height: 1.4, color: k.secondary),
                  ),
                ),
                if (placer != null && guessed.isNotEmpty) ...[
                  FilledButton(
                    key: const ValueKey('place-all'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: () => placeAndSay(context, d, [for (final b in guessed) (b, b.suggestions.first)]),
                    child: const Text('Place all best guesses'),
                  ),
                  const SizedBox(height: 10),
                ],
                for (final b in books)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      key: ValueKey('unsorted-${b.id}'),
                      color: nav.isOpen('place:${b.id}') || nav.isOpen('book:${b.id}') ? Color.alphaBlend(k.accent.withValues(alpha: 0.16), k.surface) : k.surface,
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              onTap: () => nav.open(context, bookSpec(d, b.id)),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text('CDS —', style: TextStyle(fontFamily: kCdsMono, fontSize: 13, fontWeight: FontWeight.w700, color: k.secondary)),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text))),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (var i = 0; i < b.suggestions.length && i < 3; i++)
                                  PlaceChip(
                                    key: ValueKey('chip-${b.id}-${b.suggestions[i]}'),
                                    label: i == 0 ? '${cdsChipLabel(b.suggestions[i])} · Best guess' : cdsChipLabel(b.suggestions[i]),
                                    best: i == 0,
                                    onPressed: placer == null ? null : () => placeAndSay(context, d, [(b, b.suggestions[i])]),
                                  ),
                                TextButton(
                                  key: ValueKey('all-divisions-${b.id}'),
                                  onPressed: () => openPlace(context, d, b, queue: queue),
                                  child: const Text('All divisions'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One fact of the book page: its name small above, its value, and a line under it.
class _Fact {
  const _Fact(this.label, this.value, {this.line, this.tone = Tone.normal, this.action, this.valueKey});

  final String label;
  final String value;
  final String? line;
  final Tone tone;
  final Widget? action;
  final String? valueKey;
}

Widget _facts(BuildContext context, List<_Fact> facts) {
  final k = context.t;
  return ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < facts.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          Container(
            color: k.surface,
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(facts[i].label, style: TextStyle(fontSize: 13, color: k.secondary)),
                      const SizedBox(height: 2),
                      Text(
                        facts[i].value,
                        key: facts[i].valueKey == null ? null : ValueKey(facts[i].valueKey),
                        style: TextStyle(fontSize: 15, color: facts[i].tone == Tone.normal ? k.text : toneColor(k, facts[i].tone)),
                      ),
                      if (facts[i].line != null) Text(facts[i].line!, style: TextStyle(fontSize: 13, color: k.secondary)),
                    ],
                  ),
                ),
                if (facts[i].action != null) ...[const SizedBox(width: 8), facts[i].action!],
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// A book: its catalogue card (call number, title in a serif, author and edition), then where it is shelved (with Move), its
/// PDF, whether it is searchable here and what was stored; the actions this device can do; Delete book.
class BookPage extends StatelessWidget {
  const BookPage({super.key, required this.deps, required this.bookId});

  final LibraryDeps deps;
  final String bookId;

  @override
  Widget build(BuildContext context) {
    final d = deps;
    return ListenableBuilder(
      listenable: d.changes,
      builder: (context, _) {
        final k = context.t;
        final b = d.shelves.book(bookId);
        if (b == null) {
          return Scaffold(
            appBar: libraryAppBar(context, title: 'Book'),
            body: Center(child: Text('This book is not on your Bookshelves any more.', style: TextStyle(color: k.secondary))),
          );
        }
        final crumbs = b.shelf == null ? shelfCrumbs(context, d, null, last: 'Unsorted') : shelfCrumbs(context, d, b.shelf);
        final crumbsWithLast = b.shelf == null ? crumbs : [...crumbs.sublist(0, crumbs.length - 1), Crumb(crumbs.last.label, shelfPath(d, b.shelf!))];
        final color = bookColor(context, d, b);
        // once after Add PDF filed it: "Filed in 530 Water treatment", Move, Undo; then it goes
        final card = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [AddPdfBookNote(key: ValueKey('add-pdf-book-note-${b.id}'), book: b, deps: d), _CatalogueCard(book: b, color: color)]);
        final facts = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _facts(context, _bookFacts(context, d, b)),
            if (b.spares.isNotEmpty) ...[const SizedBox(height: 12), _spares(context, d, b)],
          ],
        );
        final actions = _actions(context, d, b);
        final links = SettingsGroup(
          rows: [
            if (d.shelves.copies != null) ...[
              SettingsRow(key: const ValueKey('book-rename'), title: 'Rename', onTap: () => openRename(context, d, b)),
              SettingsRow(
                key: const ValueKey('book-hide'),
                title: 'Hide from Bookshelves',
                status: const [Part('On all your devices. No file is deleted.')],
                chevron: false,
                onTap: () => hideBook(context, d, b),
              ),
            ],
            SettingsRow(key: const ValueKey('book-delete'), title: 'Delete book', danger: true, chevron: false, onTap: () => showDeleteBook(context, d, b)),
          ],
        );
        final desktop = DesktopMetrics.of(context);
        return Scaffold(
          appBar: libraryAppBar(context, title: b.title, titleWidget: LibraryCrumbs(crumbs: crumbsWithLast)),
          body: desktop != null
              ? _desktopBody(context, d, b, desktop, card)
              : LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 860;
              final body = wide
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        card,
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: facts),
                            const SizedBox(width: 16),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...actions, if (actions.isNotEmpty) const SizedBox(height: 14), links])),
                          ],
                        ),
                      ],
                    )
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [card, const SizedBox(height: 12), facts, const SizedBox(height: 12), ...actions, if (actions.isNotEmpty) const SizedBox(height: 12), links]);
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                // text kept to a reading width; on a wide page the panels sit side by side under the card
                child: Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: wide ? 1000 : 640), child: body)),
              );
            },
          ),
        );
      },
    );
  }

  /// The Linux desktop's book pane: the catalogue card on top, the actions in one row of ordinary buttons under it, the facts as a
  /// label and value list, then the quiet group (Rename, Hide from Bookshelves, Delete book). Left-aligned, 760 wide at most.
  static Widget _desktopBody(BuildContext context, LibraryDeps d, ShelfBook b, DesktopMetrics m, Widget card) {
    final k = context.t;
    final f = d.files;
    final path = b.pdfPath;
    final here = path != null && _pdfBytes(b) != null;
    final original = d.originals?.available(b) ?? false;
    final placer = d.shelves.placer;
    final facts = _bookFacts(context, d, b);
    final line = k.secondary.withValues(alpha: 0.2);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(m.gutter, 24, m.gutter, 24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: DesktopMetrics.formMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              card,
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // in a browser the PDF is on the server: nothing to open or download here
                  if (!b.onServer && here)
                    FilledButton(
                      key: const ValueKey('book-open'),
                      onPressed: () => openPdfReader(context, PdfFileSource(path, title: b.title, from: PdfFrom.library), page: 1),
                      child: const Text('Open'),
                    ),
                  if (!b.onServer && here && f.canRemove)
                    OutlinedButton(key: const ValueKey('book-remove-pdf'), onPressed: () => _removeHere(context, d, [b]), child: const Text('Remove PDF from this device'))
                  else if (!b.onServer && !here)
                    OutlinedButton(key: const ValueKey('book-download'), onPressed: f.download(b), child: const Text('Download to this device')),
                  if (d.shelves.copies != null)
                    OutlinedButton(key: const ValueKey('book-same-as'), onPressed: () => openSameBook(context, d, b), child: const Text('Same book as…')),
                  if (placer != null)
                    OutlinedButton(
                      key: const ValueKey('book-move'),
                      onPressed: () => openPlace(context, d, b, replace: true),
                      child: Text(b.shelf == null ? 'Place it' : 'Move'),
                    ),
                  if (original)
                    OutlinedButton.icon(
                      key: const ValueKey('book-open-original'),
                      onPressed: () => d.originals!.open(b),
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text('Open original'),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(border: Border(top: BorderSide(color: line))),
                child: Column(
                  children: [
                    for (final fact in facts)
                      Container(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line))),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 140, child: Text(fact.label, style: TextStyle(fontSize: 13, color: k.secondary))),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    fact.value,
                                    key: fact.valueKey == null ? null : ValueKey(fact.valueKey),
                                    style: TextStyle(fontSize: 15, color: fact.tone == Tone.normal ? k.text : toneColor(k, fact.tone)),
                                  ),
                                  if (fact.line != null) Text(fact.line!, style: TextStyle(fontSize: 13, color: k.secondary)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (b.spares.isNotEmpty) ...[const SizedBox(height: 16), _spares(context, d, b)],
              const SizedBox(height: 24),
              Material(
                color: k.surface,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    if (d.shelves.copies != null) ...[
                      SettingsRow(key: const ValueKey('book-rename'), compact: true, title: 'Rename', onTap: () => openRename(context, d, b)),
                      Divider(height: 1, color: line),
                      SettingsRow(
                        key: const ValueKey('book-hide'),
                        compact: true,
                        title: 'Hide from Bookshelves',
                        status: const [Part('On all your devices. No file is deleted.')],
                        chevron: false,
                        onTap: () => hideBook(context, d, b),
                      ),
                      Divider(height: 1, color: line),
                    ],
                    SettingsRow(key: const ValueKey('book-delete'), compact: true, title: 'Delete book', danger: true, chevron: false, onTap: () => showDeleteBook(context, d, b)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static List<_Fact> _bookFacts(BuildContext context, LibraryDeps d, ShelfBook b) {
    final search = d.shelves.searchOf(b);
    final placer = d.shelves.placer;
    // whether the PDF is here is the file itself; which other device has it, when this device knows (stream-back)
    final from = d.files.stateOf(b).from;
    final here = _pdfBytes(b);
    final String pdf = b.onServer
        // in a browser the device is the server the page is signed in to: the PDF is kept there
        ? ['On this device', if (b.bytes case final n? when n > 0) formatBytes(n)].join(' · ')
        : here != null
            ? 'On this device · ${formatBytes(here)}'
            : (from == null ? 'Not on this device' : 'Not on this device. Opens from $from when it is online.');
    return [
      _Fact(
        'Subject',
        b.shelf == null ? 'Unsorted' : _shelfWords(d, b.shelf!),
        valueKey: 'book-subject',
        line: b.shelf == null ? null : (b.shelvedBy == ShelvedBy.person ? 'Placed by you' : 'Filed by Cache'),
        action: placer == null
            ? null
            : RowButton(key: const ValueKey('book-move'), label: b.shelf == null ? 'Place it' : 'Move', onPressed: () => openPlace(context, d, b, replace: true)),
      ),
      _Fact('PDF', pdf, valueKey: 'book-pdf'),
      _Fact(
        'Search',
        switch (search.state) {
          BookSearchState.searchable => 'Searchable here',
          BookSearchState.making => search.fraction == null ? 'Making it searchable' : 'Making it searchable ${(search.fraction! * 100).round()}%',
          BookSearchState.waiting => 'Not searchable yet',
          BookSearchState.gettingReady => 'Getting ready',
          BookSearchState.failed => 'Stopped: it could not be read',
        },
        valueKey: 'book-search',
        tone: switch (search.state) {
          BookSearchState.searchable => Tone.ok,
          BookSearchState.failed => Tone.danger,
          _ => Tone.normal,
        },
      ),
      if (b.stored != null) _Fact('Stored', b.stored!, valueKey: 'book-stored'),
      if (b.aka.isNotEmpty) _Fact('Also known as', b.aka.join('\n'), valueKey: 'book-aka'),
    ];
  }

  /// The book's other files: each with its title, size and where it is; "Read this copy instead" for one on this device, and
  /// "Not the same book" to make it a book of its own.
  static Widget _spares(BuildContext context, LibraryDeps d, ShelfBook b) {
    final k = context.t;
    final copies = d.shelves.copies;
    final messenger = ScaffoldMessenger.of(context);
    Future<void> run(Future<void> Function() f, String done) async {
      try {
        await f();
      } catch (_) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('That could not be saved. Try again.')));
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(done)));
    }

    return Column(
      key: const ValueKey('book-spares'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('Spare copies'),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: Text('Other files of this book. They share its number; Cache reads the best one.', style: TextStyle(fontSize: 13, color: k.secondary)),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < b.spares.length; i++) ...[
                if (i > 0) const SizedBox(height: 2),
                Container(
                  key: ValueKey('spare-${b.spares[i].copy}'),
                  color: k.surface,
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.spares[i].title, style: TextStyle(fontSize: 15, color: k.text)),
                      const SizedBox(height: 2),
                      Text(
                        [if (b.spares[i].bytes case final n? when n > 0) formatBytes(n), b.spares[i].where].join(' · '),
                        style: TextStyle(fontSize: 13, color: k.secondary),
                      ),
                      if (copies != null) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (b.spares[i].here)
                              RowButton(
                                key: ValueKey('spare-read-${b.spares[i].copy}'),
                                label: 'Read this copy instead',
                                onPressed: () => run(() => copies.readInstead(b, b.spares[i].copy), 'You will read this copy from now on.'),
                              ),
                            RowButton(
                              key: ValueKey('spare-notsame-${b.spares[i].copy}'),
                              label: 'Not the same book',
                              onPressed: () => run(() => copies.notSame(b, b.spares[i].copy), 'Now a book of its own.'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The size of the book's PDF on this device, or null when it is not here.
  static int? _pdfBytes(ShelfBook b) {
    final p = b.pdfPath;
    if (p == null) return null;
    try {
      return File(p).lengthSync();
    } catch (_) {
      return null;
    }
  }

  static List<Widget> _actions(BuildContext context, LibraryDeps d, ShelfBook b) {
    final f = d.files;
    final download = f.download(b);
    final path = b.pdfPath;
    final here = path != null && _pdfBytes(b) != null;
    final original = d.originals?.available(b) ?? false;
    final buttons = <Widget>[
      // in a browser the PDF is on the server: nothing to open or download here
      if (!b.onServer) ...[
      // Open: the book's own PDF in the app's PDF reader, at its first page
      if (here)
        Expanded(
          child: FilledButton(
            key: const ValueKey('book-open'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            onPressed: () => openPdfReader(context, PdfFileSource(path, title: b.title, from: PdfFrom.library), page: 1),
            child: const Text('Open'),
          ),
        ),
      if (here && f.canRemove)
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('book-remove-pdf'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            onPressed: () => _removeHere(context, d, [b]),
            child: const Text('Remove PDF from this device', textAlign: TextAlign.center),
          ),
        )
      // not here: Download, greyed until this device can fetch a book from another (stream-back)
      else if (!here)
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('book-download'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            onPressed: download,
            child: const Text('Download to this device', textAlign: TextAlign.center),
          ),
        ),
      ],
    ];
    return [
      if (buttons.isNotEmpty) Row(children: [for (var i = 0; i < buttons.length; i++) ...[if (i > 0) const SizedBox(width: 8), buttons[i]]]),
      if (d.shelves.copies != null) ...[
        if (buttons.isNotEmpty) const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('book-same-as'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          onPressed: () => openSameBook(context, d, b),
          child: const Text('Same book as…'),
        ),
      ],
      if (original) ...[
        if (buttons.isNotEmpty) const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('book-open-original'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          onPressed: () => d.originals!.open(b),
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('Open original'),
        ),
      ],
    ];
  }
}

/// The catalogue card at the top of a book: call number in its class colour, a punched hole, the title in a serif, author and
/// edition when known.
class _CatalogueCard extends StatelessWidget {
  const _CatalogueCard({required this.book, required this.color});

  final ShelfBook book;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final serif = TextStyle(fontFamily: kCdsSerif, fontVariations: serifWeight(FontWeight.w400), fontSize: 14, height: 1.35, color: k.secondary);
    // each line only when the pack has it
    return Container(
      key: const ValueKey('catalogue-card'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: k.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: k.secondary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.25)))),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    book.callNumber ?? 'CDS —',
                    key: const ValueKey('book-call'),
                    style: TextStyle(fontFamily: kCdsMono, fontSize: 18, fontWeight: FontWeight.w700, color: color),
                  ),
                ),
                Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.secondary.withValues(alpha: 0.5), width: 1.5))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            book.title,
            key: const ValueKey('book-title'),
            style: TextStyle(fontFamily: kCdsSerif, fontVariations: serifWeight(FontWeight.w700), fontWeight: FontWeight.w700, fontSize: 21, height: 1.3, color: k.text),
          ),
          if (book.author != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(book.author!, key: const ValueKey('book-author'), style: serif)),
          if (book.edition != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(book.edition!, key: const ValueKey('book-edition'), style: serif)),
          if (book.originalTitle != null)
            Padding(padding: const EdgeInsets.only(top: 2), child: Text('Original title: ${book.originalTitle}', key: const ValueKey('book-original-title'), style: serif)),
        ],
      ),
    );
  }
}

Future<void> _removeHere(BuildContext context, LibraryDeps d, List<ShelfBook> books) async {
  final messenger = ScaffoldMessenger.of(context);
  final (outcome, removed, kept) = await d.files.removeFromDevice(books);
  final text = switch (outcome) {
    RemoveOutcome.removed => books.length == 1 ? 'Removed from this device.' : '$removed removed. $kept kept: no other device has them.',
    _ => "No other device has this book right now, so it can't be freed.",
  };
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Delete book: two clearly separate choices. "Remove from this device" takes the book, its PDF and its search entry off this
/// device only, after checking right now that another device has it; "Delete from all your devices" deletes it everywhere and
/// cannot be undone. A choice this device cannot do yet says so.
Future<void> showDeleteBook(BuildContext context, LibraryDeps d, ShelfBook b) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (ctx) => DeleteBookSheet(deps: d, book: b, onDeleted: () => LibraryNav.of(context).goTo(context, b.shelf == null ? [bookshelvesSpec(d)] : shelfPath(d, b.shelf!))),
);

class DeleteBookSheet extends StatefulWidget {
  const DeleteBookSheet({super.key, required this.deps, required this.book, this.onDeleted});

  final LibraryDeps deps;
  final ShelfBook book;
  final VoidCallback? onDeleted;

  @override
  State<DeleteBookSheet> createState() => _DeleteBookSheetState();
}

class _DeleteBookSheetState extends State<DeleteBookSheet> {
  bool _asking = false;
  String? _refused;

  Future<void> _remove() async {
    setState(() {
      _asking = true;
      _refused = null;
    });
    final (outcome, _, _) = await widget.deps.files.removeFromDevice([widget.book]);
    if (!mounted) return;
    if (outcome == RemoveOutcome.removed) {
      Navigator.of(context).pop();
      widget.onDeleted?.call();
      return;
    }
    setState(() {
      _asking = false;
      _refused = "No other device has this book right now, so it can't be removed from just this device. Delete it instead.";
    });
  }

  Future<void> _deleteEverywhere() async {
    await widget.deps.files.deleteEverywhere(widget.book);
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onDeleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final f = widget.deps.files;
    final b = widget.book;
    Widget choice({required String title, required String text, required Widget button, bool danger = false, String? note, Key? key}) => Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: k.background, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: danger ? k.emergency : k.text)),
          const SizedBox(height: 4),
          Text(text, style: TextStyle(fontSize: 14, height: 1.4, color: k.secondary)),
          const SizedBox(height: 10),
          button,
          if (note != null) ...[const SizedBox(height: 6), Text(note, style: TextStyle(fontSize: 13, color: k.secondary))],
        ],
      ),
    );
    const unavailable = 'Not available on this device yet.';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Delete book', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
            const SizedBox(height: 2),
            Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.secondary)),
            const SizedBox(height: 12),
            choice(
              key: const ValueKey('delete-here'),
              title: 'Remove from this device',
              text: 'Takes the book, its PDF and its search entry off this device only. Cache asks your other devices right now whether one has a checked copy. If none does, nothing is removed.',
              button: OutlinedButton(
                key: const ValueKey('delete-here-button'),
                onPressed: !f.canRemove || _asking ? null : _remove,
                child: Text(_asking ? 'Asking your other devices...' : 'Remove from this device'),
              ),
              note: !f.canRemove ? unavailable : _refused,
            ),
            const SizedBox(height: 10),
            choice(
              key: const ValueKey('delete-all'),
              danger: true,
              title: 'Delete from all your devices',
              text: 'Deletes the book, its search index and its call number ${b.callNumber ?? ''} on every device you have linked. This cannot be undone.'.replaceAll('number  on', 'number on'),
              button: FilledButton(
                key: const ValueKey('delete-all-button'),
                style: FilledButton.styleFrom(backgroundColor: k.emergency, foregroundColor: k.background),
                onPressed: f.canDeleteEverywhere && !_asking ? _deleteEverywhere : null,
                child: const Text('Delete from all your devices'),
              ),
              note: f.canDeleteEverywhere ? null : unavailable,
            ),
          ],
        ),
      ),
    );
  }
}

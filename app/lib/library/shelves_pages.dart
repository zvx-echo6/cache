import 'package:flutter/material.dart';

import '../screens/settings/widgets.dart';
import '../theme.dart';
import '../video/format.dart' show formatBytes;
import 'cds.dart';
import 'library_pages.dart';
import 'library_panes.dart';
import 'library_prefs.dart';
import 'shelf_source.dart';

/// A shelf's colour: its class's (a numbered shelf), else the accent.
Color shelfColor(BuildContext context, Shelf s) {
  final n = s.number;
  return n == null ? context.t.accent : context.cdsColor('${n[0]}00');
}

/// Bookshelves: "Shelved by the Cache Decimal System", Go to a number, Unsorted while it holds books, and the ten classes in the
/// look chosen on this device (List, Drawers or Spines). Every class shows, empty ones too.
class BookshelvesPage extends StatefulWidget {
  const BookshelvesPage({super.key, required this.deps});

  final LibraryDeps deps;

  @override
  State<BookshelvesPage> createState() => _BookshelvesPageState();
}

class _BookshelvesPageState extends State<BookshelvesPage> {
  final _number = TextEditingController();

  LibraryDeps get d => widget.deps;

  @override
  void initState() {
    super.initState();
    d.looks.load();
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _go() {
    final t = d.shelves.goTo(_number.text);
    if (t == null) {
      say(context, 'No shelf has that number. Try one such as 530.');
      return;
    }
    final nav = LibraryNav.of(context);
    final shelf = t.shelfId;
    final path = [
      if (shelf != null) ...shelfPath(d, shelf) else bookshelvesSpec(d),
      if (t.bookId != null) bookSpec(d, t.bookId!),
    ];
    FocusScope.of(context).unfocus();
    nav.goTo(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final nav = LibraryNav.of(context);
    return Scaffold(
      appBar: libraryAppBar(context, title: 'Bookshelves'),
      body: ListenableBuilder(
        listenable: d.changes,
        builder: (context, _) {
          final s = d.shelves;
          final look = d.looks.look;
          final unsorted = s.unsorted;
          final working = _working();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (!nav.compact) LibraryCrumbs(crumbs: shelfCrumbs(context, d, null)),
              LookSwitch(value: look, onChanged: d.looks.set),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(s.scheme, key: const ValueKey('shelves-scheme'), style: TextStyle(fontSize: 13, color: k.secondary)),
              ),
              if (s.goToHint case final hint?) ...[
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('go-to-number'),
                  controller: _number,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _go(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: hint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: IconButton(key: const ValueKey('go-to-number-go'), tooltip: 'Go', icon: const Icon(Icons.arrow_forward), onPressed: _go),
                    filled: true,
                    fillColor: k.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              if (working != null) ...[working, const SizedBox(height: 10)],
              if (unsorted.isNotEmpty) ...[
                SettingsGroup(
                  rows: [
                    SettingsRow(
                      key: const ValueKey('shelves-unsorted'),
                      title: 'Unsorted · ${booksWord(unsorted.length)}',
                      statusWidget: Text('Place them', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: k.accent)),
                      selected: nav.isOpen('unsorted'),
                      onTap: () => nav.open(context, unsortedSpec(d)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              if (s.bookCount == 0 && !s.loading) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Text('No books yet.', key: const ValueKey('shelves-empty'), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(onPressed: () => d.addToLibrary(context), icon: const Icon(Icons.add, size: 18), label: const Text('Add to Library')),
                ),
                const SizedBox(height: 12),
              ],
              switch (look) {
                ShelfLook.list => _ShelfList(deps: d, shelves: s.shelves),
                ShelfLook.drawers => _Drawers(deps: d),
                ShelfLook.spines => _Spines(deps: d),
              },
            ],
          );
        },
      ),
    );
  }

  /// "Making 214 books searchable" while books are being made searchable, with its bar; tapping it opens Catalog, where Pause is.
  Widget? _working() {
    final s = d.shelves;
    var making = 0;
    double? sum;
    var known = 0;
    for (final b in [for (final sh in s.shelves) for (final c in sh.children) ...s.booksOn(c.id), ...s.unsorted]) {
      final st = s.searchOf(b);
      if (st.state != BookSearchState.making) continue;
      making++;
      if (st.fraction != null) {
        sum = (sum ?? 0) + st.fraction!;
        known++;
      }
    }
    if (making == 0) return null;
    final k = context.t;
    final f = known == 0 ? null : sum! / known;
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('shelves-working'),
        onTap: () => LibraryNav.of(context).goTo(context, [catalogSpec(d)]),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Making ${booksWord(making)} searchable', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(value: f, minHeight: 6, color: k.accent, backgroundColor: k.secondary.withValues(alpha: 0.15)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: k.secondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three-way switch at the top of Bookshelves: List, Drawers, Spines.
class LookSwitch extends StatelessWidget {
  const LookSwitch({super.key, required this.value, required this.onChanged});

  final ShelfLook value;
  final ValueChanged<ShelfLook> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      container: true,
      label: 'How Bookshelves look',
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: k.secondary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(
          children: [
            for (final l in ShelfLook.values)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: l == value,
                  child: Material(
                    color: l == value ? k.primary : Colors.transparent,
                    shape: const StadiumBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('look-${l.name}'),
                      onTap: () => onChanged(l),
                      child: SizedBox(
                        height: 40,
                        child: Center(
                          child: Text(l.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: l == value ? k.onPrimary : k.text)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A numbered shelf's leading: the class colour's band and the number in the fixed-width face.
class ShelfNumber extends StatelessWidget {
  const ShelfNumber({super.key, required this.text, required this.color, this.size = 20, this.width = 50, this.band = true});

  final String text;
  final Color color;
  final double size;
  final double width;
  final bool band;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (band) Container(width: 5, height: 34, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
      if (band) const SizedBox(width: 10),
      SizedBox(
        width: width,
        child: Text(text, style: TextStyle(fontFamily: kCdsMono, fontSize: size, fontWeight: FontWeight.w700, color: color)),
      ),
    ],
  );
}

/// List (the default look): each shelf with its band, number, name and book count; an empty shelf dimmed with "empty".
class _ShelfList extends StatelessWidget {
  const _ShelfList({required this.deps, required this.shelves, this.inside = false});

  final LibraryDeps deps;
  final List<Shelf> shelves;

  /// Inside a class (its divisions): no band, "empty" for an empty one.
  final bool inside;

  @override
  Widget build(BuildContext context) {
    final nav = LibraryNav.of(context);
    final s = deps.shelves;
    return SettingsGroup(
      rows: [
        for (final sh in shelves.where((x) => x.assigned))
          Builder(
            builder: (context) {
              final n = s.countUnder(sh);
              final empty = n == 0;
              final row = SettingsRow(
                key: ValueKey('shelf-${sh.id}'),
                leading: sh.number == null
                    ? null
                    : ShelfNumber(text: sh.number!, color: shelfColor(context, sh), band: !inside, size: inside ? 18 : 20, width: inside ? 44 : 50),
                title: sh.name,
                status: [Part(inside && empty ? 'empty' : booksWord(n))],
                selected: nav.isOpen('shelf:${sh.id}'),
                onTap: () => nav.open(context, shelfSpec(deps, sh)),
              );
              return inside && empty ? Opacity(opacity: 0.55, child: row) : row;
            },
          ),
      ],
    );
  }
}

/// The wood of the card-catalogue cabinet, for this theme.
({Color cabinet, Color drawer, Color edge, Color pull, Color label}) _wood(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final k = context.t;
  if (k.monoDark != null) {
    // a single-hue theme: the cabinet in its own hue
    return (cabinet: k.surface, drawer: Color.alphaBlend(k.accent.withValues(alpha: 0.18), k.background), edge: k.secondary, pull: k.secondary, label: k.text);
  }
  return dark
      ? (cabinet: const Color(0xFF3E2F22), drawer: const Color(0xFF6B5039), edge: const Color(0xFF4F3B2A), pull: const Color(0xFF2E2219), label: const Color(0xFFF3EAD6))
      : (cabinet: const Color(0xFF7A5A3A), drawer: const Color(0xFFB98A5C), edge: const Color(0xFF8F6440), pull: const Color(0xFF6A4A2A), label: const Color(0xFF1A1D1F));
}

/// Drawers: each class a drawer front of a card-catalogue cabinet, its typed label card with the range ("200-299") and name, a
/// pull and the book count.
class _Drawers extends StatelessWidget {
  const _Drawers({required this.deps});

  final LibraryDeps deps;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final w = _wood(context);
    final s = deps.shelves;
    final nav = LibraryNav.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final cols = (c.maxWidth / 170).floor().clamp(2, 5);
        final shelves = s.shelves.where((x) => x.assigned).toList();
        return Container(
          key: const ValueKey('shelves-drawers'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: w.cabinet, borderRadius: BorderRadius.circular(14)),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: cols,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.45,
            children: [
              for (final sh in shelves)
                Semantics(
                  button: true,
                  label: '${sh.label(s.shortName)} ${sh.name}, ${booksWord(s.countUnder(sh))}',
                  excludeSemantics: true,
                  child: Material(
                    color: w.drawer,
                    borderRadius: BorderRadius.circular(6),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('drawer-${sh.id}'),
                      onTap: () => nav.open(context, shelfSpec(deps, sh)),
                      child: Container(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: w.edge, width: 3))),
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                        child: Column(
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                              decoration: BoxDecoration(
                                color: nav.isOpen('shelf:${sh.id}') ? Color.alphaBlend(k.accent.withValues(alpha: 0.18), k.surface) : k.surface,
                                border: Border.all(color: w.edge),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    sh.number == null ? sh.name : cdsClass(sh.number!)?.range ?? sh.number!,
                                    style: TextStyle(fontFamily: kCdsMono, fontSize: 15, fontWeight: FontWeight.w700, color: k.text),
                                  ),
                                  Text(
                                    sh.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontFamily: kCdsSerif, fontSize: 11, height: 1.25, color: k.text),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            Container(width: 44, height: 9, decoration: BoxDecoration(color: w.pull, borderRadius: BorderRadius.circular(5))),
                            const SizedBox(height: 4),
                            Text(booksWord(s.countUnder(sh)), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: w.label)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Spines: each class a shelf with its books' spines standing on it (at most 22 drawn), its number and name.
class _Spines extends StatelessWidget {
  const _Spines({required this.deps});

  final LibraryDeps deps;

  static const int maxSpines = 22;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final w = _wood(context);
    final s = deps.shelves;
    final nav = LibraryNav.of(context);
    final shelves = s.shelves.where((x) => x.assigned).toList();
    return Column(
      key: const ValueKey('shelves-spines'),
      children: [
        for (var i = 0; i < shelves.length; i++)
          Builder(
            builder: (context) {
              final sh = shelves[i];
              final n = s.countUnder(sh);
              final color = shelfColor(context, sh);
              return Semantics(
                button: true,
                label: '${sh.label(s.shortName)} ${sh.name}, ${booksWord(n)}',
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('spines-${sh.id}'),
                  onTap: () => nav.open(context, shelfSpec(deps, sh)),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Column(
                      children: [
                        Container(
                          height: 50,
                          color: nav.isOpen('shelf:${sh.id}') ? k.accent.withValues(alpha: 0.12) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: LayoutBuilder(
                            builder: (context, c) {
                              // the spines take what the number and the name leave
                              final room = ((c.maxWidth - 40 - 110) / 12).floor().clamp(0, maxSpines);
                              final count = n < room ? n : room;
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  SizedBox(
                                    width: 40,
                                    height: 50,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(sh.number ?? '', style: TextStyle(fontFamily: kCdsMono, fontSize: 13, fontWeight: FontWeight.w700, color: color)),
                                    ),
                                  ),
                                  for (var j = 0; j < count; j++)
                                    Container(
                                      width: 9,
                                      height: 30 + ((j * 7 + i * 3) % 16).toDouble(),
                                      margin: const EdgeInsets.only(right: 3),
                                      decoration: BoxDecoration(color: color.withValues(alpha: 0.85), borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
                                    ),
                                  Expanded(
                                    child: SizedBox(
                                      height: 50,
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: Text(
                                          n == 0 ? '${sh.name} · empty' : sh.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 12, color: n == 0 ? k.secondary : k.text),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        Container(height: 6, decoration: BoxDecoration(color: w.cabinet, borderRadius: BorderRadius.circular(2))),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A shelf opened: a class (its divisions, every one, the empty ones dimmed) or a division (its books by call number).
class ShelfPage extends StatelessWidget {
  const ShelfPage({super.key, required this.deps, required this.shelfId});

  final LibraryDeps deps;
  final String shelfId;

  @override
  Widget build(BuildContext context) {
    final d = deps;
    return ListenableBuilder(
      listenable: d.changes,
      builder: (context, _) {
        final s = d.shelves;
        final sh = s.shelf(shelfId);
        if (sh == null) {
          return Scaffold(appBar: libraryAppBar(context, title: 'Bookshelves'), body: const Center(child: Text('This shelf is not in the scheme.')));
        }
        final color = shelfColor(context, sh);
        final n = s.countUnder(sh);
        return Scaffold(
          appBar: libraryAppBar(context, title: sh.name, number: sh.number == null ? null : sh.label(s.shortName), numberColor: color),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              LibraryCrumbs(crumbs: shelfCrumbs(context, d, sh.id), trail: booksWord(n)),
              const SizedBox(height: 4),
              if (!sh.holdsBooks)
                _ShelfList(deps: d, shelves: sh.children, inside: true)
              else
                _Books(deps: d, books: s.booksOn(sh.id), color: color),
            ],
          ),
        );
      },
    );
  }
}

/// The book rows of a division: call number (without "CDS"), title, size, and one small state mark when needed.
class _Books extends StatelessWidget {
  const _Books({required this.deps, required this.books, required this.color});

  final LibraryDeps deps;
  final List<ShelfBook> books;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    if (books.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text('No books on this shelf yet.', key: const ValueKey('shelf-empty'), style: TextStyle(fontSize: 14, color: k.secondary)),
      );
    }
    final nav = LibraryNav.of(context);
    return SettingsGroup(
      rows: [
        for (final b in books)
          SettingsRow(
            key: ValueKey('book-${b.id}'),
            leading: SizedBox(
              width: 74,
              child: Text(
                (b.callNumber ?? 'CDS —').replaceFirst('CDS ', ''),
                style: TextStyle(fontFamily: kCdsMono, fontSize: 13, fontWeight: FontWeight.w700, color: color),
              ),
            ),
            title: b.title,
            statusWidget: libraryLines(context, bookLine(b), bookMark(deps, b)),
            statusLines: 2,
            chevron: false,
            selected: nav.isOpen('book:${b.id}'),
            onTap: () => nav.open(context, bookSpec(deps, b.id)),
          ),
      ],
    );
  }
}

/// "41 MB", or "230 pages" when the size is not known.
String bookLine(ShelfBook b) {
  if (b.bytes != null && b.bytes! > 0) return formatBytes(b.bytes!);
  if (b.pages != null && b.pages! > 0) return b.pages == 1 ? '1 page' : '${b.pages} pages';
  return 'Book';
}

/// The one small state mark a book row carries when needed: "Not on this device", "Making it searchable 40%".
String? bookMark(LibraryDeps d, ShelfBook b) {
  final st = d.shelves.searchOf(b);
  switch (st.state) {
    case BookSearchState.making:
      final f = st.fraction;
      return f == null ? 'Making it searchable' : 'Making it searchable ${(f * 100).round()}%';
    case BookSearchState.failed:
      return 'Stopped: it could not be read';
    default:
      break;
  }
  if (d.files.stateOf(b).where == BookFileWhere.elsewhere) return 'Not on this device';
  return null;
}

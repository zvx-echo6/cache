import 'package:flutter/material.dart';

import '../browse/browse_state.dart';
import '../layout/adaptive.dart' show isDesktop;
import '../regions/regions_state.dart';
import '../screens/settings/about_pages.dart';
import '../screens/settings/widgets.dart';
import '../search/index_overview.dart';
import '../search/index_scheduler.dart' show indexSchedulerShared;
import '../pdf/index/pdf_index_app.dart' show pdfIndexShared;
import '../sharing/sharing_state.dart';
import '../sources/libraries_state.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import '../update/update_ui.dart' show currentWhatsNew, showWhatsNew;
import '../version.dart';
import '../video/format.dart' show formatBytes;
import 'add_pdf/add_pdf_state.dart' show addPdfShared;
import 'book_pages.dart';
import 'catalog_page.dart';
import 'library_panes.dart';
import 'library_prefs.dart';
import 'shelf_source.dart';
import 'shelves_pages.dart';

/// What the Library's pages need: the states they show, and what the Library module does for them (its ZIM list and menus, Add
/// to Library, the guide).
class LibraryDeps {
  LibraryDeps({
    required this.browse,
    required this.shelves,
    required this.files,
    required this.looks,
    required this.zims,
    required this.addToLibrary,
    required this.openGuide,
    required this.openOwnLibrary,
    required this.holdsBooks,
    required this.booksIn,
    this.originals,
    this.regions,
    this.sharing,
    this.rootTop,
    this.rootBottom,
    this.whatsNew = currentWhatsNew,
  });

  final BrowseState browse;
  SourcesState get sources => browse.sources;
  LibrariesState? get libraries => browse.libraries;
  final ShelfSource shelves;
  final BookFiles files;

  /// The book page's "Open original" (a linked folder's own file): supplied where there is one.
  final OriginalFileProvider? originals;
  final ShelfLookPrefs looks;
  final RegionsState? regions;
  final SharingState? sharing;

  /// ZIM Collections, as the Library module draws it (its rows, menus and the reader).
  final WidgetBuilder zims;
  final void Function(BuildContext context) addToLibrary;
  final Future<void> Function(BuildContext context) openGuide;
  final void Function(BuildContext context, LibraryItem item) openOwnLibrary;

  /// A library whose books are on Bookshelves (its search index is "Your books" in Catalog).
  final bool Function(LibraryItem item) holdsBooks;

  /// How many books a library of books holds, shelved or not.
  final int Function(LibraryItem item) booksIn;

  /// What shows above the four rows besides the search progress (a library being added).
  final List<Widget> Function(BuildContext context)? rootTop;

  /// What shows under the four rows, above Add to Library (in a browser, the libraries built from PDFs).
  final List<Widget> Function(BuildContext context)? rootBottom;
  final Future<List<String>> Function() whatsNew;

  /// Everything a Library page listens to.
  Listenable get changes => Listenable.merge([browse, sources, ?libraries, shelves, files, ?originals, ?regions, ?sharing, ?indexSchedulerShared, ?pdfIndexShared, ?addPdfShared, looks]);
}

// ---- the levels

LibraryPageSpec zimsSpec(LibraryDeps d) => LibraryPageSpec('zims', d.zims);
LibraryPageSpec bookshelvesSpec(LibraryDeps d) => LibraryPageSpec('bookshelves', (_) => BookshelvesPage(deps: d));
LibraryPageSpec shelfSpec(LibraryDeps d, Shelf s) => LibraryPageSpec('shelf:${s.id}', (_) => ShelfPage(deps: d, shelfId: s.id));
LibraryPageSpec bookSpec(LibraryDeps d, String id) => LibraryPageSpec('book:$id', (_) => BookPage(deps: d, bookId: id), leaf: true);
LibraryPageSpec unsortedSpec(LibraryDeps d) => LibraryPageSpec('unsorted', (_) => UnsortedPage(deps: d));
LibraryPageSpec hiddenSpec(LibraryDeps d) => LibraryPageSpec('hidden', (_) => HiddenBooksPage(deps: d), leaf: true);
LibraryPageSpec catalogSpec(LibraryDeps d, {String? focus}) => LibraryPageSpec('catalog', (_) => CatalogPage(deps: d, focus: focus), leaf: true);
LibraryPageSpec docsSpec(LibraryDeps d) => LibraryPageSpec('docs', (_) => DocsPage(deps: d), leaf: true);
LibraryPageSpec creditsSpec() => LibraryPageSpec('credits', (_) => const AboutPage(), leaf: true);

/// The levels from Bookshelves down to shelf [id] (Bookshelves, its class, the division).
List<LibraryPageSpec> shelfPath(LibraryDeps d, String id) => [bookshelvesSpec(d), for (final s in d.shelves.pathTo(id)) shelfSpec(d, s)];

/// The levels from Bookshelves down to book [b] (Unsorted for a book no shelf holds).
List<LibraryPageSpec> bookPath(LibraryDeps d, ShelfBook b) => [
  ...(b.shelf == null ? [bookshelvesSpec(d), unsortedSpec(d)] : shelfPath(d, b.shelf!)),
  bookSpec(d, b.id),
];

/// The breadcrumb of Bookshelves' levels: "Library" (in the panes), "Bookshelves", then each shelf down to [shelfId], the last one
/// (or [last]) not tappable.
List<Crumb> shelfCrumbs(BuildContext context, LibraryDeps d, String? shelfId, {String? last}) {
  final nav = LibraryNav.of(context);
  final out = <Crumb>[if (!nav.compact) const Crumb('Library', [])];
  final shelves = shelfId == null ? const <Shelf>[] : d.shelves.pathTo(shelfId);
  final short = d.shelves.shortName;
  out.add(Crumb('Bookshelves', shelves.isEmpty && last == null ? null : [bookshelvesSpec(d)]));
  for (var i = 0; i < shelves.length; i++) {
    final s = shelves[i];
    final isLast = i == shelves.length - 1 && last == null;
    out.add(Crumb(s.label(short), isLast ? null : shelfPath(d, s.id)));
  }
  if (last != null) out.add(Crumb(last));
  return out;
}

extension on String {
  String? get emptyToNullWords => isEmpty ? null : this;
}

/// "1 book", "14 books".
String booksWord(int n) => n == 1 ? '1 book' : '$n books';

/// An icon on a tile, as the Library's rows show it.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Color.alphaBlend(k.secondary.withValues(alpha: 0.10), k.surface), borderRadius: BorderRadius.circular(size / 4)),
      child: Icon(icon, size: size * 0.55, color: k.accent),
    );
  }
}

/// The two short lines under a Library row's name: what it holds, and a fix in the accent ("Update ready for 1", "9 unsorted"),
/// never an alarm.
Widget libraryLines(BuildContext context, String line, String? fix) {
  final k = context.t;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.35, color: k.secondary)),
      if (fix != null) Text(fix, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.35, fontWeight: FontWeight.w500, color: k.accent)),
    ],
  );
}

/// The Library: four rows (ZIM Collections, Bookshelves, Catalog, Cache Documentation), the search progress card above them, and
/// Add to Library, the one way in.
class LibraryRootPage extends StatelessWidget {
  const LibraryRootPage({super.key, required this.deps});

  final LibraryDeps deps;

  @override
  Widget build(BuildContext context) {
    final d = deps;
    final nav = LibraryNav.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: libraryAppBar(context, title: 'Library'),
      body: ListenableBuilder(
        listenable: d.changes,
        builder: (context, _) {
          final sources = d.sources;
          final zims = sources.zims;
          final zimBytes = zims.fold<int>(0, (s, z) => s + z.size);
          final updates = d.browse.updates.length;
          final shelves = d.shelves;
          final books = shelves.bookCount;
          final unsorted = shelves.unsorted.length;
          final entries = catalogEntries(d);
          final readying = entries.where((e) => !e.ready).length;
          // A desktop window shows Add to Library beside the list while nothing is chosen: never two ways to one place.
          final addBeside = !nav.compact && isDesktop(context) && !LibraryNav.of(context).isAnythingOpen;
          return LayoutBuilder(builder: (context, c) {
          // a narrow sections pane (230 to 280) leaves the tiles out, so the names fit
          final roomy = c.maxWidth >= 300;
          IconTile? tile(IconData i) => roomy ? IconTile(i) : null;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (indexSchedulerShared case final s?) IndexOverviewLine(scheduler: s),
              ...?d.rootTop?.call(context),
              SettingsGroup(
                rows: [
                  SettingsRow(
                    key: const ValueKey('library-zims'),
                    chevron: roomy ? null : false,
                    leading: tile(Icons.collections_bookmark_outlined),
                    title: 'ZIM Collections',
                    statusWidget: libraryLines(
                      context,
                      zims.isEmpty ? 'None yet' : '${zims.length == 1 ? '1 collection' : '${zims.length} collections'} · ${formatBytes(zimBytes)}',
                      updates == 0 ? null : 'Update ready for $updates',
                    ),
                    selected: nav.isOpen('zims'),
                    onTap: () => nav.open(context, zimsSpec(d)),
                  ),
                  SettingsRow(
                    key: const ValueKey('library-bookshelves'),
                    chevron: roomy ? null : false,
                    leading: tile(Icons.shelves),
                    title: 'Bookshelves',
                    statusWidget: libraryLines(
                      context,
                      books == 0 ? 'No books yet' : '${booksWord(books)}, shelved by the ${shelves.shortName ?? 'shelves'}',
                      [if (unsorted > 0) '$unsorted unsorted', if ((addPdfShared?.adding ?? 0) > 0) '${addPdfShared!.adding} being added'].join(' · ').emptyToNullWords,
                    ),
                    selected: nav.isOpen('bookshelves'),
                    onTap: () => nav.open(context, bookshelvesSpec(d)),
                  ),
                  SettingsRow(
                    key: const ValueKey('library-catalog'),
                    chevron: roomy ? null : false,
                    leading: tile(Icons.manage_search),
                    title: 'Catalog',
                    statusWidget: libraryLines(
                      context,
                      entries.isEmpty ? 'No search indexes yet' : (entries.length == 1 ? '1 search index' : '${entries.length} search indexes'),
                      readying == 0 ? null : '$readying getting ready',
                    ),
                    selected: nav.isOpen('catalog'),
                    onTap: () => nav.open(context, catalogSpec(d)),
                  ),
                  SettingsRow(
                    key: const ValueKey('library-docs'),
                    chevron: roomy ? null : false,
                    leading: tile(Icons.description_outlined),
                    title: 'Cache Documentation',
                    titleLines: 2,
                    statusWidget: libraryLines(context, "The Cache guide, What's new, credits", null),
                    selected: nav.isOpen('docs'),
                    onTap: () => nav.open(context, docsSpec(d)),
                  ),
                ],
              ),
              if (d.rootBottom?.call(context) case final below? when below.isNotEmpty) ...[const SizedBox(height: 16), ...below],
              if (!addBeside) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const ValueKey('add-to-library'),
                    onPressed: () => d.addToLibrary(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add to Library'),
                  ),
                ),
              ],
            ],
          );
          });
        },
      ),
    );
  }
}

/// Cache Documentation: the guide that ships in the app, What's new in this version and Credits and licences (the last two moved
/// here from Settings, so each has one home).
class DocsPage extends StatefulWidget {
  const DocsPage({super.key, required this.deps});

  final LibraryDeps deps;

  @override
  State<DocsPage> createState() => _DocsPageState();
}

class _DocsPageState extends State<DocsPage> {
  late final Future<List<String>> _lines = widget.deps.whatsNew();

  @override
  Widget build(BuildContext context) {
    final nav = LibraryNav.of(context);
    return Scaffold(
      appBar: libraryAppBar(context, title: 'Cache Documentation'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          if (!nav.compact) const LibraryCrumbs(crumbs: [Crumb('Library', []), Crumb('Cache Documentation')]),
          FutureBuilder<List<String>>(
            future: _lines,
            builder: (context, snap) {
              final lines = snap.data ?? const <String>[];
              return SettingsGroup(
                rows: [
                  SettingsRow(
                    key: const ValueKey('docs-guide'),
                    leading: const IconTile(Icons.menu_book_outlined),
                    title: 'The Cache guide',
                    status: const [Part('Built in · how everything works')],
                    onTap: () => widget.deps.openGuide(context),
                  ),
                  if (lines.isNotEmpty)
                    SettingsRow(
                      key: const ValueKey('docs-whats-new'),
                      leading: const IconTile(Icons.new_releases_outlined),
                      title: "What's new in $kAppVersion",
                      status: const [Part('The changes in this version')],
                      onTap: () => showWhatsNew(context, version: kAppVersion, lines: lines),
                    ),
                  SettingsRow(
                    key: const ValueKey('docs-credits'),
                    leading: const IconTile(Icons.favorite_border),
                    title: 'Credits and licenses',
                    status: const [Part('The maps, data and code Cache is built on')],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutPage())),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const NoteText("What's new and Credits and licenses moved here from Settings."),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../pdf/open_pdf.dart' show openPdfReader;
import '../pdf/pdf_source.dart' show PdfFileSource, PdfFrom, PdfServerSource;
import '../screens/settings/widgets.dart';
import '../sources/libraries_state.dart';
import '../theme.dart';
import 'library_pages.dart';
import 'library_panes.dart';
import 'shelf_source.dart';
import 'shelves_pages.dart' show shelfColor;

/// A library's books, from Catalog: every document in the library with where it stands on Bookshelves (its shelf, Unsorted,
/// Hidden, or On no shelf), and how many copies it has when more than one. The ones on no shelf come first, so they are seen.
/// A book opens its book page; a document with no Bookshelves book opens its PDF, and says so.
class LibraryDocsPage extends StatelessWidget {
  const LibraryDocsPage({super.key, required this.deps, required this.library});

  final LibraryDeps deps;
  final LibraryItem library;

  @override
  Widget build(BuildContext context) {
    final d = deps;
    final pageContext = context;
    final title = d.libraries?.titleOf(library) ?? library.folderName;
    return Scaffold(
      appBar: libraryAppBar(context, title: title),
      body: ListenableBuilder(
        listenable: d.changes,
        builder: (context, _) {
          final k = context.t;
          final nav = LibraryNav.of(context);
          final docs = d.documentsIn?.call(library) ?? const <LibraryDoc>[];
          int byTitle(LibraryDoc a, LibraryDoc b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
          final none = [for (final x in docs) if (x.place == DocPlace.none) x]..sort(byTitle);
          final rest = [for (final x in docs) if (x.place != DocPlace.none) x]..sort(byTitle);
          Widget group(List<LibraryDoc> rows) => SettingsGroup(
            rows: [for (final x in rows) _DocRow(key: ValueKey('doc-${x.docId}'), deps: d, doc: x, pageContext: pageContext)],
          );
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              if (!nav.compact) LibraryCrumbs(crumbs: [const Crumb('Library', []), Crumb('Catalog', [catalogSpec(d)]), Crumb(title)], trail: booksWord(docs.length)),
              const SizedBox(height: 4),
              if (docs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('No books in this library yet.', key: const ValueKey('library-docs-empty'), style: TextStyle(fontSize: 14, color: k.secondary)),
                ),
              if (none.isNotEmpty) ...[
                GroupLabel('On no shelf · ${none.length}'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                  child: Text(
                    "${none.length == 1 ? "This book is" : "These books are"} in this library, but not on your Bookshelves. Tap one to open its PDF.",
                    key: const ValueKey('library-docs-none-note'),
                    style: TextStyle(fontSize: 13, color: k.secondary),
                  ),
                ),
                group(none),
                const SizedBox(height: 10),
              ],
              if (rest.isNotEmpty) ...[
                if (none.isNotEmpty) GroupLabel('On Bookshelves · ${rest.length}'),
                group(rest),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DocRow extends StatelessWidget {
  const _DocRow({super.key, required this.deps, required this.doc, required this.pageContext});

  final LibraryDeps deps;
  final LibraryDoc doc;
  final BuildContext pageContext;

  /// "CDS 210-001 · First aid and emergency care", "Unsorted", "Hidden" or "On no shelf". Copies are their own line.
  String _where() {
    final b = doc.book;
    final sh = b.shelf == null ? null : deps.shelves.shelf(b.shelf!);
    final base = switch (doc.place) {
      DocPlace.shelved => b.callNumber != null && sh != null ? '${b.callNumber} · ${sh.name}' : (sh?.name ?? 'Unsorted'),
      DocPlace.unsorted => 'Unsorted',
      DocPlace.hidden => 'Hidden',
      DocPlace.none => 'On no shelf',
    };
    return base;
  }

  void _open(BuildContext context) {
    final b = doc.book;
    if (doc.place != DocPlace.none) {
      LibraryNav.of(pageContext).open(pageContext, bookSpec(deps, b.id));
      return;
    }
    final path = b.pdfPath;
    final fetch = deps.shelves.pdfFetcher(b);
    if (path != null) {
      openPdfReader(context, PdfFileSource(path, title: b.title, from: PdfFrom.library), page: 1);
    } else if (fetch != null) {
      openPdfReader(context, PdfServerSource(id: '${b.libraryId}/${b.docId}', title: b.title, fetch: fetch), page: 1);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('This book is not on your shelves, and its PDF is not on this device.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final b = doc.book;
    final sh = b.shelf == null ? null : deps.shelves.shelf(b.shelf!);
    final color = switch (doc.place) {
      DocPlace.shelved when sh != null => shelfColor(context, sh),
      DocPlace.none => toneColor(k, Tone.warn),
      _ => k.secondary,
    };
    final hasFile = b.pdfPath != null || deps.shelves.pdfFetcher(b) != null;
    final line = Text(_where(), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.35, fontWeight: doc.place == DocPlace.none ? FontWeight.w600 : FontWeight.w400, color: color));
    return SettingsRow(
      title: doc.title,
      titleLines: 2,
      statusLines: null,
      chevron: true,
      selected: doc.place != DocPlace.none && LibraryNav.of(context).isOpen('book:${b.id}'),
      onTap: () => _open(context),
      statusWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          line,
          if (doc.place == DocPlace.none) Text(hasFile ? 'Opens the PDF' : 'Not on this device', style: TextStyle(fontSize: 13, height: 1.35, color: k.secondary)),
          if (doc.copies > 1) Text('${doc.copies} copies', key: ValueKey('doc-copies-${doc.docId}'), style: TextStyle(fontSize: 13, height: 1.35, color: k.secondary)),
        ],
      ),
    );
  }
}
